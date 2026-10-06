# frozen_string_literal: true

# EXACT_CORE_RECEIVER (ADR 0280): an unguarded proof that a receiver is exactly an Array, Hash,
# Range or String (or a fresh `Klass.new`), so the arms of ADR 0253/0257/0270 can drop their
# class test. Nothing checks the class at run time, so only a dominating literal or `*rest`
# write counts (plus exact_flow_core_class, ADR 0289), and only while ClosedWorld#exact_instances_singleton_free?. A ClassLayout hint,
# an annotation or a branch join is a guarded fact and never enters here. A compiled core body gets the walk
# only, as a checked proof (ADR 0359).
class CodeGen
  EXACT_LITERAL_CLASS = {
    'ARRAY' => 'Array', 'ARRAY2' => 'Array', 'HASH' => 'Hash', 'STRING' => 'String',
    'RANGE_INC' => 'Range', 'RANGE_EXC' => 'Range', 'LOADNIL' => 'NilClass'
  }.freeze
  # Ops that add to the container their first register already holds.
  EXACT_EXTEND_OPS = %w[ARYPUSH ARYCAT HASHADD HASHCAT STRCAT].freeze

  # 'Array' | 'Hash' | 'Range' | 'String' (| 'NilClass', for arguments) when the value in `reg`
  # at `idx` is exactly that class.
  def exact_core_value_class(irep, idx, reg)
    return nil unless @closed_world&.exact_instances_singleton_free? && irep && idx&.positive? && reg

    exact_walk_class(irep, idx, reg) || exact_flow_core_class(irep, idx, reg) || frozen_table_exact_class(irep, idx, reg)
  end

  # The dominating-writer walk alone: a literal or the method's own `*rest` slot, through MOVEs.
  def exact_walk_class(irep, idx, reg)
    at_entry = ->(entry_reg) { rest_entry_class(irep, entry_reg.to_i) }
    irep.walk_dominating_writers(idx - 1, reg.to_s, use: idx, exhausted: at_entry) do |insn, _i, _cur|
      case insn.op
      when 'MOVE' then insn.regs[1] ? IrepScans.follow(insn.regs[1]) : nil
      when *EXACT_EXTEND_OPS then IrepScans::KEEP
      else EXACT_LITERAL_CLASS[insn.op]
      end
    end
  end

  CORE_BODY_EXACT_TESTS = {
    'Array' => 'mrb_array_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->array_class',
    'Hash' => 'mrb_hash_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->hash_class',
    'String' => 'mrb_string_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->string_class',
    'Range' => 'mrb_range_p(%<r>s) && mrb_obj_ptr(%<r>s)->c == M->range_class'
  }.freeze

  # CORE_BODY_EXACT (ADR 0359): a compiled core body has no engine world, so its walk proof rests on
  # the program's. It is a checked proof: the site keeps a class test and a guard violation.
  def core_body_exact_class(irep, idx, reg)
    return nil unless core_body_exact_enabled? && irep && idx&.positive? && reg

    klass = exact_walk_class(irep, idx, reg)
    klass if CORE_BODY_EXACT_TESTS.key?(klass)
  end

  def core_body_exact_enabled?
    ENV['BC2CPP_CORE_BODY_EXACT'] != '0' && @closed_world.nil? && NomethodReviewed.guard_violation_enabled? &&
      @core_program_world&.exact_instances_singleton_free?
  end

  INDEX_EXACT_NOTE = "// INDEX_EXACT -- receiver is exactly this class (unguarded proof, ADR 0296)\n  "

  # 'Array' | 'Hash' when GETIDX/GETIDX0/SETIDX's receiver register is exactly that class, so its
  # fast path needs no class test.
  def index_exact_class(irep, idx, reg)
    klass = irep && idx && reg && exact_core_value_class(irep, idx, reg)
    %w[Array Hash].include?(klass) ? klass : nil
  end

  # The site's proof for the arm wrappers: the receiver's exact class, and a lambda that answers
  # the exact class of an argument register (nil when it is not a plain register or unproven).
  # `new_class` is the fresh `Klass.new` proof of compile_send (exact_new_receiver_class).
  # `owner_def` is carried so an arm wrapper can ask native_int_arg_proven? about an :int
  # argument (ADR 0358); without it the wrapper cannot reach the Fixnum proof at all.
  def exact_core_site(irep, idx, receiver_reg, argv, reg_offset, new_class = nil, recv: nil, name: nil, owner_def: nil, dest: nil)
    if @closed_world&.exact_instances_singleton_free?
      klass = exact_core_value_class(irep, idx, receiver_reg) || new_class
      return nil unless klass

      return { klass: klass, recv: recv, name: name,
               int_site: [irep, idx, owner_def, reg_offset],
               arg_class: lambda do |position|
                 reg = argv[position].to_s[/\Ar(\d+)\z/, 1]
                 reg && exact_core_value_class(irep, idx, reg.to_i - reg_offset)
               end }
    end

    checked_core_body_site(irep, idx, receiver_reg, argv, recv, name, dest)
  end

  # CORE_BODY_EXACT (ADR 0359): the receiver proof of a compiled core body. Only the receiver is
  # proven and with_exact_core_site tests it; no argument or Fixnum proof rides on it.
  def checked_core_body_site(irep, idx, receiver_reg, argv, recv, name, dest)
    return nil unless recv.to_s.match?(/\Ar\d+\z/) && name && dest

    klass = core_body_exact_class(irep, idx, receiver_reg)
    return nil unless klass

    { klass: klass, recv: recv, name: name, int_site: nil, arg_class: ->(_position) {},
      checked: true, dest: dest, argv: argv, used: false }
  end

  # The site's proof, only for the send it was made for: a nested compile that reaches the arm
  # wrappers while the ivar is set (compiles_clean? on a callee) is another send.
  def exact_core_site_for(recv, name)
    site = @exact_core_site
    return nil unless site && site[:recv] == recv && site[:name] == name

    site[:used] = true
    site
  end

  def with_exact_core_site(site)
    previous = @exact_core_site
    @exact_core_site = site
    checked = site && site[:checked]
    site[:used] = false if checked
    code = yield
    checked && !previous.equal?(site) ? checked_exact_code(site, code) : code
  ensure
    @exact_core_site = previous
  end

  # What an arm that dropped its class test on this proof says about itself: a new arm kind must say it too, or
  # its code is left unchecked (scripts/bc2cpp_core_body_exact_check.rb scans for the "unguarded proof" ones).
  CORE_BODY_EXACT_ARM = /unguarded proof|-- proven \w+ receiver/

  # The code is only valid for the proven class, so it sits behind the class test and the else is a
  # loud error (ADR 0290).
  def checked_exact_code(site, code)
    return code unless site[:used] && code.is_a?(String) && code.match?(CORE_BODY_EXACT_ARM)

    test = format(CORE_BODY_EXACT_TESTS.fetch(site[:klass]), r: site[:recv])
    violation = guard_violation_line(site[:dest], site[:recv], site[:name], site[:argv], 'CORE_BODY_EXACT')
    "// CORE_BODY_EXACT_CHECKED :#{site[:name]} -> #{site[:klass]} (ADR 0359)\n" \
      "  if (#{test}) {\n#{code.chomp}\n  } else {\n    #{violation.chomp}\n  }\n"
  end
end
