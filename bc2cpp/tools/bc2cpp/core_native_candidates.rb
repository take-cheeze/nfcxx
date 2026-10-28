# frozen_string_literal: true

# CORE_NATIVE_CANDIDATES (closed only): the mruby core ROM method-table entries (MRB_MT_ENTRY) no lookup in the closed
# build can reach. The closed build leaves each listed one out of its table at compile time (MRB_MT_EXCLUDE_HEADER,
# build_config.rb), so it costs neither a table slot nor, once nothing else calls its function, its code.
#
# The engine proof (StaticDispatchRegistrations.analyze) reads core Ruby only for sends that may reach an engine
# object. A core method is reached through core receivers too, so the rule here is receiver-blind and coarser: a
# name is reachable when any of these spell it --
#   - a symbol an instruction of the program may look up (a send, a LOADSYM, an alias or undef, a key, ...; the
#     operand of a DEF, which defines its name, does not), or an identifier-shaped pool string. The engine's ireps all
#     count. A core, external or foreign mrblib method body counts only while its own name is reachable (LIVE_CORE),
#     to a fixpoint: nothing runs a Ruby-defined core method but a lookup of its name, or a direct `_impl` call from
#     compiled code, which is read as one. Root and class bodies, and blocks made in them, always count;
#   - a name the native sources look up (native_name_tokens: string literals, presym macros, naming macros), except
#     the name operand of a table entry or registration call, which defines it;
#   - a string literal of the generated code;
#   - ALWAYS_DYNAMIC, or a name a pool fragment may build (dynamic_name?).
# The VM's implicit calls (to_s, inspect, coerce, ...) are presym uses in src/, so they are read like any other. An
# operator name is never a candidate: the VM sends those from opcodes the scan does not name.
#
# An exclusion macro names (MRB_MT_CLASS, name), shared by every table of that class (its singleton's too), so a
# key is listed only when each entry it names is a candidate: in a table whose install target is MRB_MT_CLASS itself.
require 'set'
require 'tmpdir'
require_relative 'native_rom_owners'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'diagnostics'

