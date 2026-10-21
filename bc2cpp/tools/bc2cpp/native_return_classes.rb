# frozen_string_literal: true

require_relative 'native_owner_map'
require_relative 'native_rom_owners'

# NativeReturnClasses (option B): the class a native method name returns, proven from its C bodies, for the
# unknown-receiver join. A name is admitted only when every native registration of it is accounted for:
#
# - NativeOwnerMap lists every owner the name is registered on (ROM tables and mrb_define_* families), with no
#   unknown or computed owner that could land on it;
# - each such owner has exactly one ROM entry whose C function returns a proven class (NativeAstReturns kinds);
# - a `self` return is that owner's class only where the owner's allocator is undefined (no subclass instance
#   can exist, so the receiver is exactly the owner); otherwise it is refused;
# - every proven class is the same.
#
# The caller admits a name only when its Ruby definitions (if any) also return that class. A name that fails any
# rule is absent from the table, with the reason kept for the report.
module NativeReturnClasses
  SELF = 'self'

  # Owners whose allocator is undefined in numeric.c (MRB_UNDEF_ALLOCATOR): an instance is exactly that class.
  EXACT_SELF_OWNERS = %w[Integer Float].freeze

  Refusal = Struct.new(:name, :reason, :detail)

  module_function

  # The table for one list of native sources. kinds: { fn => class | 'self' | nil }. Owners come from NativeOwnerMap
  # (which reads ROM tables through NativeRomOwners), and the ROM entries from the same sources.
  def from_paths(paths, kinds)
    rom = []
    paths.each do |path|
      NativeRomOwners.analyze_file(path)[:tables].each_value do |info|
        next if info[:owner] == NativeRomOwners::UNKNOWN

        info[:entries].each { |fn, name| rom << [info[:owner], name, fn] }
      end
    end
    owner_map = NativeOwnerMap.build(paths)
    # Define-family registrations carry their function too; a registration with no C function identifier has no body.
    owner_map.registrations.each { |owner, name, fn| rom << [owner, name, fn] }
    # An alias (define_alias / define_alias_id) is a registration of its name with the function of the name it copies,
    # on the same owner. A copy of a name with no registration on that owner has no body here.
    owner_map.aliases.each do |owner, name, original|
      fn = owner_map.registrations.find { |ro, rn, _| ro == owner && rn == original }&.last
      rom << [owner, name, fn]
    end
    admit(owner_map, rom, kinds)
  end

  # The admitted table for the NATIVE_SRCS paths. Empty unless BC2CPP_NATIVE_FN_KINDS names a TSV of `fn<TAB>class` rows
  # (a class, `self`, or `unproven`): the kinds come from clang over those sources, which the build does not run yet.
  def table_for_env(paths)
    path = ENV['BC2CPP_NATIVE_FN_KINDS']
    return {} unless path && !path.empty?

    kinds = File.readlines(path, chomp: true).to_h do |line|
      fn, kind = line.split("\t", 2)
      [fn, kind == 'unproven' || kind.nil? ? nil : kind]
    end
    from_paths(paths, kinds)[:admitted]
  end

  # owner_map: NativeOwnerMap::Result. rom: [[owner, name, fn]] for each ROM entry of the native sources.
  # kinds: { fn => class name | 'self' | nil }, where a missing fn has no body in the native sources.
  # Returns { admitted: { name => class }, refused: [Refusal] }.
  def admit(owner_map, rom, kinds, core_dynamic_trusted: true)
    admitted = {}
    refused = []
    names = (owner_map.by_name.keys + rom.map { |_owner, name, _fn| name }).uniq.sort
    names.each do |name|
      verdict = admit_name(owner_map, rom, kinds, name, core_dynamic_trusted: core_dynamic_trusted)
      if verdict.is_a?(Refusal)
        refused << verdict
      else
        admitted[name] = verdict
      end
    end
    { admitted: admitted, refused: refused }
  end

  # The global guards match NativeOwnerMap.verdict: a computed registration with an unknown owner outside the core
  # could define any name, and a core one only where the core's own names are trusted (the default, as in codegen).
  def admit_name(owner_map, rom, kinds, name, core_dynamic_trusted: true)
    return Refusal.new(name, :owner_unknown_somewhere, nil) if owner_map.computed_unknown
    return Refusal.new(name, :core_dynamic_unknown, nil) if owner_map.core_dynamic_unknown.positive? && !core_dynamic_trusted
    return Refusal.new(name, :native_prepend, nil) if owner_map.refusals[:native_prepend].positive?

    owners = owner_map.by_name.fetch(name, Set.new)
    return Refusal.new(name, :no_native_registration, nil) if owners.empty?
    return Refusal.new(name, :owner_unknown, nil) if owners.include?(NativeOwnerMap::UNKNOWN)
    return Refusal.new(name, :computed_registration_on_owner, owners.to_a.sort.join(', ')) unless (owner_map.computed & owners).empty?

    singletons = owners.select { |owner| owner.end_with?('.singleton') }
    return Refusal.new(name, :singleton_registration, singletons.sort.join(', ')) unless singletons.empty?

    by_owner = rom.select { |_owner, entry_name, _fn| entry_name == name }.group_by(&:first)
    missing = owners.to_a.sort.reject { |owner| by_owner.key?(owner) }
    return Refusal.new(name, :registration_without_rom_entry, missing.join(', ')) unless missing.empty?

    extra = by_owner.keys.reject { |owner| owners.include?(owner) }
    return Refusal.new(name, :rom_entry_not_registered, extra.sort.join(', ')) unless extra.empty?

    duplicate = by_owner.select { |_owner, entries| entries.size > 1 }.keys
    return Refusal.new(name, :several_entries_for_owner, duplicate.sort.join(', ')) unless duplicate.empty?

    classes = owners.to_a.sort.map do |owner|
      _owner, _name, fn = by_owner[owner].first
      kind = kinds[fn]
      if kind.nil? then return Refusal.new(name, :body_not_proven, "#{owner} via #{fn}") end

      if kind == SELF
        next owner if EXACT_SELF_OWNERS.include?(owner)

        return Refusal.new(name, :self_return_not_exact, "#{owner} via #{fn}")
      end
      kind
    end
    return classes.first if classes.uniq.size == 1

    Refusal.new(name, :classes_disagree, classes.uniq.sort.join(', '))
  end
end
