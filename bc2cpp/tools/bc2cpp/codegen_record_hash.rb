# frozen_string_literal: true

# CodeGen: RECORD_HASH_PROOF consumer (docs/adr/0285).

class CodeGen
  # The single exact class every value stored under the record key(s) read by the GETIDX feeding
  # +reg+ at +idx+ has, or nil. Unguarded: RecordHash proved the Hash is created by the listed literals
  # and mutated only by the listed stores, and each store is a fresh instance of that class.
  def record_hash_exact_class(irep, idx, reg)
    return nil unless RecordHash.table && @closed_world

    defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s, through_handlers: true)
    return nil if defs.nil? || defs.empty?

    slots = defs.flat_map do |d|
      return nil if d.entry? || irep.instructions[d.index].op != 'GETIDX'

      RecordHash.read_slots(irep, d.index) or return nil
    end
    classes = slots.map { |name, key| record_key_exact_class(name, key) }
    classes.first if classes.all? && classes.uniq.size == 1
  end

  private

  def record_key_exact_class(name, key)
    @record_key_exact_class ||= {}
    return @record_key_exact_class[[name, key]] if @record_key_exact_class.key?([name, key])

    @record_key_exact_class[[name, key]] = compute_record_key_exact_class(name, key)
  end

  def compute_record_key_exact_class(name, key)
    info = RecordHash.table.dig(name, key) or return nil
    return nil if info[:nilable] || info[:writers].empty?

    classes = info[:writers].map { |irep, i, reg| record_writer_exact_class(irep, i, reg) }
    classes.first if classes.all? && classes.uniq.size == 1
  end

  # The exact class of the value register +reg+ holds at +idx+ when every reaching definition is a
  # heap literal or a `Klass.new` whose constructor is stable (exact_new_receiver_class).
  def record_writer_exact_class(irep, idx, reg)
    defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s, through_handlers: true)
    return nil if defs.nil? || defs.empty?

    classes = defs.map do |d|
      next nil if d.entry?

      writer = irep.instructions[d.index]
      case writer.op
      when 'ARRAY' then 'Array'
      when 'HASH' then 'Hash'
      when 'STRING' then 'String'
      when 'SEND', 'SEND0', 'SENDB' then record_new_class(irep, d.index, writer)
      end
    end
    classes.first if classes.all? && classes.uniq.size == 1
  end

  def record_new_class(irep, index, writer)
    return nil unless writer.sym == 'new'

    owner = entry_arg_body_owner[irep.label]&.owner
    klass = trace_new_target(irep, index + 1, writer.reg, nil, 0, nil, owner: owner, container_constants: @container_constants,
                                                                       known_owners: @known_owners)
    klass && exact_new_receiver_class(irep, index + 1, writer.reg, owner: owner, expected_class: klass)
  end
end
