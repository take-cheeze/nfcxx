# frozen_string_literal: true

require 'digest'
require 'set'
require_relative 'bytecode_ir'

# RESCUE_SHARED_HANDLER: in a rescue handler, the run that logs the failure (`$stderr.puts "[RPG2k] ...: #{e.message}"`,
# GETGV $stderr through `SEND :puts n=1`) moves into a file-scope helper, and the site becomes one call. Handlers are
# near-identical, so most share a helper: its body is the run's own text with the registers, the declared locals and
# the pool literals made parameters, so it runs the same statements on the same values and prints the same bytes.
# BC2CPP_RESCUE_SHARED_HANDLER=0 turns it off.
#
# Soundness: the run writes only its own temporaries (registers from the GETGV's up, which the `puts` send's frame
# clobbers in the VM, so nothing after the run reads them) and returns the send's result in the GETGV's register; no
# instruction after the first is a jump target, so control enters at the top and leaves at the end or by an exception.
# The text gate (refusal) keeps every name meaning the same at file scope.
module RescueSharedHandler
  PREFIX = 'bc2cpp_rh_'
  PLACEHOLDER = /\bbc2cpp_rh_(\h{16})\b/
  # A site's literal argument: the pool string's own spelling, which the static dispatch scan knows as one
  # (static_dispatch_registrations.rb, POOL_STRING_VALUE). Defined in each unit that holds a site.
  LIT_MACRO = "#ifndef BC2CPP_RH_LIT\n#define BC2CPP_RH_LIT(s) s\n#endif\n"
  # The ops a run may hold between its GETGV and its `puts`: string building, plain reads and sends without a block.
  OPS = (Set[:STRING, :STRCAT, :MOVE, :SEND, :SEND0, :SSEND, :SSEND0, :GETIV, :GETCONST, :GETMCNST, :LOADNIL,
             :LOADSELF, :LOADSYM, :LOADTRUE, :LOADFALSE, :LOADL, :INTERN] | BytecodeIR::Ops::LOADI_OPS).freeze
  MAX_RUN = 64
  LIT = /"(?:[^"\\\n]|\\.)*"/
  # A pool string the run builds or appends; its bytes become a `const char*` parameter (no NUL, so strlen is N - 1).
  POOL_LIT = /\b(bc2cpp_pool_str\(M, |bc2cpp_str_cat_lit\(M, r\d+, )("(?:[^"\\\n]|\\.)+")\)/
  CONTROL = /\b(?:goto|return|break|continue|switch|case|default|for|while|do|static|throw|try|catch|asm|__asm__|
              __LINE__|__COUNTER__|__func__|setjmp|longjmp|this|operator|template)\b/x
  KEYWORDS = %w[if else struct sizeof const nullptr true false].to_set.freeze
  TYPES = %w[mrb_value mrb_int mrb_float mrb_sym mrb_bool mrb_state bool int unsigned size_t uint32_t int32_t uint8_t
             int8_t uint16_t int16_t uint64_t int64_t uintptr_t intptr_t double float char long auto void].to_set.freeze
  # Calls the closed-world reports count per site (bc2cpp.rb), and the guard-violation family a message names.
  COUNTED = /\b(?:bc2cpp_nomethod|bc2cpp_guard_violation|bc2cpp_nil_receiver)\b/
  VIOLATION_FAMILY = /"[^"\n]* \((?:[A-Z_]+)\)"/
  SYM_MACRO = /\bMRB_(?:SYM|IVSYM|GVSYM|CVSYM|OPSYM|QSYM)(?:_[QBE])?\(\s*\w*\s*\)/
  IDENT = /(?<![\w$])[A-Za-z_][\w$]*/
  DECL = /\b(?:mrb_value|mrb_int|mrb_sym|mrb_bool|mrb_float|bool|int|size_t|(?:struct\s+)?R[A-Z]\w*|\w+_ivars)\s*\*?\s*([A-Za-z_]\w*)\s*(?==|\[|;)/

  module_function

  def enabled?
    ENV['BC2CPP_RESCUE_SHARED_HANDLER'] != '0'
  end

  def stats
    @stats ||= Hash.new(0)
  end

  # {name => source} of every helper outlined so far (the placeholder name; place renames it per gem).
  def helpers
    @helpers ||= {}
  end

  # The call replacing +texts+ (a run's instruction texts, in order) whose result is register +dest+, or nil when the
  # run stays inline. Records the helper's source under its name.
  def outline(texts, dest)
    site_notes, body = split_comments(texts.join)
    refusal = refusal(body, dest)
    stats[refusal || :outlined] += 1
    return nil if refusal

    lits = []
    body = body.gsub(POOL_LIT) do
      head = Regexp.last_match(1)
      lits << Regexp.last_match(2)
      call = head.start_with?('bc2cpp_pool_str') ? 'mrb_str_new_cstr(M, ' : head.sub('bc2cpp_str_cat_lit(', 'mrb_str_cat_cstr(')
      "#{call}bc2cpp_rhl#{lits.size - 1})"
    end
    plain = body.gsub(LIT, '""')
    locals = plain.scan(DECL).flatten.uniq
    locals.each_with_index { |name, i| body = body.gsub(/(?<![\w$])#{name}(?![\w$])/, "bc2cpp_rhv#{i}") }
    inputs, temps = register_roles(plain)
    order = (inputs + temps).uniq
    names = order.each_with_index.to_h { |r, i| [r, "a#{i}"] }
    names["r#{dest}"] ||= "a#{names.size}"
    body = body.gsub(/\br\d+\b/) { |r| names.fetch(r) }
    uses_self = plain.match?(/(?<![\w$.>])self\b/)
    params = ['mrb_state* M']
    params << 'mrb_value self' if uses_self
    params.concat(inputs.map { |r| "mrb_value #{names.fetch(r)}" })
    params.concat(lits.each_index.map { |i| "const char* bc2cpp_rhl#{i}" })
    decls = (names.keys - inputs).map { |r| "  mrb_value #{names.fetch(r)} = mrb_nil_value();\n" }.join
    sig = "(#{params.join(', ')})"
    fn_body = "#{sig} {\n#{decls}#{body}\n  return #{names.fetch("r#{dest}")};\n}\n"
    name = "#{PREFIX}#{Digest::SHA256.hexdigest(fn_body)[0, 16]}"
    helpers[name] ||= fn_body
    args = ['M']
    args << 'self' if uses_self
    args.concat(inputs)
    args.concat(lits.map { |lit| "BC2CPP_RH_LIT(#{lit})" })
    "#{site_notes}  r#{dest} = #{name}(#{args.join(', ')});\n"
  end

  # [the comments of +text+ as lines for the site, its code without them]. The site keeps the comments: the reports
  # list markers (`/* CLOSED_WORLD ... */`, STRICT_HINT) by the method whose text holds them.
  def split_comments(text)
    notes = String.new
    lines = []
    text.each_line do |line|
      masked = line.gsub(LIT) { |s| "\"#{'x' * (s.size - 2)}\"" }
      while (open = masked.index('/*')) && (close = masked.index('*/', open + 2))
        notes << "  #{line[open..close + 1]}\n"
        line = line[0...open] + line[(close + 2)..]
        masked = masked[0...open] + masked[(close + 2)..]
      end
      if (at = masked.index('//'))
        notes << "  #{line[at..].strip}\n"
        line = line[0...at]
      end
      lines << line.rstrip unless line.strip.empty?
    end
    [notes, lines.join("\n")]
  end

  # Why +body+ (the run's code, comments gone) must stay inline, or nil. The helper sees file scope, so a bare name
  # may only be a register, M, self, a local the text declares, a type, a macro or a called function; the text may
  # write only temporaries (registers from +dest+ up) and its own locals; and nothing may jump, return or name the
  # method (@@SITE@@) or a generated diagnostic the reports count per site.
  def refusal(body, dest)
    plain = body.gsub(LIT, '""')
    return :comment if plain.include?('/*') || plain.include?('//')
    return :directive if plain.match?(/^\s*#/)
    return :site if body.include?('@@SITE@@') || plain.match?(COUNTED) || body.match?(VIOLATION_FAMILY)
    return :control if plain.match?(CONTROL) || plain.match?(/\bL\d+:/)
    return :address if plain.match?(/&\s*r\d+\b/) || plain.match?(/\+\+|--/)
    return :nul if body.scan(POOL_LIT).any? { |_, lit| lit.include?('\\x00') }
    return :braces unless balanced?(plain)

    locals = plain.scan(DECL).flatten.to_set
    scan = plain.gsub(SYM_MACRO, 'MRB_SYM()')
    scan.to_enum(:scan, IDENT).each do
      m = Regexp.last_match
      id = m[0]
      before = scan[0...m.begin(0)]
      after = scan[m.end(0)..]
      next if before.match?(/(?:->|\.)\s*\z/) || after.match?(/\A\s*\(/)
      next if id.match?(/\Ar\d+\z/) || %w[M self].include?(id) || KEYWORDS.include?(id) || TYPES.include?(id)
      next if locals.include?(id) || id.match?(/\A(?:R[A-Z]\w*|\w+_ivars|(?:MRB|BC2CPP)_[A-Z0-9_]+)\z/)

      return :"name #{id}"
    end
    plain.to_enum(:scan, /(?<![=!<>+\-*\/%&|^])(?:[+\-*\/%&|^]|<<|>>)?=(?!=)/).each do
      lhs = Regexp.last_match.pre_match.rstrip
      next if lhs.match?(/(?:->|\.)\s*\w+\z/) || lhs.match?(/\]\z/)

      name = lhs[/(?<![\w$])([A-Za-z_]\w*)\z/, 1]
      return :write unless name
      next if locals.include?(name)
      reg = name[/\Ar(\d+)\z/, 1]
      return :write unless reg && reg.to_i >= dest
    end
    nil
  end

  def balanced?(plain)
    depth = 0
    plain.each_char do |c|
      depth += 1 if c == '{'
      depth -= 1 if c == '}'
      return false if depth.negative?
    end
    depth.zero?
  end

  # [registers read before the text writes them (parameters), the others (helper locals)], in order of appearance. A
  # register first written inside a brace scope counts as read: the other path keeps the value it had.
  def register_roles(plain)
    seen = {}
    depth = 0
    plain.each_line do |line|
      stmt = line.match(/\A\s*(r\d+) = (.*);\s*\z/)
      rhs_regs = stmt ? stmt[2].scan(/\br\d+\b/) : line.scan(/\br\d+\b/)
      rhs_regs.each { |r| seen[r] ||= :input }
      seen[stmt[1]] ||= depth.zero? ? :temp : :input if stmt
      depth += line.count('{') - line.count('}')
    end
    [seen.select { |_, v| v == :input }.keys, seen.select { |_, v| v == :temp }.keys]
  end

  # Defines each helper +units+ (entries with :code, in print order) call ahead of its first caller, under a name
  # with +symbol+ so two gems' helpers stay apart. A helper with one site is `static inline` (GCC folds it back into
  # the caller); the others are noinline and cold. Returns {sites:, helpers:}.
  def place(units, symbol)
    return { sites: 0, helpers: 0 } if helpers.empty?

    first = {}
    count = Hash.new(0)
    units.each_with_index do |u, i|
      code = u[:code]
      next unless code&.include?(PREFIX)

      code.scan(PLACEHOLDER) do |(hash)|
        first[hash] ||= i
        count[hash] += 1
      end
    end
    tag = symbol.to_s.gsub(/\W/, '_')
    units.each do |u|
      next unless u[:code]&.include?(PREFIX)

      u[:code] = LIT_MACRO + u[:code].gsub(PLACEHOLDER) { "#{PREFIX}#{tag}_#{Regexp.last_match(1)}" }
    end
    first.sort_by { |hash, i| [-i, hash] }.each do |hash, i|
      head = count[hash] > 1 ? '[[gnu::noinline, gnu::cold]] static' : 'static inline'
      fn = "// RESCUE_SHARED_HANDLER: #{count[hash]} site(s)\n#{head} mrb_value #{PREFIX}#{tag}_#{hash}" \
           "#{helpers.fetch("#{PREFIX}#{hash}")}\n"
      units[i][:code] = fn + units[i][:code]
    end
    { sites: count.values.sum, helpers: first.size, shared: count.count { |_, n| n > 1 } }
  end

  def summary(placed)
    refused = stats.reject { |k, _| k == :outlined }.sort_by { |k, n| [-n, k.to_s] }.map { |k, n| "#{k} #{n}" }
    "== rescue shared handlers (RESCUE_SHARED_HANDLER): #{placed[:sites]} sites into #{placed[:helpers]} helpers " \
      "(#{placed[:shared] || 0} shared); refused: #{refused.empty? ? 'none' : refused.join(', ')} =="
  end
end

class CodeGen
  # RESCUE_SHARED_HANDLER: {first index => last index} of the logging runs in +irep+'s rescue handlers inside +range+
  # (an address Range, nil for the whole method) that no other emitter claims (+claimed+ says so for an address).
  def rescue_shared_plan(irep, claimed, range: nil)
    return {} unless RescueSharedHandler.enabled? && !@resumable && !@rescue_shared_off

    handlers = recognize_rescue_regions(irep).filter_map do |r|
      r[:except_addr]...r[:shared_target] if r[:kind] == :rescue_class && r[:shared_target] > r[:except_addr]
    end
    return {} if handlers.empty?

    program = BytecodeIR.for(irep)
    targets = jump_targets(irep)
    plan = {}
    program.each_source do |insn, idx|
      next unless insn.op == :GETGV && insn.global_name == '$stderr'

      handler = handlers.find { |h| h.cover?(insn.addr) }
      next unless handler && (range.nil? || range.cover?(insn.addr)) && !claimed.call(insn.addr)

      stop = rescue_shared_run_end(program, idx, insn.reg.to_i, handler, range, targets, claimed)
      plan[idx] = stop if stop
    end
    plan
  end

  def rescue_shared_run_end(program, idx, dest, handler, range, targets, claimed)
    (idx + 1...[program.size, idx + RescueSharedHandler::MAX_RUN].min).each do |j|
      insn = program.source_at(j)
      return nil unless insn && handler.cover?(insn.addr) && (range.nil? || range.cover?(insn.addr))
      return nil if targets.include?(insn.addr) || claimed.call(insn.addr)
      return j if %i[SEND].include?(insn.op) && insn.reg.to_i == dest && insn.sym.to_s == 'puts' && insn.argc == 1
      return nil unless RescueSharedHandler::OPS.include?(insn.op)

      written = rescue_insn_written_regs(insn)
      return nil unless written&.all? { |r| r.to_i > dest }
    end
    nil
  end
end

# RESCUE_SHARED_HANDLER: holds a planned run's instruction texts until its last one, then hands back the site's texts
# (the call at the first index and empty texts after it, or the texts as they were).
class RescueSharedRuns
  def initialize(plan, program)
    @plan = plan
    @program = program
    @buf = nil
  end

  # [[index, label, text], ...] to place now for instruction +idx+.
  def feed(idx, label, text)
    if @buf
      @buf[:items] << [idx, label, text]
      return [] unless idx == @buf[:stop]

      items = @buf[:items]
      @buf = nil
      call = RescueSharedHandler.outline(items.map(&:last), @program.source_at(items.first[0]).reg.to_i)
      return items unless call

      first_idx, first_label, = items.first
      [[first_idx, first_label, call]] + items.drop(1).map { |i, l, _| [i, l, ''] }
    elsif (stop = @plan[idx])
      @buf = { stop: stop, items: [[idx, label, text]] }
      []
    else
      [[idx, label, text]]
    end
  end

  def pending?
    !@buf.nil?
  end
end

# RESCUE_SHARED_HANDLER: a class unit is printed ahead of every compiled method, so a helper placed after
# compile_all could not be defined ahead of its sites; class-body methods keep their runs inline.
module RescueSharedClassUnits
  def compile_top_class_units(root_irep, **opts)
    saved = @rescue_shared_off
    @rescue_shared_off = true
    super
  ensure
    @rescue_shared_off = saved
  end
end
CodeGen.prepend(RescueSharedClassUnits)
