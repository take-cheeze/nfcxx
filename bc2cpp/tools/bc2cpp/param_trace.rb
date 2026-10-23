# frozen_string_literal: true

require 'stringio'
require_relative 'else_trace'

# PARAM_TRACE: opt-in runtime classes of the parameters of compiled methods and blocks, of the values
# their `return` statements hand back (RETURN_SITE rows), and of the values an ivar read hands back
# (IVAR_SITE rows, one per owner class and ivar name).
#
# Off unless BC2CPP_TRACE_TYPES=1 is set; the unset output is byte-identical to a build without this
# file (bc2cpp.rb does not even require it). Set, bc2cpp's stdout is rewritten after codegen (nothing
# in codegen reads it), like ElseTrace:
#
#   mrb_value Foo_bar_impl(mrb_state* M, mrb_value self, mrb_value x) {
#     mrb_value r0 = self;                       ->   bc2cpp_param_enter_SYM(F); bc2cpp_param_hit_SYM(M, S, x); mrb_value r0 = self;
#
# The statements go in front of the first register declaration, on the same line, so no line moves
# and the line numbers ElseTrace reports stay those of the untraced output. Every `*_impl` function
# whose header the compiled-method table (or a `bc2cpp_bargN` block parameter) explains is covered:
#
#   * a method's required, optional (only when the call supplied it), rest and keyword parameters;
#     a NATIVE_ARG_TARGETS parameter (mrb_int/mrb_sym/mrb_bool) is boxed for the count;
#   * the positional parameters of a block that has its own `_impl` (BLOCK_FALLBACK, lambda, proc);
#   * the receiver of a singleton method (`def self.x`, `def Owner.x`, the defs of a `class << self`), as a
#     `self` site (kind `self`). Its runtime class is the class object itself, not its metaclass, so the
#     site is keyed by that class and named by its path (see bc2cpp_self_hit_*).
#
# Not covered, and counted as such in the dump: a block inlined into its caller's loop (INLINE_LOOP:
# each/map/times ...), where the parameter is a register of the enclosing function, resumable
# `_step` bodies, and rescue-extracted try bodies.
#
# Each binary keeps, per parameter, its call count and up to MAX_CLASSES distinct runtime classes (the
# real class, so a singleton class counts as its class; a `self` site names the class object instead), and
# appends to the file named by BC2CPP_TRACE_TYPES_OUT (stderr when unset) at exit. Every row carries the statically proven fact
# for the parameter that this bc2cpp run computed, so the dump is self-contained.
# scripts/bc2cpp/trace_types.rb report reads it, together with an ElseTrace dump.
module ParamTrace
  MAX_CLASSES = 8
  # The impl header: `mrb_value Foo_bar_impl(mrb_state* M, mrb_value self, <params>) {`.
  HEADER_RE = /\A(?:static )?mrb_value ([\w$]+_impl)\(mrb_state\* M, mrb_value self((?:, [^,()]+)*)\) \{\s*\z/
  BARG_RE = /\Abc2cpp_barg(\d+)\z/
  KWARG_RE = /\Abc2cpp_kwarg_([\w$]+)\z/
  KW_GIVEN_RE = /\Abc2cpp_kw_given_([\w$]+)\z/
  REG0_RE = /\A\s*mrb_value r0 = self;/
  # Left by codegen after a GETIV (codegen_insn.rb ivar_trace_marker): the owner class, the ivar and its register.
  IVAR_MARKER_RE = %r{\A\s*/\*BC2CPP_IVAR_HIT (\S+) (@\S+) r(\d+)\*/\s*\z}
  REG0_WINDOW = 12
  # C parameter type => the expression that boxes it back to an mrb_value (TYPE_OPS[...][:box]).
  BOX = { 'mrb_value' => '%s', 'mrb_int' => 'mrb_fixnum_value(%s)', 'mrb_sym' => 'mrb_symbol_value(%s)',
          'mrb_bool' => 'mrb_bool_value(%s)' }.freeze

  module_function

  # Facts for one compiled method: mandatory count, optional count, rest, the registry arity of its name
  # and the proven facts per positional index, as strings "kind=value".
  #   argtypes  ArgTypes (call-site :fixnum/:symbol)         classarg  ClassArgTypes (call-site class)
  #   entryfix  ENTRY_ARG_CALLSITE_PROOF                      numeric   entry_arg_numeric mask
  #   pool      CLASS_POOLS argument pool                     annot     NATIVE_ARG_TARGETS annotation
  def method_infos(compiled, ireps:, registry:, arg_types:, class_arg_types:, annotations:, gen:)
    entry_fix = gen.instance_variable_get(:@entry_arg_fixnum)
    numeric = gen.instance_variable_get(:@entry_arg_numeric) || {}
    pools = gen.instance_variable_get(:@class_arg_pools) || {}
    compiled.each_with_object({}) do |m, infos|
      irep = m[:label] && ireps[m[:label]]
      next unless irep && m[:impl]

      enter = irep.enter
      mand, opt, rest = enter ? enter.enter_fields.first(3) : [0, 0, 0]
      defs = registry[m[:name].to_s] || registry[m[:name].to_sym] || []
      mono = defs.size == 1 && defs.first.irep == m[:label]
      facts = Hash.new { |h, k| h[k] = [] }
      total = mand + opt + (rest.to_i.positive? ? 1 : 0)
      (1..total).each do |k|
        if k <= mand && mono
          t = (arg_types[m[:name]] || [])[k - 1]
          facts[k] << "argtypes=#{t}" if t
          c = (class_arg_types[m[:name]] || [])[k - 1]
          facts[k] << "classarg=#{c}" if c
        end
        facts[k] << 'entryfix=Integer' if entry_fix&.include?([m[:label], k])
        mask = numeric[[m[:label], k]]
        facts[k] << "numeric=#{gen.send(:numeric_mask_name, mask)}" if mask
        pool = pools[[m[:label], k]]
        facts[k] << "pool=#{gen.send(:class_mask_name, pool)}" if pool&.nonzero?
        ann = annotations[m[:label]]
        facts[k] << "annot=#{ann.args[k - 1]}" if ann && k <= mand && ann.args[k - 1]
      end
      infos[m[:impl]] = { method: "#{m[:owner]}##{m[:name]}", mand: mand, opt: opt, rest: rest.to_i.positive?,
                          mono: mono, defs: defs.size, facts: facts, ret: return_fact(m[:name], gen),
                          singleton: m[:owner].to_s.end_with?('.singleton') }
    end
  end

  # The static return fact bc2cpp proved for a method name (the same proofs codegen uses for its own
  # return specialization): fixnum, array, class=NAME, or none.
  def return_fact(name, gen)
    n = name.to_s
    return 'fixnum' if gen.fixnum_return_names.include?(n)
    return 'array' if gen.array_return_names.include?(n)
    klass = gen.class_return_names[n]
    klass ? "class=#{klass}" : 'none'
  end

  def static_text(info, k)
    return 'none:block' unless info

    f = info[:facts][k]
    return f.join(',') unless f.empty?
    return 'none:non_mandatory' if k > info[:mand]

    info[:mono] ? 'none:mono' : "none:poly(#{info[:defs]})"
  end

  # [ctype, name] pairs of a header's parameter list after `self`.
  def header_params(tail)
    tail.split(', ').reject(&:empty?).map do |p|
      ctype, name = p.strip.split(/\s+/, 2)
      [ctype, name.to_s.delete('*&')]
    end
  end

  RETURN_RE = /\breturn ([^;]+);/
  # A C++ lambda inside a generated body: its own `return` answers the lambda, not the method.
  LAMBDA_RE = /\[(?:&|=)?\]\s*\(/

  # Wraps each `return EXPR;` of the function whose header is lines[start] (not the ones inside a lambda
  # nested in it) so the returned value is recorded. Appends one row per wrapped return to rets.
  def wrap_returns(lines, start, rets, ident, method, fn, block, ret_fact)
    depth = lines[start].count('{') - lines[start].count('}')
    lambda_depth = nil
    ordinal = 0
    k = start + 1
    while k < lines.size && depth.positive?
      line = lines[k]
      opens = line.count('{')
      closes = line.count('}')
      if lambda_depth.nil? && line.match?(LAMBDA_RE)
        lambda_depth = depth
      elsif lambda_depth.nil?
        lines[k] = line.gsub(RETURN_RE) do
          id = rets.size
          static = block ? 'none:block' : "ret=#{ret_fact}"
          ordinal += 1
          rets << { id: id, fn: fn, meta: [method, fn, block ? 'block' : 'method', 'return', 0, "return##{ordinal}", static].join("\t") }
          "return bc2cpp_ret_hit_#{ident}(M, #{id}, #{Regexp.last_match(1)});"
        end
      end
      depth += opens - closes
      lambda_depth = nil if lambda_depth && depth <= lambda_depth
      k += 1
    end
  end

  # Rewrites generated C++; returns [instrumented_text, summary]. `infos` is method_infos' result.
  def instrument(cpp, symbol, infos)
    lines = cpp.lines
    fns = []
    sites = []
    rets = []
    ivars = []
    ident = ElseTrace.ident(symbol)
    skipped = Hash.new(0)
    lines.each_with_index do |l, i|
      m = HEADER_RE.match(l.chomp) or next
      fn = m[1]
      params = header_params(m[2])
      info = infos[fn]
      if params.none? { |_, n| n =~ BARG_RE } && !info
        skipped[:not_a_method_or_block] += 1
        next
      end
      # The window stops at this function's closing brace: a short body must not reach the next function's `r0`.
      close = (i + 1...lines.size).find { |x| lines[x].match?(/\A\}\s*\z/) } || lines.size
      j = (i + 1..[i + REG0_WINDOW, close - 1].min).find { |x| lines[x].match?(REG0_RE) }
      unless j
        skipped[:no_register_block] += 1
        next
      end
      fnid = fns.size
      block = info.nil?
      stmts = []
      positional = 0
      given_opt = params.any? { |_, n| n == 'bc2cpp_given_opt' }
      kw_given = params.filter_map { |_, n| n[KW_GIVEN_RE, 1] }
      method = info ? info[:method] : "(#{fn})"
      if info && info[:singleton]
        # The receiver of `def self.x` is the class it ran on. Not a positional parameter, so no index.
        id = sites.size
        static = 'none:self'
        meta = [method, fn, 'method', 'self', 0, 'self', static].join("\t")
        sites << { id: id, fn: fn, meta: meta, kind: 'self', index: 0, name: 'self', method: method, static: static }
        stmts << "bc2cpp_self_hit_#{ElseTrace.ident(symbol)}(M, #{id}, self);"
      end
      params.each do |ctype, name|
        next if ctype.include?('*') || !BOX.key?(ctype)

        if (b = name[BARG_RE, 1])
          kind = 'block_arg'
          index = b.to_i
          label = name
          guard = nil
        elsif (kw = name[KWARG_RE, 1])
          kind = kw_given.include?(kw) ? 'kwopt' : 'kwreq'
          index = 0
          label = name
          guard = kw_given.include?(kw) ? "bc2cpp_kw_given_#{kw}" : nil
        elsif %w[bc2cpp_blk bc2cpp_given_opt].include?(name) || name =~ KW_GIVEN_RE
          next
        else
          positional += 1
          index = positional
          label = name
          if block
            kind = 'block_arg'
            guard = nil
          elsif info && index <= info[:mand]
            kind = 'req'
            guard = nil
          elsif info && index <= info[:mand] + info[:opt]
            kind = 'opt'
            guard = given_opt ? "bc2cpp_given_opt > #{index - info[:mand] - 1}" : nil
          else
            kind = 'rest'
            guard = nil
          end
        end
        id = sites.size
        static = kind =~ /\A(?:req|opt|rest)\z/ ? static_text(info, index) : (block ? 'none:block' : 'none:keyword')
        meta = [method, fn, block ? 'block' : 'method', kind, index, label, static].join("\t")
        sites << { id: id, fn: fn, meta: meta, kind: kind, index: index, name: label, method: method, static: static }
        call = "bc2cpp_param_hit_#{ElseTrace.ident(symbol)}(M, #{id}, #{format(BOX.fetch(ctype), name)});"
        stmts << (guard ? "if (#{guard}) #{call}" : call)
      end

      fns << { id: fnid, fn: fn, method: method, block: block }
      wrap_returns(lines, i, rets, ident, method, fn, block, info && info[:ret])
      # A marker is rewritten only in a function that is traced, so one left in an untraced body stays a comment.
      (i + 1...close).each do |x|
        mk = IVAR_MARKER_RE.match(lines[x]) or next
        vid = ivars.size
        ivars << { id: vid, owner: mk[1], ivar: mk[2] }
        lines[x] = "  bc2cpp_ivar_hit_#{ident}(M, #{vid}, r#{mk[3]});\n"
      end
      lines[j] = "  bc2cpp_param_enter_#{ident}(#{fnid}); #{stmts.join(' ')} #{lines[j].lstrip}"
      sites.last(stmts.size).each { |s| s[:fnid] = fnid }
    end
    summary = { fns: fns, sites: sites, rets: rets, ivars: ivars, skipped: skipped,
                untraced_methods: infos.keys.size - fns.count { |f| !f[:block] } }
    [header(symbol, fns, sites, summary) + lines.join, summary]
  end

  def header(symbol, fns, sites, summary)
    id = ElseTrace.ident(symbol)
    rets = summary[:rets]
    nsites = [sites.size, 1].max
    nrets = [rets.size, 1].max
    nfns = [fns.size, 1].max
    ivars = summary[:ivars]
    nivars = [ivars.size, 1].max
    ivarmeta = ivars.empty? ? '""' : ivars.map { |v| ElseTrace.c_string("#{v[:owner]}\t#{v[:ivar]}") }.join(",\n  ")
    meta = sites.empty? ? '""' : sites.map { |s| ElseTrace.c_string(s[:meta]) }.join(",\n  ")
    retmeta = rets.empty? ? '""' : rets.map { |r| ElseTrace.c_string(r[:meta]) }.join(",\n  ")
    fnmeta = fns.empty? ? '""' : fns.map { |f| ElseTrace.c_string([f[:method], f[:fn], f[:block] ? 'block' : 'method'].join("\t")) }.join(",\n  ")
    <<~CPP
      // BC2CPP_TRACE_TYPES -- see tools/bc2cpp/param_trace.rb.
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include <mruby.h>
      #include <mruby/class.h>
      #include <mruby/value.h>
      #include <mruby/array.h>
      #include <mruby/hash.h>
      #include "mrb_array_access.hxx"
      #define BC2CPP_PARAM_TRACE_MAX_CLASSES #{MAX_CLASSES}
      #define BC2CPP_ELEM_SAMPLE 8
      struct bc2cpp_param_cls_#{id} { struct RClass* real; char* name; unsigned long long count; };
      struct bc2cpp_param_site_#{id} { unsigned long long calls; unsigned long long overflow; unsigned ncls; struct bc2cpp_param_cls_#{id} cls[BC2CPP_PARAM_TRACE_MAX_CLASSES]; };
      static struct bc2cpp_param_site_#{id} bc2cpp_param_sites_#{id}[#{nsites}];
      static unsigned long long bc2cpp_param_entries_#{id}[#{nfns}];
      static const char* const bc2cpp_param_meta_#{id}[#{nsites}] = {
        #{meta}
      };
      static const char* const bc2cpp_param_fnmeta_#{id}[#{nfns}] = {
        #{fnmeta}
      };
      static struct bc2cpp_param_site_#{id} bc2cpp_ret_sites_#{id}[#{nrets}];
      // Three slots per site: [0] array elements, [1] hash keys, [2] hash values.
      static struct bc2cpp_param_site_#{id} bc2cpp_param_elem_#{id}[#{nsites * 3}];
      static struct bc2cpp_param_site_#{id} bc2cpp_ret_elem_#{id}[#{nrets * 3}];
      static const char* const bc2cpp_ret_meta_#{id}[#{nrets}] = {
        #{retmeta}
      };
      static inline void bc2cpp_param_enter_#{id}(unsigned fn) { bc2cpp_param_entries_#{id}[fn]++; }
      static void bc2cpp_site_record_#{id}(struct bc2cpp_param_site_#{id}* s, mrb_state* M, mrb_value v) {
        struct RClass* real = mrb_class_real(mrb_class(M, v));
        unsigned i = 0;
        s->calls++;
        while (i < s->ncls && s->cls[i].real != real) i++;
        if (i == s->ncls) {
          if (s->ncls == BC2CPP_PARAM_TRACE_MAX_CLASSES) { s->overflow++; return; }
          const char* n = mrb_obj_classname(M, v);
          s->cls[s->ncls].real = real;
          s->cls[s->ncls].name = strdup(n ? n : "?");
          s->cls[s->ncls].count = 0;
          i = s->ncls++;
        }
        s->cls[i].count++;
      }
      // The receiver of a singleton method. The site is keyed by the class object itself (mrb_class of a class is
      // its metaclass, which would name every singleton receiver `Class`). A value that is not a class or module
      // goes in one "(non-class)" bucket, which the gate cannot place, so it is never compared as a class name.
      static inline void bc2cpp_self_hit_#{id}(mrb_state* M, unsigned site, mrb_value v) {
        struct bc2cpp_param_site_#{id}* s = &bc2cpp_param_sites_#{id}[site];
        struct RClass* c = (mrb_class_p(v) || mrb_module_p(v)) ? mrb_class_ptr(v) : NULL;
        unsigned i = 0;
        s->calls++;
        while (i < s->ncls && s->cls[i].real != c) i++;
        if (i == s->ncls) {
          if (s->ncls == BC2CPP_PARAM_TRACE_MAX_CLASSES) { s->overflow++; return; }
          const char* n = c ? mrb_class_name(M, c) : NULL;
          s->cls[s->ncls].real = c;
          s->cls[s->ncls].name = strdup(n ? n : "(non-class)");
          s->cls[s->ncls].count = 0;
          i = s->ncls++;
        }
        s->cls[i].count++;
      }
      // Samples the elements of an Array or the keys/values of a Hash one level deep, so a
      // container's element type is visible without walking it whole.
      static void bc2cpp_elem_record_#{id}(struct bc2cpp_param_site_#{id}* t, mrb_state* M, mrb_value v) {
        if (mrb_array_p(v)) {
          mrb_int n = ary_size(v);
          for (mrb_int i = 0; i < n && i < BC2CPP_ELEM_SAMPLE; i++) bc2cpp_site_record_#{id}(&t[0], M, mrb_ary_ref(M, v, i));
        } else if (mrb_hash_p(v)) {
          mrb_value keys = mrb_hash_keys(M, v);
          mrb_int n = ary_size(keys);
          for (mrb_int i = 0; i < n && i < BC2CPP_ELEM_SAMPLE; i++) {
            mrb_value k = mrb_ary_ref(M, keys, i);
            bc2cpp_site_record_#{id}(&t[1], M, k);
            bc2cpp_site_record_#{id}(&t[2], M, mrb_hash_get(M, v, k));
          }
        }
      }
      static void bc2cpp_elem_dump_#{id}(FILE* f, const char* site_tag, const char* class_tag, const char* symbol, unsigned site, struct bc2cpp_param_site_#{id}* t) {
        static const char* const roles[3] = {"array", "key", "value"};
        for (unsigned r = 0; r < 3; r++) {
          struct bc2cpp_param_site_#{id}* s = &t[r];
          if (!s->calls && !s->overflow) continue;
          fprintf(f, "%s\\t%s\\t%u\\t%s\\t%llu\\t%llu\\n", site_tag, symbol, site, roles[r], s->calls, s->overflow);
          for (unsigned j = 0; j < s->ncls; j++)
            fprintf(f, "%s\\t%s\\t%u\\t%s\\t%s\\t%llu\\n", class_tag, symbol, site, roles[r], s->cls[j].name, s->cls[j].count);
        }
      }
      // One site per owner class and ivar name: the value a traced GETIV read hands back.
      static struct bc2cpp_param_site_#{id} bc2cpp_ivar_sites_#{id}[#{nivars}];
      static const char* const bc2cpp_ivar_meta_#{id}[#{nivars}] = {
        #{ivarmeta}
      };
      static inline void bc2cpp_ivar_hit_#{id}(mrb_state* M, unsigned site, mrb_value v) {
        bc2cpp_site_record_#{id}(&bc2cpp_ivar_sites_#{id}[site], M, v);
      }
      static inline void bc2cpp_param_hit_#{id}(mrb_state* M, unsigned site, mrb_value v) {
        bc2cpp_site_record_#{id}(&bc2cpp_param_sites_#{id}[site], M, v);
        bc2cpp_elem_record_#{id}(&bc2cpp_param_elem_#{id}[site * 3], M, v);
      }
      // Records the value a traced `return` hands back and passes it through unchanged.
      static inline mrb_value bc2cpp_ret_hit_#{id}(mrb_state* M, unsigned site, mrb_value v) {
        bc2cpp_site_record_#{id}(&bc2cpp_ret_sites_#{id}[site], M, v);
        bc2cpp_elem_record_#{id}(&bc2cpp_ret_elem_#{id}[site * 3], M, v);
        return v;
      }
      static void bc2cpp_param_dump_#{id}(void) {
        const char* path = getenv("BC2CPP_TRACE_TYPES_OUT");
        FILE* f = (path && *path) ? fopen(path, "a") : stderr;
        unsigned long long entries = 0;
        unsigned used = 0;
        if (!f) { perror(path); return; }
        for (unsigned i = 0; i < #{fns.size}; i++) entries += bc2cpp_param_entries_#{id}[i];
        for (unsigned i = 0; i < #{sites.size}; i++) if (bc2cpp_param_sites_#{id}[i].calls) used++;
        fprintf(f, "PARAM_TRACE_SYMBOL\\t%s\\tfns\\t%u\\tparams\\t%u\\tparams_hit\\t%u\\tentries\\t%llu\\tuntraced_methods\\t%d\\tinlined_blocks_not_traced\\t1\\n", "#{symbol}", (unsigned)#{fns.size}, (unsigned)#{sites.size}, used, entries, #{summary[:untraced_methods]});
        for (unsigned i = 0; i < #{fns.size}; i++)
          if (bc2cpp_param_entries_#{id}[i]) fprintf(f, "PARAM_FN\\t%s\\t%u\\t%llu\\t%s\\n", "#{symbol}", i, bc2cpp_param_entries_#{id}[i], bc2cpp_param_fnmeta_#{id}[i]);
        for (unsigned i = 0; i < #{sites.size}; i++) {
          struct bc2cpp_param_site_#{id}* s = &bc2cpp_param_sites_#{id}[i];
          fprintf(f, "PARAM_SITE\\t%s\\t%u\\t%llu\\t%llu\\t%s\\n", "#{symbol}", i, s->calls, s->overflow, bc2cpp_param_meta_#{id}[i]);
          for (unsigned j = 0; j < s->ncls; j++)
            fprintf(f, "PARAM_CLASS\\t%s\\t%u\\t%s\\t%llu\\n", "#{symbol}", i, s->cls[j].name, s->cls[j].count);
        }
        for (unsigned i = 0; i < #{rets.size}; i++) {
          struct bc2cpp_param_site_#{id}* s = &bc2cpp_ret_sites_#{id}[i];
          fprintf(f, "RETURN_SITE\\t%s\\t%u\\t%llu\\t%llu\\t%s\\n", "#{symbol}", i, s->calls, s->overflow, bc2cpp_ret_meta_#{id}[i]);
          for (unsigned j = 0; j < s->ncls; j++)
            fprintf(f, "RETURN_CLASS\\t%s\\t%u\\t%s\\t%llu\\n", "#{symbol}", i, s->cls[j].name, s->cls[j].count);
        }
        for (unsigned i = 0; i < #{ivars.size}; i++) {
          struct bc2cpp_param_site_#{id}* s = &bc2cpp_ivar_sites_#{id}[i];
          fprintf(f, "IVAR_SITE\\t%s\\t%u\\t%llu\\t%llu\\t%s\\n", "#{symbol}", i, s->calls, s->overflow, bc2cpp_ivar_meta_#{id}[i]);
          for (unsigned j = 0; j < s->ncls; j++)
            fprintf(f, "IVAR_CLASS\\t%s\\t%u\\t%s\\t%llu\\n", "#{symbol}", i, s->cls[j].name, s->cls[j].count);
        }
        for (unsigned i = 0; i < #{sites.size}; i++) bc2cpp_elem_dump_#{id}(f, "PARAM_ELEM_SITE", "PARAM_ELEM_CLASS", "#{symbol}", i, &bc2cpp_param_elem_#{id}[i * 3]);
        for (unsigned i = 0; i < #{rets.size}; i++) bc2cpp_elem_dump_#{id}(f, "RETURN_ELEM_SITE", "RETURN_ELEM_CLASS", "#{symbol}", i, &bc2cpp_ret_elem_#{id}[i * 3]);
        if (f != stderr) fclose(f);
      }
      static const int bc2cpp_param_registered_#{id} = atexit(bc2cpp_param_dump_#{id});
    CPP
  end

  # Called from bc2cpp.rb before the first output line, BEFORE ElseTrace.capture_stdout when both are on:
  # at_exit handlers run last-in first-out, so ElseTrace instruments the untouched text first (its
  # ELSE_SITE line numbers stay those of the plain output) and this runs on its result.
  def capture_stdout(symbol, infos)
    real = $stdout
    buf = StringIO.new
    $stdout = buf
    at_exit do
      $stdout = real
      next if $!

      text, summary = instrument(buf.string, symbol, infos)
      warn "== PARAM_TRACE: #{summary[:sites].size} parameters, #{summary[:rets].size} returns and #{summary[:ivars].size} ivar reads of #{summary[:fns].size} functions instrumented in #{symbol} " \
           "(skipped: #{summary[:skipped].map { |k, v| "#{k} #{v}" }.join(', ').then { |s| s.empty? ? 'none' : s }}) =="
      real.write(text)
    end
  end
end
