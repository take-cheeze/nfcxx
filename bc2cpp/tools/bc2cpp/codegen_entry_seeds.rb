# frozen_string_literal: true

require 'set'
require_relative 'ir_entry_seeds'

# CodeGen: ENTRY_SEEDS (see ir_entry_seeds.rb). Reporting only: IrCallGraphTypes reads these facts, and nothing in the
# code generator does, so the compiled output does not change with the switch.
class CodeGen
  # The `start` receiver: the native entry calls `start` on the maker it built, so self in RPG2k#start is RPG2k. Seeded
  # explicitly; the closed-world self model gives the same class (return_class_self_receiver), and the seed must agree
  # with it, or the seed is refused.
  START_RECEIVER_CLASS = 'RPG2k'

  def bytecode_ir_entry_seed_self_class(definition)
    return nil if ENV['BC2CPP_ENTRY_SEEDS'] == '0'
    return nil unless definition.name == 'start' && definition.owner == START_RECEIVER_CLASS && definition.irep
    return nil unless @closed_world&.exact_class?(START_RECEIVER_CLASS)

    START_RECEIVER_CLASS
  end

  # IrCallGraphTypes asks this for a body's parameter that no SEND names. Only the maker `initialize` at position 1 is
  # seeded: its complete caller set is the native construction (an Array) and no Ruby site.
  def bytecode_ir_entry_seed_classes(definition, position)
    return nil if ENV['BC2CPP_ENTRY_SEEDS'] == '0'
    return nil unless definition.name == 'initialize' && position.to_i == 1 && definition.irep

    entry_seed_ctor_admitted?(definition) ? IrEntrySeeds::CTOR_ARG_CLASSES : nil
  end

  # True when the maker's initialize body has no Ruby caller at all, so the native construction is its entire entry.
  # The constructor-pool scan is reused with one change: the native spelling of an admitted maker is not a refusal
  # (constructor_pool_status's exempt:). Every other gate still applies.
  def entry_seed_ctor_admitted?(definition)
    @entry_seed_ctor ||= {}
    return @entry_seed_ctor[definition.irep] if @entry_seed_ctor.key?(definition.irep)

    @entry_seed_ctor[definition.irep] = compute_entry_seed_ctor(definition)
  end

  private

  def compute_entry_seed_ctor(definition)
    return false unless IrEntrySeeds::MAKERS.include?(definition.owner)
    return false if constructor_pools_refusal
    return false unless (@registry['initialize'] || []).count { |d| d.owner == definition.owner } == 1
    return false unless entry_seed_makers.include?(definition.owner)

    status, = constructor_pool_status(definition, constructor_site_scan, exempt: entry_seed_makers)
    status == :no_sites
  end

  # The makers the scanned native entries construct (see IrEntrySeeds.admitted_makers). The entry texts are read here,
  # from the paths the closed world scanned, so an entry that was not in the world admits nothing.
  def entry_seed_makers
    @entry_seed_makers ||= begin
      native = @closed_world.native_token_files
      texts = native.keys.select { |path| IrEntrySeeds.entry_key(path) && File.file?(path) }.to_h do |path|
        # The entry sources have UTF-8 text in comments and strings; the token rules do not care about the rest.
        [path, File.read(path, encoding: 'UTF-8').scrub]
      end
      IrEntrySeeds.admitted_makers(native, @closed_world.foreign_ruby_token_files, texts)
    end
  end
end
