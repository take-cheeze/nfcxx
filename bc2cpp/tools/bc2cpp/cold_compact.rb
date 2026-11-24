# frozen_string_literal: true

require 'digest'
require 'set'
require_relative 'world_root'

# COLD_COMPACT: in a method the sweep profile lists as cold (sig/bc2cpp/cold_methods.txt in the world), the text of an
# arithmetic or compare instruction moves into a file-scope noinline helper and the site becomes one call. The helper
# body is the instruction's own text with its registers renamed to parameters, so it runs the same statements on the
# same values; `outline` refuses any text where that renaming could change what runs (see outline_refusal). An unlisted
# method keeps the inline text, so a stale profile can only cost size. BC2CPP_COLD_COMPACT=0 turns it off.
#
# COLD_COMPACT_TAIL: in every other method, an ADD/SUB/MUL/ADDI/SUBI/DIV keeps its Fixnum (DIV: Integer pair) tier
# inline and only the arms after it (overflow, heap Integer, Float, the operator send) move into a helper of the same
# kind; see split_tail.
# BC2CPP_COLD_COMPACT_TAIL=0 turns it off.
#
# COLD_PROFILE (BC2CPP_COLD_PROFILE=1): each compiled method body counts its calls, and the host writes the counts to
# BC2CPP_COLD_PROFILE_DIR at exit; scripts/bc2cpp/cold_profile.bash turns a host sweep's counts into the list.
module ColdCompact
  LIST_KEY = 'BC2CPP_COLD_LIST'
  DEFAULT_LIST = File.join(BC2CPP_WORLD_ROOT, 'sig/bc2cpp/cold_methods.txt')
  OPS = %i[ADD ADDI SUB SUBI MUL DIV EQ LT LE GT GE].to_set.freeze

  # Callees a helper body may name. Each takes its operands by value (or is a macro over values), so a renamed
  # register is read, never written, through it; bc2cpp_fixnum_* write their third argument, which must be the
  # destination (checked in outline_refusal). A helper printed only when a method's text names it (bc2cpp_num_cmp)
  # is not one: the scan that prints it does not read the helpers here. bc2cpp_cmp_num_* are: CMP_NUM_OUTLINE prints
  # them whenever it is on, and only then does a compare's text name them.
  CALLEES = %w[
    mrb_likely mrb_unlikely mrb_fixnum_p mrb_integer_p mrb_float_p mrb_undef_p mrb_symbol_p mrb_nil_p
    mrb_fixnum mrb_integer mrb_float mrb_fixnum_value mrb_bool_value mrb_true_value mrb_false_value mrb_nil_value
    mrb_obj_eq mrb_equal mrb_num_add mrb_num_sub mrb_num_mul mrb_div_int_value mrb_int_value
    BC2CPP_FIXNUM_PAIR_P BC2CPP_FIXNUM_WORD bc2cpp_fixnum_add bc2cpp_fixnum_sub bc2cpp_fixnum_mul
    bc2cpp_num_add_float bc2cpp_num_sub_float bc2cpp_num_mul_float bc2cpp_num_div_float
    bc2cpp_slow_add bc2cpp_slow_add_f bc2cpp_slow_sub bc2cpp_slow_sub_f bc2cpp_slow_mul bc2cpp_slow_mul_f
    bc2cpp_slow_div bc2cpp_slow_div_f bc2cpp_slow_lt bc2cpp_slow_lt_f bc2cpp_slow_le bc2cpp_slow_le_f
    bc2cpp_slow_gt bc2cpp_slow_gt_f bc2cpp_slow_ge bc2cpp_slow_ge_f
    mrb_type mrb_string_p mrb_obj_ptr mrb_float_value mrb_div_float mrb_as_float mrb_str_equal mrb_obj_equal
    bc2cpp_cmp_num_lt bc2cpp_cmp_num_le bc2cpp_cmp_num_gt bc2cpp_cmp_num_ge bc2cpp_cmp_num_eq
  ].to_set.freeze
  OUT_PARAM = /\bbc2cpp_fixnum_(?:add|sub|mul)\(/
  KEYWORDS = %w[if else].to_set.freeze
  DIRECTIVE = /\A\s*#\s*(?:(?:ifdef|ifndef)\s+MRB_\w+|if(?:\s*(?:!|\|\||&&|defined\(MRB_\w+\)))+|else|endif)\s*\z/
  TEMP_DECL = /\A\s*\{?\s*mrb_value bc2cpp_nt;\s*\z/

  module_function

  def enabled?
    ENV['BC2CPP_COLD_COMPACT'] != '0'
  end

  def profile?
    ENV['BC2CPP_COLD_PROFILE'] == '1'
  end

  def tail?
    enabled? && ENV['BC2CPP_COLD_COMPACT_TAIL'] != '0'
  end

  TAIL_OPS = %i[ADD SUB MUL ADDI SUBI DIV].to_set.freeze
  PAIR_TEST = /\ABC2CPP_FIXNUM_PAIR_P\((r\d+), (r\d+)\)\z/
  IMM_TEST = /\Amrb_fixnum_p\((r\d+)\)\z/
  TIER = /\A\s*if \((.*)\) \{ (r\d+) = mrb_num_(add|sub|mul)\(M, (r\d+), ([^;]*)\); \}\n\z/

  # `cond` without the BranchHints wrapper `hint` (BC2CPP_BRANCH_HINTS=0 prints none).
  def unhinted(cond, hint)
    cond.start_with?("#{hint}(") && cond.end_with?(')') ? cond[(hint.size + 1)...-1] : cond
  end

  # [fast, tail] for an arithmetic instruction's text: `fast`, the condition under which the Fixnum tier has stored
  # the result, and `tail`, the arms after the tier as one statement; nil for any other shape (a guarded range arm, a
  # proven operand). The tier (TaggedFixnum.tier) leaves the destination untouched when it reports an overflow and
  # then runs mrb_num_* on the operands; the tail must open with the Integer arm, which runs that same call on them
  # (two Fixnums are Integers), so `if (!fast) tail` runs what the whole text runs.
  def split_tail(text)
    div = split_div_tail(text)
    return div if div

    lines = text.lines
    pair = lines.first.match?(/\A\s*\{ mrb_value bc2cpp_nt;\n\z/)
    lines.shift if pair
    test = lines[0].to_s[/\A\s*if \((.*)\) \{\n\z/, 1]
    tier = TIER.match(lines[1].to_s)
    return nil unless test && tier

    m = (pair ? PAIR_TEST : IMM_TEST).match(unhinted(test, 'mrb_likely'))
    return nil unless m

    dest = m[1]
    rhs = pair ? m[2] : tier[5]
    return nil unless pair || rhs.match?(/\Amrb_fixnum_value\(-?\d+\)\z/)

    op = tier[3]
    overflow = unhinted(tier[1], 'mrb_unlikely')
    return nil unless overflow == "bc2cpp_fixnum_#{op}(#{dest}, #{rhs}, #{dest})" && tier[2] == dest &&
                      tier[4] == dest && tier[5] == rhs

    integer = pair ? "mrb_integer_p(#{dest}) && mrb_integer_p(#{rhs})" : "mrb_integer_p(#{dest})"
    return nil unless lines[2] == "} else if (#{integer}) {\n" && lines[3].to_s.strip == "#{dest} = mrb_num_#{op}(M, #{dest}, #{rhs});"

    chain = whole_chain("  if #{lines[2..].join.delete_prefix('} else if ')}", pair)
    return nil unless chain

    ["#{test} && !#{tier[1]}", "#{pair ? "{ mrb_value bc2cpp_nt;\n" : ''}#{chain}\n#{pair ? "}\n" : ''}"]
  end

  # `text` less its closing brace (with `close`) when, under every choice of arms of its #if lines, it is one if/else
  # chain and that brace; nil otherwise. A statement after the chain would run on the fast path too, so it may not move.
  def whole_chain(text, close)
    conds = text.lines.count { |l| l.match?(/\A\s*#\s*if/) }
    return nil if conds > 4

    ok = (0...(1 << conds)).all? do |bits|
      t = preprocess(text, bits)
      stop = t.index('(') && ColdCompactCalls.chain_end(t, t.index('('))
      stop && t[stop..].strip == (close ? '}' : '')
    end
    return nil unless ok

    close ? text[0...text.rindex('}')].rstrip : text.rstrip
  end

  # `text` with the directive lines dropped and, of the n-th #if, the #else arm kept when bit n of `bits` is set.
  def preprocess(text, bits)
    stack = []
    n = 0
    text.lines.filter_map do |l|
      if l.match?(/\A\s*#\s*if/)
        stack.push(bits[n].zero?)
        n += 1
        nil
      elsif l.match?(/\A\s*#\s*else/)
        stack[-1] = !stack[-1] unless stack.empty?
        nil
      elsif l.match?(/\A\s*#\s*endif/)
        stack.pop
        nil
      elsif stack.all?
        l
      end
    end.join
  end

  DIV_TEST = /\Amrb_integer_p\((r\d+)\) && mrb_integer_p\((r\d+)\)\z/
  DIV_PAIR = /\A\s*(r\d+) = (?:bc2cpp_div_int_pair\(M, (r\d+), (r\d+)\)|mrb_div_int_value\(M, mrb_integer\((r\d+)\), mrb_integer\((r\d+)\)\));\n\z/

  # DIV's Integer pair arm is a call already, so the tail is its `else` as a whole: [fast, tail, fast_stmt].
  def split_div_tail(text)
    lines = text.lines
    return nil unless lines.first.match?(/\A\s*\{ mrb_value bc2cpp_nt;\n\z/)

    test = lines[1].to_s[/\A\s*if \((.*)\) \{\n\z/, 1]
    m = test && DIV_TEST.match(unhinted(test, 'mrb_likely'))
    stmt = m && DIV_PAIR.match(lines[2].to_s)
    return nil unless stmt && stmt[1] == m[1] && [stmt[2] || stmt[4], stmt[3] || stmt[5]] == [m[1], m[2]]
    return nil unless lines[3].to_s.start_with?('} else if (!mrb_undef_p(bc2cpp_nt = bc2cpp_num_div_float(')

    chain = whole_chain("  if #{lines[3..].join.delete_prefix('} else if ')}", true)
    return nil unless chain

    [test, "{ mrb_value bc2cpp_nt;\n#{chain}\n}\n", lines[2].strip]
  end

  def list_path
    ENV.fetch(LIST_KEY, DEFAULT_LIST)
  end

  # The cold method keys (`Owner#name`, one per line; a line starting with `#` is a comment), or nil with no list. A
  # `*` line lists every method.
  def cold_methods
    return @cold_methods if defined?(@cold_methods)

    path = list_path
    @cold_methods = if enabled? && File.file?(path)
                      File.readlines(path, chomp: true).map(&:strip).reject { |l| l.empty? || l.start_with?('#') }.to_set
                    end
  end

  def cold?(key)
    set = cold_methods
    !set.nil? && (set.include?('*') || set.include?(key))
  end

  # Outlines and refusals by reason over every compile of a method (probes included), for the stderr summary.
  def stats
    @stats ||= Hash.new(0)
  end

  # [call_text, name, body] for `text`, or nil when it stays inline.
  def outline(text)
    lines = text.lines.map { |l| l.gsub(%r{/\*.*?\*/}, '').sub(%r{//.*}, '').rstrip }.reject { |l| l.strip.empty? }
    code = lines.reject { |l| l.match?(DIRECTIVE) }.join("\n")
    refusal = outline_refusal(lines, code)
    stats[refusal || :outlined] += 1
    return nil if refusal

    regs = code.scan(/\br\d+\b/).uniq
    dest = assigned(code).grep(/\Ar\d+\z/).first
    params = regs.each_with_index.to_h { |r, i| [r, "a#{i}"] }
    body = lines.join("\n").gsub(/\br\d+\b/) { |r| params.fetch(r) }
    name = "bc2cpp_compact_#{Digest::SHA256.hexdigest(body)[0, 16]}"
    source = "static __attribute__((noinline, cold)) mrb_value #{name}(mrb_state* M, " \
             "#{params.values.map { |p| "mrb_value #{p}" }.join(', ')}) {\n#{body}\n  return #{params.fetch(dest)};\n}\n\n"
    ["  #{dest} = #{name}(M, #{regs.join(', ')});\n", name, source]
  end

  # Why `text` must stay inline (nil when it may move). The helper sees file scope instead of the method's, so every
  # name must mean the same there: registers (now parameters), M, CALLEES, MRB_TT_* tags, struct members read through
  # `->`/`.`, and a temporary the text declares itself. Only the one destination register (and that temporary) may be
  # written, and no keyword but if/else leaves room for a jump: control only falls off the end.
  def outline_refusal(lines, code)
    return :string if code.include?('"') || code.include?("'") || code.include?('/*')
    return :directive if lines.any? { |l| l.lstrip.start_with?('#') && !l.match?(DIRECTIVE) }
    return :braces unless balanced?(lines)
    return :address if code.match?(/(?<![&\w)\]])&\s*[A-Za-z_]/) || code.match?(/\+\+|--|(?:[-+*\/%&|^]|<<|>>)=/)

    temp = lines.first.match?(TEMP_DECL)
    code.scan(/(->|\.)?\s*\b([A-Za-z_]\w*)\b/).each do |member, id|
      next if member || id.match?(/\Ar\d+\z/) || id == 'M' || KEYWORDS.include?(id) || CALLEES.include?(id)
      next if id.match?(/\AMRB_TT_[A-Z_]+\z/) || (temp && %w[bc2cpp_nt mrb_value].include?(id))

      return :"name #{id}"
    end
    written = assigned(code)
    return :write unless written&.all? { |lhs| lhs.match?(/\Ar\d+\z/) || (temp && lhs == 'bc2cpp_nt') }

    dests = written.grep(/\Ar\d+\z/).uniq
    return :dest unless dests.size == 1
    return :out_param unless out_params(code).all? { |arg| arg == dests.first }

    nil
  end

  # The names `code` assigns with `=`, or nil when a left-hand side is not a plain name.
  def assigned(code)
    code.to_enum(:scan, /(?<![=!<>])=(?!=)/).map do
      lhs = Regexp.last_match.pre_match.rstrip
      name = lhs[/(?<![\w.>])([A-Za-z_]\w*)\z/, 1]
      return nil unless name

      name
    end
  end

  # Braces balance in the text a preprocessor keeping every first arm sees (both arms of an #if repeat a `{`).
  def balanced?(lines)
    depth = 0
    skip = []
    lines.each do |l|
      if l.match?(/\A\s*#\s*if/)
        skip.push(skip.last || false)
      elsif l.match?(/\A\s*#\s*else/)
        return false if skip.empty?

        skip[-1] = true
      elsif l.match?(/\A\s*#\s*endif/)
        return false if skip.pop.nil?
      elsif !skip.last
        depth += l.count('{') - l.count('}')
        return false if depth.negative?
      end
    end
    depth.zero? && skip.empty?
  end

  # The third argument of every bc2cpp_fixnum_* call in `code`.
  def out_params(code)
    args = []
    code.scan(OUT_PARAM) do
      rest = Regexp.last_match.post_match
      depth = 0
      parts = ['']
      rest.each_char do |c|
        break if c == ')' && depth.zero?

        depth += 1 if c == '('
        depth -= 1 if c == ')'
        c == ',' && depth.zero? ? parts << '' : parts[-1] += c
      end
      args << parts[2].to_s.strip
    end
    args
  end

  # COLD_PROFILE: the counter type, once per translation unit; each unit writes its own file at exit.
  PROFILE_PRELUDE = <<~'CPP'
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    namespace {
    struct Bc2cppColdCounter {
      const char* key;
      unsigned long long n;
      Bc2cppColdCounter* next;
      static Bc2cppColdCounter*& head() { static Bc2cppColdCounter* h = nullptr; return h; }
      explicit Bc2cppColdCounter(const char* k) : key(k), n(0), next(head()) { head() = this; }
    };
    struct Bc2cppColdDump {
      ~Bc2cppColdDump() {
        const char* dir = getenv("BC2CPP_COLD_PROFILE_DIR");
        if (!dir || !Bc2cppColdCounter::head()) return;
        char path[4096];
        snprintf(path, sizeof path, "%s/cold-%ld-%p.tsv", dir, (long)getpid(), (void*)&Bc2cppColdCounter::head());
        FILE* f = fopen(path, "w");
        if (!f) return;
        for (Bc2cppColdCounter* c = Bc2cppColdCounter::head(); c; c = c->next) fprintf(f, "%s\t%llu\n", c->key, c->n);
        fclose(f);
      }
    } bc2cpp_cold_profile_dump;
    }
    #define BC2CPP_COLD_PROFILE_HIT(key) do { static Bc2cppColdCounter bc2cpp_cold_profile_counter(key); bc2cpp_cold_profile_counter.n++; } while (0)
  CPP

  # A key is printed into a C string; method names are Ruby identifiers or operators, never a quote or backslash.
  def profile_line(key)
    raise "COLD_PROFILE: #{key.inspect} cannot be a C string" if key.match?(/["\\\n]/)

    "  BC2CPP_COLD_PROFILE_HIT(\"#{key}\");\n"
  end
end

class CodeGen
  # COLD_COMPACT: `text`, instruction `insn`'s code in method `d`, or the call to its helper.
  def cold_compact(insn, text, d)
    return text if @resumable || !ColdCompact::OPS.include?(insn.op)
    return cold_compact_tail(insn, text) unless ColdCompact.cold?("#{d.owner}##{d.name}")

    call, name, source = ColdCompact.outline(text)
    return text unless call

    (@cold_compact_helpers ||= {})[name] ||= source
    call
  end

  # COLD_COMPACT_TAIL: `text` with the arms after its Fixnum tier as one helper call (ColdCompact.split_tail).
  def cold_compact_tail(insn, text)
    return text unless ColdCompact.tail? && ColdCompact::TAIL_OPS.include?(insn.op)

    fast, tail, fast_stmt = ColdCompact.split_tail(text)
    return text unless tail

    call, name, source = ColdCompact.outline(tail)
    return text unless call

    ColdCompact.stats[:tail] += 1
    (@cold_compact_helpers ||= {})[name] ||= source
    # The arms' tags (FIXNUM_ARITHMETIC, ...) stay at the site, which still makes the send they mark.
    notes = tail.scan(%r{//[^\n]*}).uniq.map { |note| "  #{note}\n" }.join
    "  if (#{fast}) {\n#{"  #{fast_stmt}\n" if fast_stmt}  } else {\n#{notes}#{call}  }\n"
  end

  # File-scope definitions of the helpers `codes` call, and the COLD_PROFILE counter when that is on; computed on the
  # first call, which names the codes.
  def cold_compact_code(codes = nil)
    @cold_compact_code ||= emit_cold_compact_helpers(codes)
  end

  def emit_cold_compact_helpers(codes)
    prelude = ColdCompact.profile? ? ColdCompact::PROFILE_PRELUDE : ''
    helpers = @cold_compact_helpers || {}
    return prelude if helpers.empty?

    used = codes.flat_map { |c| (c.is_a?(Hash) ? c[:code] : c).to_s.scan(/\bbc2cpp_compact_\h{16}\b/) }.uniq.sort
    prelude + used.map { |name| helpers.fetch(name) }.join
  end

  def cold_compact_summary
    helpers = cold_compact_code.scan(/^static __attribute__\(\(noinline, cold\)\) mrb_value /).size
    refused = ColdCompact.stats.reject { |k, _| %i[outlined tail].include?(k) }.sort_by { |k, n| [-n, k.to_s] }.map { |k, n| "#{k} #{n}" }
    "== cold compact (COLD_COMPACT): #{ColdCompact.stats[:outlined]} outlines (probe compiles included, " \
      "#{ColdCompact.stats[:tail]} arithmetic tails) into #{helpers} helpers; refused: #{refused.empty? ? 'none' : refused.join(', ')} =="
  end
end
