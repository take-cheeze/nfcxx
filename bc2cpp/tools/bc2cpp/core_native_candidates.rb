# frozen_string_literal: true

# CORE_NATIVE_CANDIDATES (closed only): the mruby core ROM method-table entries (MRB_MT_ENTRY) no lookup in the closed
# build can reach. The closed build leaves each listed one out of its table at compile time (MRB_MT_EXCLUDE_HEADER,
# build_config.rb), so it costs neither a table slot nor, once nothing else calls its function, its code.
#
# The engine proof (StaticDispatchRegistrations.analyze) reads core Ruby only for sends that may reach an engine
# object. A core method is reached through core receivers too, so the rule here is receiver-blind and coarser: a
# name is reachable when any of these spell it --
#   - a symbol an instruction of the program may look up (a send, a LOADSYM, an alias or undef, a key, ...; the
#     operand of a DEF or the destination of an ALIAS, which defines its name, does not), or an identifier-shaped pool string. The engine's ireps all
#     count. A core, external or foreign mrblib method body counts only while its own name is reachable (LIVE_CORE),
#     to a fixpoint: nothing runs a Ruby-defined core method but a lookup of its name, or a direct `_impl` call from
#     compiled code. A direct implementation reference retains body dependencies without requiring its named slot.
#     Root and class bodies, and blocks made in them, always count;
#   - a name the native sources look up (native_name_tokens: string literals, presym macros, naming macros), except
#     the name operand of a table entry or registration call, which defines it;
#   - a string literal of the generated code;
#   - a name a pool fragment may build (dynamic_name?).
# ALWAYS_DYNAMIC (the VM's implicit protocol names) seeds nothing here: the VM looks a method up by a presym or literal
# of src/, which the native scan reads, or by an operator opcode, which an irep read above names (a name only that list
# held, `to_hash` or `send`, is spelled nowhere a lookup could come from).
# The VM's implicit calls (to_s, inspect, coerce, ...) are presym uses in src/, so they are read like any other. An
# operator name is never a candidate: the VM sends those from opcodes the scan does not name.
#
# Native text the scan does not read as a lookup of an identifier (strip_operator_names, strip_label_calls,
# strip_enumerator_symbols): MRB_OPSYM(div) names `/` and not `div`; a string literal passed straight to a helper that
# only formats it into an exception message; the Symbol an Array native hands to `to_enum` when no Enumerator is made.
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
  ENTRY = /MRB_MT_ENTRY\s*\(\s*(\w+)\s*,\s*MRB_(SYM|SYM_Q|SYM_B|SYM_E|OPSYM)\s*\(\s*(\w+)\s*\)/
  SUFFIX = { 'SYM' => '', 'SYM_Q' => '?', 'SYM_B' => '!', 'SYM_E' => '=' }.freeze
  # A table entry's name operand defines the name; it is blanked before the source is scanned for lookups.
  ENTRY_NAME = /(MRB_MT_ENTRY\s*\(\s*\w+\s*,\s*)(MRB_\w*SYM\w*\s*\(\s*\w+\s*\))/
  NAME = /\A[a-z_][A-Za-z0-9_]*[?!=]?\z/
  DOMAIN_ERROR = /\bstatic\s+void\s+domain_error\s*\(\s*mrb_state\s*\*\s*mrb\s*,\s*const\s+char\s*\*\s*func\s*\)\s*\{([^{}]*)\}/m
  DOMAIN_ERROR_BODY = <<~'C'.gsub(/\s+/, '').freeze
    struct RClass *math = mrb_module_get_id(mrb, MRB_SYM(Math));
    struct RClass *domainerror = mrb_class_get_under_id(mrb, math, MRB_SYM(DomainError));
    mrb_raisef(mrb, domainerror, "Numerical argument is out of domain - %s", func);
  C
  DOMAIN_ERROR_CALL = /\bdomain_error\s*\(\s*mrb\s*,\s*("(?:[^"\\\n]|\\.)*")\s*\)/

  # LABEL_HELPERS: library functions whose string argument only ends up in an exception message. `path` is the one file
  # that defines one, `definition` its exact text without blanks. `unnamed`: a class the helper hands the message to when
  # it exists (mrb_sys_fail's SystemCallError); nothing may make it, or the branch could run.
  LABEL_HELPERS = {
    'mrb_int_overflow' => {
      path: %r{/3rd/mruby/src/numeric\.c\z},
      definition: 'voidmrb_int_overflow(mrb_state*mrb,constchar*reason){' \
                  'mrb_raisef(mrb,E_RANGE_ERROR,"integeroverflowin%s",reason);}'
    },
    'mrb_sys_fail' => {
      path: %r{/3rd/mruby/src/error\.c\z},
      definition: <<~'C'.gsub(/\s+/, ''),
        void mrb_sys_fail(mrb_state *mrb, const char *mesg)
        {
          if (mrb_class_defined_id(mrb, MRB_SYM(SystemCallError))) {
            struct RClass *sce = mrb_class_get_id(mrb, MRB_SYM(SystemCallError));
            mrb_int no = (mrb_int)errno;
            if (mesg != NULL) {
              mrb_funcall_id(mrb, mrb_obj_value(sce), MRB_SYM(_sys_fail), 2, mrb_fixnum_value(no), mrb_str_new_cstr(mrb, mesg));
            }
            else {
              mrb_funcall_id(mrb, mrb_obj_value(sce), MRB_SYM(_sys_fail), 1, mrb_fixnum_value(no));
            }
          }

          mrb_raise(mrb, E_RUNTIME_ERROR, mesg);
        }
      C
      unnamed: 'SystemCallError'
    }
  }.freeze

  # An operator's table name is the operator, not the identifier: MRB_OPSYM(div) is `/`, and cdump's table row
  # OPERATOR_SYMBOL("/", "div") formats it. Neither looks up a method called `div`.
  OPERATOR_NAMES_TEXT = [
    /\bMRB_OPSYM\s*\(\s*\w+\s*\)/,
    /\bOPERATOR_SYMBOL\s*\(\s*"[^"\n]*"\s*,\s*"\w+"\s*\)/
  ].freeze

  # The Symbol of Array#index and #rindex's `to_enum(:name)` call when no block or argument is given.
  ENUM_SYMBOL_CALL = /\bmrb_funcall_id\s*\(\s*mrb\s*,\s*self\s*,\s*MRB_SYM\s*\(\s*to_enum\s*\)\s*,\s*1\s*,\s*
                      mrb_symbol_value\s*\(\s*(MRB_SYM\s*\(\s*\w+\s*\))\s*\)\s*\)/x

  module_function

  # A diagnostic label is not a lookup when the helper only formats an exception and no computed lookup
  # can consume the resulting message. Unknown bodies, macros or escaping references retain every literal.
  def strip_diagnostic_literals(text)
    return text if text.match?(/\\[\r\n]|%:|\?\?/)
    clean = StaticDispatchRegistrations.strip_c_comments(text)
    return text if clean.match?(/^\s*#\s*(?:define|undef)\s+(?:domain_error|mrb_raisef|mrb_module_get_id|mrb_class_get_under_id)\b/)
    definitions = clean.to_enum(:scan, DOMAIN_ERROR).map { Regexp.last_match }
    return text unless definitions.size == 1 && definitions[0][1].gsub(/\s+/, '') == DOMAIN_ERROR_BODY

    calls = clean.to_enum(:scan, DOMAIN_ERROR_CALL).map { Regexp.last_match }
    return text unless clean.scan(/\bdomain_error\b/).size == calls.size + 1
    return text if calls.any? { |call| clean[0...call.begin(0)].rstrip.end_with?('.', ':', '>') }

    out = clean.dup
    calls.each { |call| out[call.begin(1)...call.end(1)] = ' ' * (call.end(1) - call.begin(1)) }
    out
  end

  # OPERATOR_NAMES_TEXT blanked.
  def strip_operator_names(text)
    OPERATOR_NAMES_TEXT.inject(text) { |t, re| t.gsub(re) { |m| ' ' * m.size } }
  end

  # ENUM_SYMBOL_CALL's Symbol blanked. Sound only while CoreEnumeratorFree holds: the call then never runs, so the
  # Symbol is never handed to the `each`-like call an Enumerator would make.
  def strip_enumerator_symbols(text, enumerator_free)
    return text unless enumerator_free && text.match?(ENUM_SYMBOL_CALL) && (enumerator_free == true || enumerator_free.call)

    text.gsub(ENUM_SYMBOL_CALL) { |m| m.sub(Regexp.last_match(1), ' ' * Regexp.last_match(1).size) }
  end

  # The LABEL_HELPERS whose one definition is the table's formatting body in the table's file, with no macro of the name
  # anywhere: a literal passed to one cannot reach an interning call, whoever calls it.
  def verified_label_helpers(native_paths, ireps, core, generated)
    clean = native_paths.to_h { |path| [path, StaticDispatchRegistrations.strip_c_comments(File.read(path, encoding: 'BINARY'))] }
    LABEL_HELPERS.select do |name, spec|
      next false if clean.each_value.any? { |text| text.match?(/^[ \t]*#[ \t]*(?:define|undef)[ \t]+#{name}\b/) }

      definitions = clean.flat_map { |path, text| label_definitions(path, text, name) }
      next false unless definitions.size == 1 && definitions[0][0].match?(spec[:path]) && definitions[0][1] == spec[:definition]

      !spec[:unnamed] || unnamed?(spec[:unnamed], clean.values, ireps, core, generated)
    end.keys.to_set
  end

  # Is the class `word` never made: no native spells it but to look it up (the helper's own check included), and no Ruby
  # or generated code names it?
  def unnamed?(word, native_texts, ireps, core, generated)
    spelled = ->(text) { text.scan(/\b#{word}\b/).size }
    lookup = /\bmrb_class_(?:defined|get)(?:_id)?\s*\(\s*mrb\s*,\s*(?:MRB_SYM\s*\(\s*#{word}\s*\)|"#{word}")\s*\)/
    return false unless native_texts.sum(&spelled) == native_texts.sum { |text| text.scan(lookup).size }
    return false if generated.any? { |src| src.include?(word) }

    all_ireps = ireps.values + core.flat_map { |file| file[:ireps].values }
    all_ireps.none? { |irep| irep.syms.any? { |s| s.to_s == word } || irep.pool.any? { |s| s == word } }
  end

  # [path, the definition's text without blanks] of each `void name(mrb_state ...) { ... }` in `text`.
  def label_definitions(path, text, name)
    text.to_enum(:scan, /\bvoid\s+#{name}\s*\(\s*mrb_state[^()]*\)\s*\{/).map do
      start = Regexp.last_match.begin(0)
      depth = 0
      close = (start...text.size).find do |i|
        depth += 1 if text[i] == '{'
        depth -= 1 if text[i] == '}'
        depth.zero? && text[i] == '}'
      end
      [path, close ? text[start..close].gsub(/\s+/, '') : nil]
    end
  end

  # The literal argument of each direct call of a verified helper blanked.
  def strip_label_calls(text, helpers)
    return text if helpers.empty?

    helpers.inject(StaticDispatchRegistrations.strip_c_comments(text)) do |t, name|
      t.gsub(/\b#{name}\s*\(\s*mrb\s*,\s*("(?:[^"\\\n]|\\.)*")\s*\)/) { |m| m.sub(Regexp.last_match(1), ' ' * Regexp.last_match(1).size) }
    end
  end

  # Every table entry of `paths`: { mt_class:, kind:, cname:, name:, fn:, installed: } with `installed` the class the
  # table's MRB_MT_INIT_ROM installs it into (NativeRomOwners), or nil when that is not MRB_MT_CLASS's own class.
  # An operator name is never a candidate: the VM sends those from opcodes the scan does not name. `operator_names`
  # names the two index operators (MRB_OPSYM(aref/aset)) for the INDEX_CLOSED proof, whose planner verdict covers
  # every class that can answer them; every other operator stays unnamed.
  OPERATOR_NAMES = { 'aref' => '[]', 'aset' => '[]=' }.freeze
  def entries(paths, operator_names: false)
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

        line.scan(ENTRY) do |fn, kind, cname|
          name = kind == 'OPSYM' ? (operator_names ? OPERATOR_NAMES[cname] : nil) : cname + SUFFIX.fetch(kind)
          out << { mt_class: mt_class, kind: kind, cname: cname, name: name, fn: fn, path: path,
                   installed: owners[table] == mt_class ? mt_class : nil }
        end
      end
      out
    end
  end

  # The receiver-blind reachable names (see the header), and the pool fragments. `ireps` (the engine's) all count;
  # `core` is one { ireps:, body_of: } per core Ruby file, body_of mapping a method body's irep label to its name.
  # +lookup+ reads one irep (lookup_names, or CorePrivateRuby::Lookup); +strip+ blanks the native text it should not
  # read, +strip_generated+ the generated source's literals (the `_impl` calls it makes are read from the whole of it),
  # +exact_impls+ how live_core reads a direct `_impl` call. +diagnostic_literals+ requires the closed-world
  # literal-lookup proof, so an exception message cannot supply a computed method name. +enumerator_free+ is
  # CoreEnumeratorFree's verdict, or a callable that makes it (asked only when a native has a ENUM_SYMBOL_CALL).
  def reachable(ireps, native_paths, generated, core: [], lookup: method(:lookup_names), strip: nil, strip_generated: nil,
                exact_impls: false, diagnostic_literals: false, enumerator_free: false, names: Set.new)
    # Closed (VM-free) only: no protocol name seeds +names+ (see StaticDispatchRegistrations#analyze).
    # A +names+ that answers `note` is told where each name comes from (scripts/bc2cpp/core_kept_report.rb).
    note = ->(label) { names.note(label) if names.respond_to?(:note) }
    fragments = Set.new
    ireps.each_value do |irep|
      note.call("engine irep #{irep.label}")
      lookup.call(irep, nil, names, fragments)
    end
    macros = StaticDispatchRegistrations.naming_macros(native_paths)
    helpers = diagnostic_literals ? verified_label_helpers(native_paths, ireps, core, generated) : Set.new
    native_paths.each do |path|
      note.call("native #{path}")
      text = File.read(path, encoding: 'BINARY').gsub(ENTRY_NAME) { "#{Regexp.last_match(1)}#{' ' * Regexp.last_match(2).size}" }
      text = strip.call(text) if strip
      text = strip_label_calls(strip_operator_names(text), helpers)
      text = strip_enumerator_symbols(text, enumerator_free)
      text = strip_diagnostic_literals(text) if diagnostic_literals && path.end_with?('/mruby-math/src/math.c')
      StaticDispatchRegistrations.native_name_tokens(text, names, macros)
    end
    note.call('generated code literal')
    generated.each do |src|
      src = strip_generated.call(src) if strip_generated
      src.scan(StaticDispatchRegistrations::STRING_LITERAL) { |(s)| names << StaticDispatchRegistrations.unescape(s) }
    end
    live_core(core, generated, names, fragments, lookup: lookup, exact_impls: exact_impls)
    [names, fragments]
  end

  # DEF, TDEF and SDEF name the method they define; no lookup reads that operand.
  DEF_OPS = %i[DEF TDEF SDEF].freeze

  # Adds what `irep` may look up to `names` and its fragment-shaped pool strings to `fragments`: every symbol of the
  # irep except one only a DEF names, since that operand defines the method. `own` is the name of the method whose
  # body this is: SUPER looks it up again in the ancestors, as an operator opcode does its operator. ALIAS looks up
  # its source and defines its destination; an unresolved source keeps every symbol conservatively.
  def lookup_names(irep, own, names, fragments)
    syms = irep.syms.map(&:to_s)
    defined = Set.new
    used = Set.new
    aliased = false
    BytecodeIR.for(irep).each_source do |insn, _index|
      if insn.op == :ALIAS
        original = insn.first_of(:name)&.value
        if original then used << original.to_s else aliased = true end
      end
      names << own if own && insn.op == :SUPER
      # An operator opcode sends its name without a symbol operand (a Ruby-defined `+` runs from ADD).
      names << IMPLICIT_DISPATCH_NAMES[insn.op] if IMPLICIT_DISPATCH_NAMES.key?(insn.op)
      (DEF_OPS.include?(insn.op) || insn.op == :ALIAS ? defined : used) << insn.sym.to_s if insn.sym
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
  #
  # exact_impls (the private-name proof): a direct `_impl` call makes live the body of the owner it names and no more,
  # and does not make the name reachable. The `_impl` is named for the owner that defines the body (CodeGen#cpp_name:
  # `Kernel_print_impl`), so `RGSS__ErrorReport__Tee_print_impl` calls Tee#print and `IO_singleton_open_impl` calls
  # IO.open, neither a lookup of `print` or `open` nor a call of Kernel's. A body whose owner the file does not give
  # (`owner_of`) is read by name alone, as without the flag.
  def live_core(core, generated, names, fragments, lookup: method(:lookup_names), exact_impls: false)
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
        if own
          pending[own] << [irep, file[:owner_of]&.dig(up)]
        else
          names.note("core root or class body #{File.basename(file[:path].to_s)}") if names.respond_to?(:note)
          lookup.call(irep, nil, names, fragments)
        end
      end
    end
    pending.each_value { |bodies| bodies.each { |irep, _owner| lookup.call(irep, nil, Set.new, fragments) } }
    # A direct call reaches the body without a lookup: `<Owner>_<name>_impl` (CodeGen#sanitize mangling).
    by_name = ->(name) { impls.any? { |t| t.end_with?("_#{mangle(name)}_impl") || t.include?("_#{mangle(name)}_block_fallback") } }
    if exact_impls
      pending.each do |name, bodies|
        bodies.reject! do |irep, owner|
          names.note("direct _impl call of #{name}") if names.respond_to?(:note)
          if owner.nil?
            names << name if by_name.call(name)
            next false
          end
          next false unless impls.any? { |t| t.start_with?("#{cpp_name(owner, name)}_") }

          lookup.call(irep, name, names, fragments)
          true
        end
      end
    else
      names.merge(pending.keys.select(&by_name))
    end
    loop do
      grew = false
      pending.each do |own, bodies|
        next unless names.include?(own)

        names.note("live core method #{own}") if names.respond_to?(:note)
        bodies.each { |irep, _owner| lookup.call(irep, own, names, fragments) }
        pending.delete(own)
        grew = true
      end
      break unless grew
    end
  end

  # CodeGen#cpp_name.
  def cpp_name(owner, name)
    "#{owner}_#{name}".gsub(/[^a-zA-Z0-9_]/) { |c| ':.'.include?(c) ? '_' : format('$%02x', c.ord) }
  end

  # CodeGen#sanitize, for a method name (no `::` or `.` in it).
  def mangle(name)
    name.gsub(/[^a-zA-Z0-9_]/) { |c| format('$%02x', c.ord) }
  end

  # The listed keys, "MtClass#name" sorted: every entry of the key a candidate, its name unreachable.
  def candidates(entries, names, fragments, proven = {})
    entries.group_by { |e| [e[:mt_class], e[:name]] }.filter_map do |(mt_class, name), group|
      next unless (name&.match?(NAME) || proven[name]) && group.all? { |e| e[:installed] }
      next if !proven[name] && StaticDispatchRegistrations.dynamic_name?(name, names, fragments)

      "#{mt_class}##{name}"
    end.sort
  end

  # Core Ruby registrations, compiled or interpreted, whose names no lookup reaches.
  # ROM-shared keys stay: omitting a Ruby override must not replace a readonly entry with a RAM tombstone.
  def ruby_candidates(core, names, fragments, entries, proven = {})
    rom = entries.to_set { |entry| "#{entry[:mt_class]}##{entry[:name]}" }
    definitions = core.flat_map do |file|
      file.fetch(:registry).flat_map do |name, definitions|
        next [] unless (name.match?(NAME) || proven[name]) &&
                       (proven[name] || !StaticDispatchRegistrations.dynamic_name?(name, names, fragments))

        definitions.filter_map do |definition|
          owner = definition.owner
          next unless definition.irep && owner.is_a?(String) && owner.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*(?:\.singleton)?\z/)
          # A per-file registry can repeat an explicit singleton receiver; do not guess its runtime owner.
          next if owner.match?(/\b([A-Z]\w*)::\1\b/)

          key = "#{owner}##{name}"
          key unless rom.include?(key.sub('.singleton#', '#'))
        end
      end
    end
    aliases = core.flat_map do |file|
      Array(file[:tuple]&.[](12)).filter_map do |site|
        owner, name = site.values_at(:owner, :new)
        next unless owner.is_a?(String) && owner.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*(?:\.singleton)?\z/) && name&.match?(NAME)
        next if owner.match?(/\b([A-Z]\w*)::\1\b/)

        key = "#{owner}##{name}"
        key unless rom.include?(key.sub('.singleton#', '#')) || StaticDispatchRegistrations.dynamic_name?(name, names, fragments)
      end
    end
    (definitions + aliases).uniq.sort
  end

  # CORE_RAM_CANDIDATES: the core registrations made at run time (mrb_define_method and the other defining calls,
  # NativeOwnerMap), as "Owner#name" sorted, that the core gem removes like a left-out native. The same reachability
  # rule; a registration with a computed name, a native alias or undef of the key, or a ROM entry of the same class and
  # name keeps it (the removal would take the ROM one, leaving a tombstone). Native aliases are candidates separately
  # when their new names are unreachable; the source names still count as lookups.
  def ram_candidates(map, names, fragments, entries, proven = {})
    rom = entries.to_set { |e| "#{e[:mt_class]}##{e[:name]}" }
    blocked = Set.new
    map.aliases.each { |owner, new_name, old_name| blocked << "#{owner}##{new_name}" << "#{owner}##{old_name}" }
    map.registrations.each { |owner, name, fn| blocked << "#{owner}##{name}" if fn.nil? }
    registrations = map.registrations.filter_map do |owner, name, _fn|
      next unless owner.is_a?(String) && (name&.match?(NAME) || proven[name]) &&
                  !owner.match?(StaticDispatchRegistrations::CLOSED_OWNER_RE)
      next if map.computed.include?(owner)

      key = "#{owner}##{name}"
      # A proven operator's singleton registration is independent of the
      # instance ROM entry the planner also excludes: the class-method table
      # the header does not touch. Only an exact ROM twin still blocks.
      rom_key = proven[name] ? key : key.sub('.singleton#', '#')
      next if blocked.include?(key) || rom.include?(rom_key)
      next if !proven[name] && StaticDispatchRegistrations.dynamic_name?(name, names, fragments)

      key
    end
    # An alias copies its source entry during native initialization. Removing an unreachable alias afterward
    # does not remove that source; its name still counts as a native lookup.
    aliases = map.aliases.filter_map do |owner, name, original|
      next unless original && owner.is_a?(String) && (name&.match?(NAME) || proven[name]) &&
                  !owner.match?(StaticDispatchRegistrations::CLOSED_OWNER_RE)
      next if map.computed.include?(owner)

      key = "#{owner}##{name}"
      rom_key = proven[name] ? key : key.sub('.singleton#', '#')
      next if rom.include?(rom_key)
      next if !proven[name] && StaticDispatchRegistrations.dynamic_name?(name, names, fragments)

      key
    end
    (registrations + aliases).uniq.sort
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