module CoreNativeCandidates
  TABLE_CLASS = /^[ \t]*#[ \t]*define[ \t]+MRB_MT_CLASS[ \t]+(\w+)[ \t]*$/
  TABLE_END = /^[ \t]*#[ \t]*undef[ \t]+MRB_MT_CLASS\b/
  ENTRY = /MRB_MT_ENTRY\s*\(\s*\w+\s*,\s*MRB_(SYM|SYM_Q|SYM_B|SYM_E|OPSYM)\s*\(\s*(\w+)\s*\)/
  SUFFIX = { 'SYM' => '', 'SYM_Q' => '?', 'SYM_B' => '!', 'SYM_E' => '=' }.freeze
  # A table entry's name operand defines the name; it is blanked before the source is scanned for lookups.
  ENTRY_NAME = /(MRB_MT_ENTRY\s*\(\s*\w+\s*,\s*)(MRB_\w*SYM\w*\s*\(\s*\w+\s*\))/
  NAME = /\A[a-z_][A-Za-z0-9_]*[?!=]?\z/

  module_function

  # Every table entry of `paths`: { mt_class:, kind:, cname:, name:, installed: } with `installed` the class the
  # table's MRB_MT_INIT_ROM installs it into (NativeRomOwners), or nil when that is not MRB_MT_CLASS's own class.
  def entries(paths)
    paths.flat_map do |path|
      text = File.binread(path).force_encoding(Encoding::UTF_8).scrub
      next [] unless text.include?('MRB_MT_ENTRY')

      # A table installed into more than one class is no single class's.
      owners = NativeRomOwners.analyze(text)[:installs].group_by(&:first)
                              .transform_values { |installs| installs.map(&:last).uniq.then { |o| o.size == 1 ? o[0] : nil } }
      out = []
      mt_class = nil
      table = nil
      text.each_line do |line|
        if (m = line.match(TABLE_CLASS)) then mt_class = m[1]
        elsif line.match?(TABLE_END) then mt_class = nil
        elsif (m = line.match(/static\s+const\s+mrb_mt_entry\s+(\w+)\s*\[\]/)) then table = m[1]
        end
        next unless mt_class

        line.scan(ENTRY) do |kind, cname|
          name = kind == 'OPSYM' ? nil : cname + SUFFIX.fetch(kind)
          out << { mt_class: mt_class, kind: kind, cname: cname, name: name, path: path,
                   installed: owners[table] == mt_class ? mt_class : nil }
        end
      end
      out
    end
  end

  # The receiver-blind reachable names (see the header), and the pool fragments. `ireps` (the engine's) all count;
  # `core` is one { ireps:, body_of: } per core Ruby file, body_of mapping a method body's irep label to its name.
  # +lookup+ reads one irep (lookup_names, or CorePrivateRuby::Lookup); +strip+ blanks the native text it should not read.
  def reachable(ireps, native_paths, generated, core: [], lookup: method(:lookup_names), strip: nil)
    names = Set.new(StaticDispatchRegistrations::ALWAYS_DYNAMIC)
    fragments = Set.new
    ireps.each_value { |irep| lookup.call(irep, nil, names, fragments) }
    macros = StaticDispatchRegistrations.naming_macros(native_paths)
    native_paths.each do |path|
      text = File.read(path, encoding: 'BINARY').gsub(ENTRY_NAME) { "#{Regexp.last_match(1)}#{' ' * Regexp.last_match(2).size}" }
      text = strip.call(text) if strip
      StaticDispatchRegistrations.native_name_tokens(text, names, macros)
    end
    generated.each { |src| src.scan(StaticDispatchRegistrations::STRING_LITERAL) { |(s)| names << StaticDispatchRegistrations.unescape(s) } }
    live_core(core, generated, names, fragments, lookup: lookup)
    [names, fragments]
  end

  # DEF, TDEF and SDEF name the method they define; no lookup reads that operand.
  DEF_OPS = %i[DEF TDEF SDEF].freeze

  # Adds what `irep` may look up to `names` and its fragment-shaped pool strings to `fragments`: every symbol of the
  # irep except one only a DEF names, since that operand defines the method. `own` is the name of the method whose
  # body this is: SUPER looks it up again in the ancestors, as an operator opcode does its operator. An irep with an ALIAS keeps every symbol: the disassembly
  # that decodes operands shows the alias's old name, the one looked up, as the new one.
  def lookup_names(irep, own, names, fragments)
    syms = irep.syms.map(&:to_s)
    defined = Set.new
    used = Set.new
    aliased = false
    BytecodeIR.for(irep).each_source do |insn, _index|
      aliased ||= insn.op == :ALIAS
      names << own if own && insn.op == :SUPER
      # An operator opcode sends its name without a symbol operand (a Ruby-defined `+` runs from ADD).
      names << IMPLICIT_DISPATCH_NAMES[insn.op] if IMPLICIT_DISPATCH_NAMES.key?(insn.op)
      (DEF_OPS.include?(insn.op) ? defined : used) << insn.sym.to_s if insn.sym
    end
    names.merge(aliased ? syms : syms.reject { |s| defined.include?(s) && !used.include?(s) })
    irep.pool.each do |s|
      next unless s.is_a?(String)

      names << s if s.match?(StaticDispatchRegistrations::IDENT)
      fragments << s if s.match?(StaticDispatchRegistrations::FRAGMENT)
    end
  end

  # LIVE_CORE (see the header): the core files' root and class bodies always count; a method body, with the blocks it
  # makes, once its name is in `names` or compiled code calls an `_impl` of that name directly. Fragments are read from
  # every body, live or not: a built name is the costly kind to miss.
  def live_core(core, generated, names, fragments, lookup: method(:lookup_names))
    impls = Set.new
    # `$` is the mangling's escape (`Array_include$3f_impl`).
    generated.each { |src| src.scan(/[\w$]+_impl\b/) { |t| impls << t } }
    pending = Hash.new { |h, k| h[k] = [] }
    core.each do |file|
      parent = {}
      file[:ireps].each_value { |irep| irep.reps.each { |c| parent[c] = irep.label } }
      file[:ireps].each do |label, irep|
        up = label
        up = parent[up] until up.nil? || file[:body_of].key?(up)
        own = up && file[:body_of][up]
        if own then pending[own] << irep else lookup.call(irep, nil, names, fragments) end
      end
    end
    pending.each_value { |reps| reps.each { |irep| lookup.call(irep, nil, Set.new, fragments) } }
    # A direct call reaches the body without a lookup: `<Owner>_<name>_impl` (CodeGen#sanitize mangling).
    called = pending.keys.select { |name| impls.any? { |t| t.end_with?("_#{mangle(name)}_impl") || t.include?("_#{mangle(name)}_block_fallback") } }
    names.merge(called)
    loop do
      grew = false
      pending.each do |own, reps|
        next unless names.include?(own)

        reps.each { |irep| lookup.call(irep, own, names, fragments) }
        pending.delete(own)
        grew = true
      end
      break unless grew
    end
  end

  # CodeGen#sanitize, for a method name (no `::` or `.` in it).
  def mangle(name)
    name.gsub(/[^a-zA-Z0-9_]/) { |c| format('$%02x', c.ord) }
  end

  # The listed keys, "MtClass#name" sorted: every entry of the key a candidate, its name unreachable.
  def candidates(entries, names, fragments)
    entries.group_by { |e| [e[:mt_class], e[:name]] }.filter_map do |(mt_class, name), group|
      next unless name&.match?(NAME) && group.all? { |e| e[:installed] }
      next if StaticDispatchRegistrations.dynamic_name?(name, names, fragments)

      "#{mt_class}##{name}"
    end.sort
  end

  # CORE_RAM_CANDIDATES: the core registrations made at run time (mrb_define_method and the other defining calls,
  # NativeOwnerMap), as "Owner#name" sorted, that the core gem removes like a left-out native. The same reachability
  # rule; a registration with a computed name, a native alias or undef of the key, or a ROM entry of the same class and
  # name keeps it (the removal would take the ROM one, leaving a tombstone).
  def ram_candidates(map, names, fragments, entries)
    rom = entries.to_set { |e| "#{e[:mt_class]}##{e[:name]}" }
    blocked = Set.new
    map.aliases.each { |owner, new_name, old_name| blocked << "#{owner}##{new_name}" << "#{owner}##{old_name}" }
    map.registrations.each { |owner, name, fn| blocked << "#{owner}##{name}" if fn.nil? }
    map.registrations.filter_map do |owner, name, _fn|
      next unless owner.is_a?(String) && name&.match?(NAME) && !owner.match?(StaticDispatchRegistrations::CLOSED_OWNER_RE)
      next if map.computed.include?(owner)

      key = "#{owner}##{name}"
      next if blocked.include?(key) || rom.include?(key.sub('.singleton#', '#'))
      next if StaticDispatchRegistrations.dynamic_name?(name, names, fragments)

      key
    end.uniq.sort
  end

  # The exclusion header's text for `keys` (MRB_MT_EXCLUDE_HEADER, include/mruby/class.h).
  def header(keys, entries)
    by_key = entries.group_by { |e| "#{e[:mt_class]}##{e[:name]}" }
    lines = keys.flat_map do |key|
      by_key.fetch(key).map { |e| "#define MRB_MT_EXCLUDE_#{e[:mt_class]}_#{e[:kind]}__#{e[:cname]} 1" }
    end.uniq
    "/* Generated by build_config.rb from the static dispatch lists (tools/bc2cpp/core_native_candidates.rb). */\n" \
      "#{lines.join("\n")}\n"
  end
end
