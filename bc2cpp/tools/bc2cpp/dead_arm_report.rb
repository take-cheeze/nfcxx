# frozen_string_literal: true

require 'set'
require 'shellwords'
require_relative 'dead_arm_report_columns'
require_relative 'diagnostics'
require_relative 'native_names'
# The proven receiver class sets (error_receiver_classes) are ProvableErrorReport's; it only writes when its own env is set.
require_relative 'provable_error_report'

# Debug report for the arms the closed world proves can only raise (ADR 0330): with BC2CPP_DEAD_ARM_REPORT=<path>,
# every `bc2cpp_nomethod` / `bc2cpp_nil_receiver` arm of the generated code is written as one TSV row (columns in
# dead_arm_report_columns.rb) with the shape of its send, whether its method can be called at all, and whether a
# rescue, a probe or a branch on the receiver guards it. It also lists constants nothing defines and calls whose
# definitions all reject the argument count. It measures; it changes no generated code.
#
# live is a by-name call-graph fixpoint (rapid type analysis): a method body is live when its name is sent, passed as a
# symbol, or called by name from native code, from a live body or from a class body (the wio world runs no game
# Ruby, so nothing else enters). A symbol literal counts as a call, so `dead` is a sound answer and
# `live` an over-approximation; `path` names one chain of definitions that makes the body live.
module DeadArmReport
  ROWS = {}
  ARM = /\br(\d+) = bc2cpp_(nomethod|nil_receiver)_named\(M, (\w+)/
  ENGINE_GEMS = %w[mruby-rpg2k mruby-lcf mruby-rgss].freeze
  # Branches on these results are guards for the value they were called on.
  TEST_NAMES = %w[nil? respond_to? is_a? kind_of? instance_of? empty? ! == != === key? include? any? none?].freeze
  JUMPS = %w[JMPIF JMPNOT JMPNIL].freeze
  ORIGIN_OPS = %w[GETIV GETCV GETGV GETCONST].freeze
  ENTRY_SOURCES = ['app/wio/src/*.cxx', 'src/main.cxx', 'src/error_dump.cxx'].freeze

  def compile_send(insn, **kwargs)
    code = super
    dead_arm_note(code, insn, kwargs[:irep], kwargs[:idx] || kwargs[:trace_idx], self)
    code
  end

  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    code = super
    dead_arm_note(code, insn, irep, idx, self) if %w[GETIDX GETIDX0 SETIDX].include?(insn.op)
    code
  end

  def dead_arm_note(code, insn, irep, idx, cg)
    return unless irep && idx

    key = [irep.label, idx]
    lines = code.each_line.reject { |l| l.lstrip.start_with?('//') }
    arms = []
    lines.each_with_index do |line, i|
      m = ARM.match(line) or next
      before = lines[0, i].join
      shape = if m[2] == 'nil_receiver' || code.match?(%r{^\s*// (?:BLOCK_PARAM_CALL|LCF_ROW_FLOW)\b}) then 'nil'
              elsif before.match?(/\belse\b/) then 'chain'
              else 'sole'
              end
      arms << { kind: m[2], shape: shape, op: insn.op, name: insn.sym || IMPLICIT_DISPATCH_NAMES.fetch(insn.op, '?') }
    end
    if arms.empty?
      ROWS.delete(key)
    else
      ROWS[key] = arms
      ROWS[:codegen] = cg
    end
  end

  def dead_arm_gem(irep)
    ENGINE_GEMS.find { |g| irep.file.to_s.include?("/#{g}/") } || (irep.file.to_s.include?('/3rd/mruby/') ? 'core' : 'other')
  end

  def dead_arm_def_text(definition)
    "#{definition.owner}##{definition.name}"
  end

  # What each irep introduces: method bodies by the name they are defined under (DEF/TDEF/SDEF, as
  # ClosedWorld#scan_closed_world reads them), and every other child (block, lambda, class body) of its parent.
  def dead_arm_structure
    @dead_arm_structure ||= begin
      method_bodies = Hash.new { |h, k| h[k] = [] }
      plain = Hash.new { |h, k| h[k] = [] }
      @ireps.each do |label, irep|
        pending = nil
        irep.instructions.each do |insn|
          case insn.op
          when 'METHOD'
            plain[label] << [pending, 'BLOCK'] if pending
            pending = irep.reps[insn.block_index.to_i]
          when 'DEF'
            method_bodies[insn.sym] << pending if pending && insn.sym
            pending = nil
          when 'TDEF', 'SDEF'
            method_bodies[insn.sym] << irep.reps[insn.block_index] if insn.sym
          else
            plain[label] << [irep.reps[insn.block_index.to_i], insn.op] if insn.block_index
          end
        end
        plain[label] << [pending, 'BLOCK'] if pending
      end
      children = (plain.values.flat_map { |l| l.map(&:first) } + method_bodies.values.flatten).to_set
      text = {}
      @registry.each_value { |defs| defs.each { |d| text[d.irep] ||= dead_arm_def_text(d) if d.irep } }
      { method_bodies: method_bodies, plain: plain, roots: @ireps.keys.reject { |l| children.include?(l) }, text: text }
    end
  end

  # [live name => [parent description, via], irep label => the method (or class body) it runs as part of] after the
  # fixpoint; the second hash holds exactly the live ireps.
  def dead_arm_liveness(native_names)
    st = dead_arm_structure
    names = {}
    owner_of = {}
    work = []
    discover = lambda do |name, parent, via|
      next if names.key?(name)

      names[name] = [parent, via]
      work << name
    end
    native_names.each { |name, src| discover.call(name, "native:#{src}", 'native') }
    %w[initialize initialize_copy method_missing respond_to_missing? to_s inspect == eql? <=> hash call].each do |n|
      discover.call(n, 'mruby core', 'native')
    end
    scan = lambda do |label, owner|
      next if owner_of.key?(label)

      owner_of[label] = owner
      @ireps[label].instructions.each do |insn|
        case insn.op
        when 'SEND0', 'SEND', 'SSEND0', 'SSEND', 'SENDB', 'SSENDB'
          discover.call(insn.sym, owner, 'send') if insn.sym
        when 'LOADSYM'
          discover.call(insn.sym, owner, 'sym') if insn.sym
        else
          fixed = IMPLICIT_DISPATCH_NAMES[insn.op]
          discover.call(fixed, owner, 'send') if fixed
        end
      end
      st[:plain][label].each do |c, op|
        scan.call(c, op == 'EXEC' ? "toplevel:#{@ireps[c].file.to_s.split('/').last(2).join('/')}" : owner)
      end
    end
    st[:roots].each { |l| scan.call(l, "toplevel:#{@ireps[l].file.to_s.split('/').last(2).join('/')}") }
    until work.empty?
      name = work.shift
      st[:method_bodies][name].each { |child| scan.call(child, st[:text][child] || "?##{name}") }
    end
    [names, owner_of]
  end

  def dead_arm_path(label, names, owner_of)
    owner = owner_of[label]
    return '-' unless owner

    chain = [owner]
    seen = Set.new
    while owner.include?('#') && !owner.start_with?('toplevel:') && seen.add?(owner)
      parent, via = names[owner.split('#', 2).last]
      break unless parent

      chain << (via == 'sym' ? "(sym) #{parent}" : parent)
      owner = parent
    end
    chain.join(' <- ')
  end

  # [origin key, writer index] of each definition reaching +reg+ at +idx+; an ivar read is keyed by its name so two
  # reads of one ivar match. nil when the dataflow gives up.
  def dead_arm_origins(irep, idx, reg)
    defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s)
    return nil unless defs

    defs.map do |d|
      next [[:entry, reg], -1] if d.entry?

      w = irep.instructions[d.index]
      [ORIGIN_OPS.include?(w.op) ? [w.op, w.first_of(:name)&.value] : [:def, d.index], d.index]
    end
  end

  def dead_arm_ivar_written_between?(irep, name, from, to)
    irep.instructions[(from + 1)...to].any? { |i| i.op == 'SETIV' && i.first_of(:name)&.value == name }
  end

  # The receiver is an ivar read that a SETIV of a non-nil value in the same straight-line stretch (no branch target
  # between them) precedes: the flow does not track ivar stores, so it still reports the ivar nilable.
  def dead_arm_selfset?(irep, idx)
    origins = dead_arm_origins(irep, idx, irep.instructions[idx].reg)
    return false if origins.nil? || origins.empty?

    targets = BytecodeIR.for(irep).branch_targets
    origins.all? do |(key, gi)|
      next false unless key.first == 'GETIV'

      s = (0...gi).to_a.reverse.find { |i| irep.instructions[i].op == 'SETIV' && irep.instructions[i].first_of(:name)&.value == key.last }
      next false unless s && (s + 1..gi).none? { |i| targets.include?(i) }

      vals = BytecodeIR.reaching_definitions(irep, s, irep.instructions[s].regs.first.to_s)
      vals && !vals.empty? && vals.none? { |d| !d.entry? && irep.instructions[d.index].op == 'LOADNIL' }
    end
  end

  # A branch earlier in the method on the value the receiver came from (`return unless x`, `x.nil?`), with no store to
  # an ivar origin in between. Weak: the branch may guard only part of the code after it.
  def dead_arm_guard_hint?(irep, idx)
    mine = dead_arm_origins(irep, idx, irep.instructions[idx].reg)
    return false if mine.nil? || mine.empty?

    same = lambda do |tested|
      tested&.any? do |(key, ti)|
        mine.any? do |(mkey, mi)|
          mkey == key && ti <= mi && (key.first != 'GETIV' || !dead_arm_ivar_written_between?(irep, key.last, ti, mi))
        end
      end
    end
    irep.instructions.each_with_index do |j, ji|
      next unless JUMPS.include?(j.op) && ji < idx && j.reg
      return true if same.call(dead_arm_origins(irep, ji, j.reg))

      BytecodeIR.reaching_definitions(irep, ji, j.reg.to_s)&.each do |d|
        next if d.entry?

        w = irep.instructions[d.index]
        return true if %w[SEND SEND0].include?(w.op) && TEST_NAMES.include?(w.sym) && w.reg && same.call(dead_arm_origins(irep, d.index, w.reg))
      end
    end
    false
  end

  def dead_arm_guard(irep, idx, name, shape)
    program = BytecodeIR.for(irep)
    return 'probed' if @closed_world.instance_variable_get(:@probed_names).include?(name)
    return 'rescue' if rescue_covered_labels.include?(irep.label) ||
                       program.handler_protected_addrs(inclusive_end: true).include?(irep.instructions[idx].addr)
    return '-' if shape == 'chain' || irep.instructions[idx].reg.nil?
    return 'selfset' if dead_arm_selfset?(irep, idx)

    dead_arm_guard_hint?(irep, idx) ? 'hint' : '-'
  end

  def dead_arm_native_names
    paths = Shellwords.split(ENV.fetch('NATIVE_SRCS', ''))
    paths += ENTRY_SOURCES.flat_map { |g| Dir[File.expand_path("../../#{g}", __dir__)] }
    out = {}
    paths.each { |p| extract_native_call_names([p]).each { |n| out[n] ||= File.basename(p) } }
    out
  end

  def dead_arm_row(kind, irep, idx, owner, op, name, shape, live, entry, guard, path, origin = '-')
    insn = irep.instructions[idx]
    [kind, dead_arm_gem(irep), owner, irep.label, idx, op, name, shape, live, entry,
     guard, "#{irep.file}:#{insn.lineno}", origin, path].join("\t")
  end

  # Where the receiver value was written: `@x` for an ivar read, `param` for a value the method was entered with,
  # `call:name` for a send result, else the opcode.
  # Every SETIV of the program by ivar name: [owner text, line, true when the value is the literal nil].
  def dead_arm_ivar_writers
    @dead_arm_ivar_writers ||= begin
      map = Hash.new { |h, k| h[k] = [] }
      @ireps.each_value do |irep|
        irep.instructions.each_with_index do |w, i|
          next unless w.op == 'SETIV' && w.regs.first

          defs = BytecodeIR.reaching_definitions(irep, i, w.regs.first.to_s)
          literal_nil = defs && !defs.empty? && defs.all? { |d| !d.entry? && irep.instructions[d.index].op == 'LOADNIL' }
          map[w.first_of(:name)&.value] << [dead_arm_site_method(irep), w.lineno, literal_nil ? true : false]
        end
      end
      map
    end
  end

  # Names each class's own `initialize` sends (blocks included): a reader it calls runs before anything else can set state.
  def dead_arm_ctor_sends
    @dead_arm_ctor_sends ||= begin
      map = Hash.new { |h, k| h[k] = Set.new }
      (@registry['initialize'] || []).each do |d|
        next unless d.irep

        stack = [d.irep]
        until stack.empty?
          irep = @ireps[stack.pop]
          irep.instructions.each { |i| map[d.owner.to_s] << i.sym if i.sym && %w[SEND SEND0 SSEND SSEND0 SENDB SSENDB].include?(i.op) }
          stack.concat(irep.reps || [])
        end
      end
      map
    end
  end

  # The constructor of the site's class (or an ancestor's) calls the site's method.
  def dead_arm_ctor_called?(owner)
    klass, meth = owner.to_s.split('#', 2)
    k = klass
    seen = []
    while k.is_a?(String) && !seen.include?(k)
      seen << k
      return true if dead_arm_ctor_sends[k].include?(meth)

      k = @closed_world.class_parent(k)
    end
    false
  end

  def dead_arm_site_method(irep)
    @dead_arm_owners&.fetch(irep.label, nil) || dead_arm_structure[:text][irep.label] || '?'
  end

  # `init:nil` when initialize only writes nil (or nothing), then the methods that set a value and the ones that reset it.
  def dead_arm_nil_source(name, owner)
    klass = owner.to_s.split('#', 2).first
    chain = []
    k = klass
    while k.is_a?(String) && !chain.include?(k)
      chain << k
      k = @closed_world.class_parent(k)
    end
    writers = dead_arm_ivar_writers[name].select { |m, _l, _n| chain.include?(m.to_s.split('#', 2).first) }
    init = writers.select { |m, _l, _n| m.end_with?('#initialize') }
    sets = writers.reject { |m, _l, nil_w| nil_w || m.end_with?('#initialize') }.map { |m, _l, _n| m.split('#', 2).last }.uniq
    resets = writers.select { |_m, _l, nil_w| nil_w }.map { |m, _l, _n| m.split('#', 2).last }.uniq
    init_text = init.empty? ? 'init:unset' : (init.all? { |_m, _l, nil_w| nil_w } ? 'init:nil' : 'init:value')
    "#{init_text} set:#{sets.first(4).join(',')}#{sets.size > 4 ? ',+' : ''} reset:#{resets.first(4).join(',')}#{resets.size > 4 ? ',+' : ''}"
  end

  def dead_arm_origin(irep, idx, owner = nil)
    text = dead_arm_origin_text(irep, idx, owner)
    owner && dead_arm_ctor_called?(owner) ? "#{text} ctor" : text
  end

  def dead_arm_origin_text(irep, idx, owner)
    reg = irep.instructions[idx].reg
    defs = reg && BytecodeIR.reaching_definitions(irep, idx, reg.to_s)
    return '?' unless defs

    defs.map do |d|
      next 'param' if d.entry?

      w = irep.instructions[d.index]
      case w.op
      when 'GETIV'
        ivar = w.first_of(:name)&.value.to_s
        owner ? "#{ivar} [#{dead_arm_nil_source(ivar, owner)}]" : ivar
      when 'GETCV', 'GETGV', 'GETCONST' then w.first_of(:name)&.value.to_s
      when 'SEND', 'SEND0', 'SSEND', 'SSEND0', 'SENDB' then "call:#{w.sym}"
      else w.op.downcase
      end
    end.uniq.sort.join('|')
  end

  def dead_arm_rows
    names, owners = dead_arm_liveness(dead_arm_native_names)
    @dead_arm_owners = owners
    rows = []
    ROWS.each do |key, arms|
      next if key == :codegen

      irep = @ireps.fetch(key[0])
      idx = key[1]
      live, owner = dead_arm_site(irep, idx, owners)
      path = live ? dead_arm_path(irep.label, names, owners) : '-'
      entry = live ? path.split(' <- ').last[/\A(?:\(sym\) )?(native|toplevel|mruby core)/, 1] || 'call' : '-'
      arms.each do |arm|
        guard = dead_arm_guard(irep, idx, arm[:name], arm[:shape])
        rows << dead_arm_row(arm[:kind], irep, idx, owner, arm[:op], arm[:name], arm[:shape], live ? 'live' : 'dead', entry, guard, path, arm[:shape] == 'chain' ? '-' : dead_arm_origin(irep, idx, owner))
      end
    end
    rows + dead_arm_partial_miss_rows(owners) + dead_arm_const_rows(owners) + dead_arm_arity_rows(owners)
  end

  # [live?, owning method text]: the body is callable and the site is not behind an unreachable instruction.
  def dead_arm_site(irep, idx, owners)
    live = owners.key?(irep.label) && BytecodeIR.for(irep).reachable_from(0).include?(idx)
    [live, owners[irep.label] || dead_arm_structure[:text][irep.label] || '-']
  end

  # Sends whose proven receiver class set holds a class (other than nil, which the nil rows count) that does not answer
  # the name: the send raises if that class reaches it. shape `all`: no class of the set answers (a provable error).
  def dead_arm_partial_miss_rows(owners)
    answers = call_facts_answers
    bodies = entry_arg_body_owner
    rows = []
    @ireps.each_value do |irep|
      next if dead_arm_gem(irep) == 'core'

      irep.instructions.each_with_index do |insn, idx|
        next unless %w[SEND SEND0 SENDB].include?(insn.op) && insn.sym && answers.definers(insn.sym)

        classes = error_receiver_classes(irep, idx, insn.reg.to_i, bodies[irep.label])
        next if classes.nil? || classes.empty?

        misses = classes.reject { |k| answers.answers?(k, insn.sym) }
        real = misses - ['NilClass']
        next if real.empty?

        live, owner = dead_arm_site(irep, idx, owners)
        rows << dead_arm_row('partial_miss', irep, idx, owner, insn.op, insn.sym, real.size == classes.size ? 'all' : 'some',
                             live ? 'live' : 'dead', '-', dead_arm_guard(irep, idx, insn.sym, 'some'), '-',
                             "miss=#{real.sort.join('|')} set=#{classes.sort.join('|')}")
      end
    end
    rows
  end

  def dead_arm_arity_accepts?(definition, argc)
    return true if definition.owner == '<native>' || !definition.irep

    enter = @ireps.fetch(definition.irep).enter
    return true unless enter

    req, opt, rest, post, kw, kdict = enter.enter_fields
    return true unless kw.zero? && kdict.zero?

    argc >= req + post && (rest.positive? || argc <= req + opt + post)
  end

  # Plain calls of a name whose Ruby definitions reject the argument count: all of them (the call raises whatever the
  # receiver is, unless a native or foreign definition answers) or only some (bc2cpp refuses a direct entry).
  def dead_arm_arity_rows(owners)
    rows = []
    answers = respond_to?(:call_facts_answers, true) ? call_facts_answers : nil
    @ireps.each_value do |irep|
      next if dead_arm_gem(irep) == 'core'

      irep.instructions.each_with_index do |insn, idx|
        next unless %w[SEND SEND0 SSEND SSEND0].include?(insn.op) && insn.sym && insn.plain_fixed_argc?

        defs = @registry[insn.sym]
        next if defs.nil? || defs.empty?

        argc = insn.argc.to_i
        ok = defs.map { |d| dead_arm_arity_accepts?(d, argc) }
        next if ok.all?

        # A name an outside definition can answer is not provably rejected.
        kind = ok.none? && answers && answers.definers(insn.sym) && !@closed_world.unknown_def?(insn.sym) ? 'arity_all' : 'arity_some'
        live, owner = dead_arm_site(irep, idx, owners)
        rows << dead_arm_row(kind, irep, idx, owner, insn.op, insn.sym, "argc=#{argc}", live ? 'live' : 'dead', '-', '-',
                             defs.map { |d| "#{d.owner}/#{d.irep ? error_arity_text_safe(d) : 'attr'}" }.join(','))
      end
    end
    rows
  end

  def error_arity_text_safe(definition)
    enter = @ireps[definition.irep]&.enter
    enter ? enter.enter_fields.first(6).join(':') : '0'
  end

  # Capitalised names the outside sources (C strings, Ruby) mention anywhere: a constant spelled there may be defined at run time.
  def dead_arm_outside_constants
    root = File.expand_path('../..', __dir__)
    paths = Shellwords.split(ENV.fetch('NATIVE_SRCS', '')) + Shellwords.split(ENV.fetch('FOREIGN_RUBY_SRCS', '')) +
            Dir["#{root}/app/wio/src/*.cxx"] + Dir["#{root}/3rd/mruby/src/*.c"] + Dir["#{root}/3rd/mruby/mrbgems/*/src/*.c"] + Dir["#{root}/3rd/mruby/mrbgems/*/mrblib/**/*.rb"]
    paths.each_with_object(Set.new) do |p, set|
      File.read(p, mode: 'rb').scan(/\b[A-Z][A-Za-z0-9_]*\b/) { |tok| set << tok }
    rescue SystemCallError => e
      warn "[dead_arm_report] #{p}: #{e.message}"
    end
  end

  def dead_arm_const_rows(owners)
    defined = Set.new
    @ireps.each_value do |irep|
      irep.instructions.each { |i| defined << (i.op == 'SETCONST' ? i.const_name : i.sym) if %w[CLASS MODULE SETCONST].include?(i.op) }
    end
    outside = dead_arm_outside_constants
    rows = []
    @ireps.each_value do |irep|
      next if dead_arm_gem(irep) == 'core'

      irep.instructions.each_with_index do |insn, idx|
        name = insn.op == 'GETCONST' && insn.const_name
        next unless name && !defined.include?(name) && !outside.include?(name)

        live, owner = dead_arm_site(irep, idx, owners)
        rows << dead_arm_row('const_unresolved', irep, idx, owner, insn.op, name, '-', live ? 'live' : 'dead', '-',
                             dead_arm_guard(irep, idx, name, 'chain'), '-')
      end
    end
    rows
  end

  def self.write(path)
    cg = ROWS[:codegen]
    File.write(path, "#{(cg ? cg.dead_arm_rows : []).join("\n")}\n")
  end
end

CodeGen.prepend(DeadArmReport)
at_exit { DeadArmReport.write(ENV.fetch('BC2CPP_DEAD_ARM_REPORT')) }
