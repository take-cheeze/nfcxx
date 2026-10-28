# frozen_string_literal: true

require 'stringio'
require_relative 'else_trace'
require_relative 'block_yielders'

# PARAM_TRACE: opt-in runtime classes of the parameters of compiled methods and blocks, of the values
# their `return` statements hand back (RETURN_SITE rows), of the values an ivar read hands back
# (IVAR_SITE rows, one per owner class and ivar name), of the values a constant read hands back
# (CONST_SITE rows, one per constant read, named by the owner it resolved to), and of the method that yields to
# each block body (BLOCK_YIELD rows, see block_yielders.rb).
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
#     a NATIVE_ARGS parameter (mrb_int) is boxed for the count;
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
  # Elements (Array) or entries (Hash) sampled per container hit. The rest are counted as overflow, never dropped.
  ELEM_SAMPLE = 32
  # The impl header: `mrb_value Foo_bar_impl(mrb_state* M, mrb_value self, <params>) {`.
  HEADER_RE = /\A(?:static )?mrb_value ([\w$]+_impl)\(mrb_state\* M, mrb_value self((?:, [^,()]+)*)\) \{\s*\z/
  BARG_RE = /\Abc2cpp_barg(\d+)\z/
  KWARG_RE = /\Abc2cpp_kwarg_([\w$]+)\z/
  KW_GIVEN_RE = /\Abc2cpp_kw_given_([\w$]+)\z/
  REG0_RE = /\A\s*(?:\[\[maybe_unused\]\] )?mrb_value r0 = self;/
  # Left by codegen after a GETIV (codegen_insn.rb ivar_trace_marker): the owner class, the ivar and its register.
  IVAR_MARKER_RE = %r{\A\s*/\*BC2CPP_IVAR_HIT (\S+) (@\S+) r(\d+)\*/\s*\z}
  # Left after a GETCONST/GETMCNST (codegen_insn.rb const_trace_marker): the resolved owner key (`-` when unproven),
  # the name as written and the register.
  CONST_MARKER_RE = %r{\A\s*/\*BC2CPP_CONST_HIT (\S+) (\S+) r(\d+)\*/\s*\z}
  REG0_WINDOW = 12
  # C parameter type => the expression that boxes it back to an mrb_value (TYPE_OPS[...][:box]).
  BOX = { 'mrb_value' => '%s', 'mrb_int' => 'mrb_fixnum_value(%s)', 'mrb_sym' => 'mrb_symbol_value(%s)',
          'mrb_bool' => 'mrb_bool_value(%s)' }.freeze

  module_function

  # Facts for one compiled method: mandatory count, optional count, rest, the registry arity of its name
  # and the proven facts per positional index, as strings "kind=value".
  #   argtypes  ArgTypes (call-site :fixnum/:symbol)         classarg  ClassArgTypes (call-site class)
  #   entryfix  ENTRY_ARG_CALLSITE_PROOF                      numeric   entry_arg_numeric mask
  #   pool      CLASS_POOLS argument pool                     annot     NATIVE_ARGS annotation
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
  # A preprocessor conditional line; group 1 is its directive.
  PP_RE = /\A\s*#\s*(ifdef|ifndef|if|elif|else|endif)\b/
  # A C++ lambda inside a generated body: its own `return` answers the lambda, not the method.
  LAMBDA_RE = /\[(?:&|=)?\]\s*\(/

  # Wraps each `return EXPR;` of the function whose header is lines[start] (not the ones inside a lambda
  # nested in it) so the returned value is recorded. Appends one row per wrapped return to rets.
  def wrap_returns(lines, start, rets, ident, method, fn, block, ret_fact)
    depth = lines[start].count('{') - lines[start].count('}')
    lambda_depth = nil
    ordinal = 0
    arms = [] # per open #if: [depth at the #if, depth at the end of the arm before its #else]
    k = start + 1
    while k < lines.size && depth.positive?
      line = lines[k]
      if (pp = PP_RE.match(line))
        # Every arm of a conditional is in the text but only one is compiled, so an arm's braces must not add to the
        # next arm's. Counting them all leaves the depth too high for an `#ifdef`/`#else` pair that opens a brace in
        # each arm, and the wrap then runs on into the following functions (see the `return` attribution check).
        case pp[1]
        when 'if', 'ifdef', 'ifndef' then arms << [depth, nil]
        when 'else', 'elif'
          if (arm = arms.last)
            arm[1] = depth
            depth = arm[0]
          end
        when 'endif' then arms.pop
        end
        k += 1
        next
      end
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
  # block_yields: { body `_impl` => BlockYielders::Join } (the BLOCK_YIELD rows of the dump; see block_yielders.rb).
  def instrument(cpp, symbol, infos, block_yields = {})
    lines = cpp.lines
    fns = []
    sites = []
    rets = []
    ivars = []
    consts = []
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
        if (mk = IVAR_MARKER_RE.match(lines[x]))
          vid = ivars.size
          ivars << { id: vid, owner: mk[1], ivar: mk[2] }
          lines[x] = "  bc2cpp_ivar_hit_#{ident}(M, #{vid}, r#{mk[3]});\n"
        elsif (mk = CONST_MARKER_RE.match(lines[x]))
          cid = consts.size
          consts << { id: cid, key: mk[1], written: mk[2] }
          lines[x] = "  bc2cpp_const_hit_#{ident}(M, #{cid}, r#{mk[3]});\n"
        end
      end
      lines[j] = "  bc2cpp_param_enter_#{ident}(#{fnid}); #{stmts.join(' ')} #{lines[j].lstrip}"
      sites.last(stmts.size).each { |s| s[:fnid] = fnid }
    end
    summary = { fns: fns, sites: sites, rets: rets, ivars: ivars, consts: consts, skipped: skipped, block_yields: block_yields,
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
    consts = summary[:consts]
    nconsts = [consts.size, 1].max
    constmeta = consts.empty? ? '""' : consts.map { |c| ElseTrace.c_string("#{c[:key]}\t#{c[:written]}") }.join(",\n  ")
    meta = sites.empty? ? '""' : sites.map { |s| ElseTrace.c_string(s[:meta]) }.join(",\n  ")
    retmeta = rets.empty? ? '""' : rets.map { |r| ElseTrace.c_string(r[:meta]) }.join(",\n  ")
    fnmeta = fns.empty? ? '""' : fns.map { |f| ElseTrace.c_string([f[:method], f[:fn], f[:block] ? 'block' : 'method'].join("\t")) }.join(",\n  ")
    # One BLOCK_YIELD row per block body: the method that yields to it, or the reason it has none.
    block_yields = summary[:block_yields]
    yield_lines = fns.select { |f| f[:block] }.map do |f|
      join = block_yields.fetch(f[:fn]) { BlockYielders::Join.new(key: nil, arity: nil, reason: :no_origin) }
      row = ['BLOCK_YIELD', symbol, f[:fn], join.key || '-', join.arity || '-', join.reason].join("\t") + "\n"
      "fputs(#{ElseTrace.c_string(row)}, f);"
    end
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
      #define BC2CPP_ELEM_SAMPLE #{ELEM_SAMPLE}
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
      // Samples the first BC2CPP_ELEM_SAMPLE elements of an Array (entries of a Hash), one level deep. The
      // unsampled tail goes to overflow, so its slot is never read as complete.
      static void bc2cpp_elem_record_#{id}(struct bc2cpp_param_site_#{id}* t, mrb_state* M, mrb_value v) {
        if (mrb_array_p(v)) {
          mrb_int n = ary_size(v);
          mrb_int m = n < BC2CPP_ELEM_SAMPLE ? n : BC2CPP_ELEM_SAMPLE;
          for (mrb_int i = 0; i < m; i++) bc2cpp_site_record_#{id}(&t[0], M, mrb_ary_ref(M, v, i));
          t[0].overflow += n - m;
        } else if (mrb_hash_p(v)) {
          mrb_value keys = mrb_hash_keys(M, v);
          mrb_int n = ary_size(keys);
          mrb_int m = n < BC2CPP_ELEM_SAMPLE ? n : BC2CPP_ELEM_SAMPLE;
          for (mrb_int i = 0; i < m; i++) {
            mrb_value k = mrb_ary_ref(M, keys, i);
            bc2cpp_site_record_#{id}(&t[1], M, k);
            bc2cpp_site_record_#{id}(&t[2], M, mrb_hash_get(M, v, k));
          }
          t[1].overflow += n - m;
          t[2].overflow += n - m;
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
      // One site per constant read: the owner it resolved to (`-` when unproven) and the name as written.
      static struct bc2cpp_param_site_#{id} bc2cpp_const_sites_#{id}[#{nconsts}];
      static const char* const bc2cpp_const_meta_#{id}[#{nconsts}] = {
        #{constmeta}
      };
      static inline void bc2cpp_const_hit_#{id}(mrb_state* M, unsigned site, mrb_value v) {
        bc2cpp_site_record_#{id}(&bc2cpp_const_sites_#{id}[site], M, v);
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
        #{yield_lines.join("\n        ")}
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
        for (unsigned i = 0; i < #{consts.size}; i++) {
          struct bc2cpp_param_site_#{id}* s = &bc2cpp_const_sites_#{id}[i];
          fprintf(f, "CONST_SITE\\t%s\\t%u\\t%llu\\t%llu\\t%s\\n", "#{symbol}", i, s->calls, s->overflow, bc2cpp_const_meta_#{id}[i]);
          for (unsigned j = 0; j < s->ncls; j++)
            fprintf(f, "CONST_CLASS\\t%s\\t%u\\t%s\\t%llu\\n", "#{symbol}", i, s->cls[j].name, s->cls[j].count);
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
  def capture_stdout(symbol, infos, block_yields = {})
    real = $stdout
    buf = StringIO.new
    $stdout = buf
    at_exit do
      $stdout = real
      next if $!

      text, summary = instrument(buf.string, symbol, infos, block_yields)
      warn "== PARAM_TRACE: #{summary[:sites].size} parameters, #{summary[:rets].size} returns, #{summary[:ivars].size} ivar reads and " \
           "#{summary[:consts].size} constant reads of #{summary[:fns].size} functions instrumented in #{symbol} " \
           "(skipped: #{summary[:skipped].map { |k, v| "#{k} #{v}" }.join(', ').then { |s| s.empty? ? 'none' : s }}) =="
      real.write(text)
    end
  end
end
