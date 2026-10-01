# frozen_string_literal: true

# EXACT_CORE_RECEIVER (ADR 0280): an unguarded proof that a receiver is exactly an Array, Hash,
# Range or String (or a fresh `Klass.new`), so the arms of ADR 0253/0257/0270 can drop their
# class test. Nothing checks the class at run time, so only a dominating literal or `*rest`
# write counts (plus exact_flow_core_class, ADR 0289), and only while ClosedWorld#exact_instances_singleton_free?. A ClassLayout hint,
# an annotation or a branch join is a guarded fact and never enters here.
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

    at_entry = ->(entry_reg) { rest_entry_class(irep, entry_reg.to_i) }
    written = irep.walk_dominating_writers(idx - 1, reg.to_s, use: idx, exhausted: at_entry) do |insn, _i, _cur|
      case insn.op
      when 'MOVE' then insn.regs[1] ? IrepScans.follow(insn.regs[1]) : nil
      when *EXACT_EXTEND_OPS then IrepScans::KEEP
      else EXACT_LITERAL_CLASS[insn.op]
      end
    end
    written || exact_flow_core_class(irep, idx, reg)
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
  def exact_core_site(irep, idx, receiver_reg, argv, reg_offset, new_class = nil, recv: nil, name: nil)
    return nil unless @closed_world&.exact_instances_singleton_free?

    klass = exact_core_value_class(irep, idx, receiver_reg) || new_class
    return nil unless klass

    { klass: klass, recv: recv, name: name,
      arg_class: lambda do |position|
        reg = argv[position].to_s[/\Ar(\d+)\z/, 1]
        reg && exact_core_value_class(irep, idx, reg.to_i - reg_offset)
      end }
  end

  # The site's proof, only for the send it was made for: a nested compile that reaches the arm
  # wrappers while the ivar is set (compiles_clean? on a callee) is another send.
  def exact_core_site_for(recv, name)
    site = @exact_core_site
    site if site && site[:recv] == recv && site[:name] == name
  end

  def with_exact_core_site(site)
    previous = @exact_core_site
    @exact_core_site = site
    yield
  ensure
    @exact_core_site = previous
  end
end
