# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'bytecode_ir_containers'
require_relative 'record_hash'
require_relative 'rbs_signatures'
require_relative 'core_hierarchy_sigs'
require_relative 'escape_analysis'
require_relative 'rbs_parse_memo'

# RBS_RECORD_TYPES: an RBS record type on an ivar (`@ui: { battle: Game::Battle, ?win: Window }`)
# is a CHECKED declaration that feeds the facts RECORD_HASH_PROOF produces.
#
# Loader: every `@ivar: { ... }` (or `{ ... }?`) and `attr_reader/attr_accessor x: { ... }` in the signature
# files. A field type is `untyped` (no check, no hint) or one RbsSignatures.value_classes_of can name (a class,
# `T?`, a union, bool, nil, a literal). A record return type is accepted and gives nothing (TC1005).
#
# Checker: the ivar NAME is scanned across the whole closed world with RecordHash::Scanner's alias discipline
# (the Hash may only be read by key, written by `h[:k] = v`, copied by MOVE or captured), extended to
#   `h.update({...})` / `h.merge!({...})`  a Hash literal argument, each pair a store;
#   `h.store(:k, v)`                       a store;
#   `h.delete(:k)`                         only of a key declared optional (`?k:`).
# Every store must use declared keys, every literal stored into the ivar must carry every required key, and every
# value must be traced (literal, `Klass.new`, trace_new_target) to a class that conforms to the field type. A
# write the checker cannot verify (computed key, non-literal update, clear, replace, delete of a required key,
# an escape of the Hash, reflection, an outside spelling of the name) is a TC1009 error at its file:line, and
# the build aborts on it like RBS_SEED_CONTRADICTION. Nothing is trusted on the declaration's word alone.
#
# Consumers: a verified name joins RecordHash.table (the unguarded RECORD_HASH_PROOF consumers keep their own
# exact-class rules), and a literal-key read `@x[:k]` whose field names one class C (nil aside) is a receiver
# HINT for C in guarded traces (trace_new_target's GETIDX arm), so the send keeps its class guard.
module RbsRecordTypes
  CODE = 'TC1009'
  Field = Struct.new(:key, :optional, :classes, :text, keyword_init: true) # classes: Set of names, nil = untyped
  Decl = Struct.new(:owner, :ivar, :fields, :nilable, :text, :loc, keyword_init: true)
  Loaded = Struct.new(:decls, :diagnostics, keyword_init: true)
  Result = Struct.new(:verified, :diagnostics, :hints, :readers, keyword_init: true)
  # Hash methods that mutate nothing and hand out no reference to the Hash: a call is a read.
  READ_SENDS = %w[key? has_key? include? member? size length empty? fetch dig].freeze
  # Kernel/BasicObject truth tests: they read only the receiver's identity (nil? / !).
  NIL_TESTS = %w[nil? !].freeze
  # How deep the interprocedural scan follows the Hash into callees before it calls the use an escape.
  INTERPROC_DEPTH = 16
  # Hash's lookup chain (declarations.rbs#core_hierarchy); only membership is read.
  HASH_OWNERS = CoreHierarchySigs.ancestors('Hash')
  BASE_CLASSES = %w[Integer Float String Symbol Array Hash NilClass TrueClass FalseClass Range Proc].freeze

  class << self
    # name => { key => class name } for guarded receiver hints; name => Decl. Set by the driver.
    attr_accessor :hints, :decls
  end

  module_function

  # ------------------------------------------------------------------------------------------------- loader

  def load(files, display_root: nil)
    out = Loaded.new(decls: [], diagnostics: [])
    return out if files.empty?

    begin
      require 'rbs'
    rescue LoadError
      return out # RbsSignatures reports the missing gem (TC1002)
    end
    files.each do |file|
      rel = display_root ? file.sub(%r{\A#{Regexp.escape(display_root)}/?}, '') : file
      begin
        decls = RbsParseMemo.decls(rel, File.read(file))
      rescue RBS::ParsingError
        next # RbsSignatures reports it (TC1002)
      end
      decls.each { |d| declaration(out, d, [], rel) }
    end
    out
  end

  def declaration(out, decl, scope, rel)
    return unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

    name = (scope + [decl.name.to_s.delete_prefix('::')]).join('::')
    decl.members.each do |m|
      case m
      when RBS::AST::Declarations::Base then declaration(out, m, [name], rel)
      when RBS::AST::Members::InstanceVariable then ivar(out, name, m.name.to_s, m.type, m, rel)
      when RBS::AST::Members::AttrReader, RBS::AST::Members::AttrAccessor
        next if m.kind == :singleton

        iv = (m.ivar_name.is_a?(Symbol) ? m.ivar_name : "@#{m.name}").to_s
        ivar(out, name, iv, m.type, m, rel)
      when RBS::AST::Members::MethodDefinition
        next unless m.overloads.any? { |o| record_type(o.method_type.type.return_type) }

        diag(out.diagnostics, loc_of(m, rel), 'info', 'TC1005',
             "#{name}##{m.name}: a record return type is accepted but not checked; no hint")
      end
    end
  end

  def record_type(type)
    type = type.type if type.is_a?(RBS::Types::Optional)
    type if type.is_a?(RBS::Types::Record)
  end

  def ivar(out, owner, name, type, member, rel)
    record = record_type(type) or return

    loc = loc_of(member, rel)
    fields = {}
    optional = record.respond_to?(:optional_fields) ? record.optional_fields : {}
    [[record.fields, false], [optional, true]].each do |table, opt|
      table.each do |key, t|
        classes = field_classes(t)
        if classes == :unsupported
          diag(out.diagnostics, loc, 'error', CODE,
               "#{owner}##{name}: field #{key}: type #{t} cannot be checked (write a class, `T?`, a union or untyped)")
          return
        end
        fields[key.to_s] = Field.new(key: key.to_s, optional: opt, classes: classes, text: t.to_s)
      end
    end
    out.decls << Decl.new(owner: owner, ivar: name.delete_prefix('@'), fields: fields,
                          nilable: type.is_a?(RBS::Types::Optional), text: type.to_s, loc: loc)
  end

  def field_classes(type)
    return nil if type.is_a?(RBS::Types::Bases::Any)

    classes = RbsSignatures.value_classes_of(type)
    classes ? classes.to_set(&:to_s) : :unsupported
  end

  def loc_of(node, rel)
    l = node.location
    RbsSignatures::Loc.new(rel, l ? l.start_line : 1, l ? l.start_column + 1 : 1)
  end

  def diag(list, loc, severity, code, message)
    list << RbsSignatures::Diag.new(file: loc.file, line: loc.line, col: loc.col, severity: severity, code: code,
                                    message: message)
  end

  # ------------------------------------------------------------------------------------------------ checker

  # +outside_ivars+: ivar names a native or foreign source spells (outside_ivar_names). +superclass_of+: the
  # registry's class tree. +value_class+: optional ->(irep, idx, reg) { class name or nil } tried after the
  # built-in literal / constructor tracing. +display_root+ shortens the file names of the diagnostics.
  # +escape_world+: the EscapeAnalysis::World the interprocedural scan resolves callees and capture summaries
  # with (nil: passing the Hash to any method is an escape).
  def check(loaded, ireps, registry, closed_world:, native_paths:, foreign_paths:, outside_ivars:, superclass_of:,
            container_constants: nil, value_class: nil, display_root: nil,
            escape_world: (EscapeAnalysis.world if EscapeAnalysis.enabled?))
    result = Result.new(verified: {}, diagnostics: loaded.diagnostics.dup, hints: {}, readers: Set.new)
    return result if loaded.decls.empty?

    known_owners = registry.values.flatten.map(&:owner).to_set
    by_name = loaded.decls.group_by(&:ivar)
    refusal = world_refusal(closed_world)
    poison = (RecordHash::Poison.new(ireps, registry, closed_world, native_paths, foreign_paths) unless refusal)
    refusal ||= poison.global && "reflection in the program (#{poison.global})"
    sites = refusal ? {} : collect_sites(ireps, by_name.keys, poison.readers)
    ctx = { registry: registry, superclass_of: superclass_of, known_owners: known_owners, root: display_root,
            container_constants: container_constants, value_class: value_class, closed_world: closed_world,
            owner_of: body_owners(ireps, registry), escape_world: escape_world }
    by_name.each do |name, decls|
      errors = []
      decl = decls.first
      if decls.map(&:text).uniq.size > 1
        errors << [decls.last.loc, "@#{name} is declared twice with different record types (one per ivar name)"]
      end
      decls.each do |d|
        errors << [d.loc, "#{d.owner}: no such class in the program"] unless known_owners.include?(d.owner)
      end
      why = refusal || poison.reason(name)
      why ||= 'spelled by a source outside the typed analysis' if outside_ivars.include?(name)
      if why
        errors << [decl.loc, "#{decl.owner}#@#{name}: declaration refused: #{why}"]
      elsif errors.empty?
        found, slot = verify(name, decl, sites[name], ctx)
        errors.concat(found)
      end
      if errors.empty?
        result.verified[name] = slot
        hint = hint_table(decl, known_owners)
        result.hints[name] = hint unless hint.empty?
        result.readers << name if poison.readers.include?(name) &&
                                  registry[name].all? { |d| d.kind == :ivar_accessor }
      else
        errors.uniq.each do |loc, msg|
          result.diagnostics << RbsSignatures::Diag.new(file: loc.file, line: loc.line, col: loc.col, severity: 'error',
                                                        code: CODE, message: msg)
        end
      end
    end
    result
  end

  def world_refusal(closed_world)
    return "closed world refusal #{closed_world.global_refusal}" if closed_world.global_refusal

    nil
  end

  def collect_sites(ireps, names, readers)
    wanted = names.to_set
    sites = Hash.new { |h, k| h[k] = { sets: [], gets: [], calls: [] } }
    ireps.each_value do |irep|
      irep.each_with_op(:SETIV, :GETIV) do |insn, i|
        name = insn.ivar
        next unless wanted.include?(name)

        (insn.op == :SETIV ? sites[name][:sets] : sites[name][:gets]) << [irep, i]
      end
      irep.each_with_op(*BytecodeIR::Ops::CALL) do |insn, i|
        sites[insn.sym][:calls] << [irep, i] if wanted.include?(insn.sym) && readers.include?(insn.sym)
      end
    end
    sites
  end

  # label => owner of the method whose body (or nested block) the irep is.
  def body_owners(ireps, registry)
    map = {}
    registry.each_value do |defs|
      defs.each do |d|
        stack = [d.irep].compact
        until stack.empty?
          label = stack.pop
          next if map.key?(label)

          map[label] = d.owner
          stack.concat(ireps[label]&.reps || [])
        end
      end
    end
    map
  end

  # [[loc, message] errors, RecordHash slot table] for one declared name.
  def verify(name, decl, sites, ctx)
    sites ||= { sets: [], gets: [], calls: [] }
    scanner = DeclScanner.new(name, sites, nil, ctx[:closed_world], ctx[:registry], decl, ctx[:root],
                              escape_world: ctx[:escape_world])
    errors = scanner.run_all
    return [errors, nil] unless errors.empty?

    keys = scanner.slot_keys
    scanner.writes.each do |keys_written, irep, idx, reg|
      keys_written.each do |key|
        field = decl.fields[key]
        unless field
          errors << [site_loc(irep, idx, ctx[:root]), "#{decl.owner}#@#{name}: key :#{key} is not declared"]
          next
        end
        next unless field.classes

        value_errors(irep, idx, reg, field, ctx).each do |msg|
          errors << [site_loc(irep, idx, ctx[:root]), "#{decl.owner}#@#{name}: #{msg}"]
        end
      end
    end
    scanner.literal_keys.each do |(irep, idx), present|
      missing = decl.fields.values.reject(&:optional).map(&:key) - present.to_a
      next if missing.empty?

      errors << [site_loc(irep, idx, ctx[:root]),
                 "#{decl.owner}#@#{name}: a Hash literal stored into it omits required key(s) " \
                 "#{missing.map { |k| ":#{k}" }.join(', ')} (declare them `?key:`)"]
    end
    scanner.nil_stores.each do |irep, idx|
      next if decl.nilable

      errors << [site_loc(irep, idx, ctx[:root]),
                 "#{decl.owner}#@#{name}: nil is stored but the type is not `{ ... }?`"]
    end
    [errors, keys]
  end

  def value_errors(irep, idx, reg, field, ctx)
    defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s, through_handlers: true, shared: true)
    return ["value of :#{field.key} cannot be traced (declare it untyped)"] if defs.nil? || defs.empty?

    defs.filter_map do |d|
      cls = d.entry? ? nil : value_class_at(irep, d.index, d.reg, ctx)
      if cls.nil?
        "value of :#{field.key} cannot be traced to a class (declared #{field.text}; declare it untyped)"
      elsif !conforms?(cls, field.classes, ctx[:superclass_of])
        "value of :#{field.key} is #{cls}, declared #{field.text}"
      end
    end
  end

  def value_class_at(irep, index, reg, ctx)
    scanner_class = LITERAL_CLASS.call(irep, index)
    return scanner_class if scanner_class

    insn = BytecodeIR.for(irep).source_at(index)
    if BytecodeIR::Ops::COUNTED_SEND.include?(insn.op) && insn.sym == 'new'
      klass = trace_new_target(irep, index + 1, insn.reg, nil, 0, nil, owner: ctx[:owner_of][irep.label],
                                                                       registry: ctx[:registry],
                                                                       container_constants: ctx[:container_constants],
                                                                       known_owners: ctx[:known_owners])
      return klass if klass && (ctx[:known_owners].include?(klass) || BASE_CLASSES.include?(klass))
    end
    ctx[:value_class]&.call(irep, index + 1, reg)
  end

  LITERAL_CLASS = lambda do |irep, d|
    insn = BytecodeIR.for(irep).source_at(d)
    case insn.op
    when :ARRAY then 'Array'
    when :HASH then 'Hash'
    when :STRING then 'String'
    when :LOADSYM then 'Symbol'
    when :LOADTRUE then 'TrueClass'
    when :LOADFALSE then 'FalseClass'
    when :LOADNIL then 'NilClass'
    when *BytecodeIR::Ops::RANGE_BUILD then 'Range'
    when :LOADL
      entry = irep.pool[insn.pool_index]
      entry.is_a?(Hash) && entry[:type] == :float ? 'Float' : (entry.is_a?(Hash) ? 'Integer' : nil)
    else BytecodeIR::Ops::LOADI_OPS.include?(insn.op) ? 'Integer' : nil
    end
  end

  def conforms?(cls, allowed, superclass_of)
    seen = Set.new
    cur = cls
    while cur.is_a?(String) && seen.add?(cur)
      return true if allowed.include?(cur)

      cur = superclass_of[cur]
    end
    false
  end

  # key => class for every field that names exactly one class besides nil.
  def hint_table(decl, known_owners)
    decl.fields.each_value.with_object({}) do |f, out|
      next unless f.classes

      classes = f.classes - ['NilClass']
      next unless classes.size == 1

      cls = classes.first
      out[f.key] = cls if known_owners.include?(cls) || BASE_CLASSES.include?(cls)
    end
  end

  def site_loc(irep, idx, root)
    file = irep.file.to_s
    file = file.sub(%r{\A#{Regexp.escape(root)}/?}, '') if root
    RbsSignatures::Loc.new(file, BytecodeIR.for(irep).source_at(idx)&.lineno.to_i, 1)
  end

  # The guarded receiver hint of the GETIDX at +index+: the one class every record key it can read declares.
  def read_hint(irep, index)
    table = hints or return nil
    pairs = RecordHash.read_slots(irep, index) or return nil
    classes = pairs.map { |name, key| table.dig(name, key) }
    classes.first if classes.all? && classes.uniq.size == 1
  end

  # The driver step: load, check, list, install. Errors join +diagnostics+ (the signature diagnostics the type
  # check reports) and abort a build, as RBS_SEED_CONTRADICTION does.
  def drive(files, diagnostics, ireps, registry, display_root:, closed_world:, native_paths:, foreign_paths:,
            superclass_of:, container_constants:)
    loaded = load(files, display_root: display_root)
    outside = outside_ivar_names(native_paths + foreign_paths)
    result = check(loaded, ireps, registry, closed_world: closed_world, native_paths: native_paths,
                                            foreign_paths: foreign_paths, outside_ivars: outside,
                                            superclass_of: superclass_of, container_constants: container_constants,
                                            display_root: display_root, value_class: array_value(registry))
    install(result)
    report(result, loaded)
    diagnostics.concat(result.diagnostics)
    errors = result.diagnostics.count { |d| d.severity == 'error' }
    return result if errors.zero? || !ENV['BC2CPP_TYPE_FACTS'].to_s.empty?

    abort "\n[bc2cpp] RBS_RECORD_TYPES: #{errors} record declaration error(s) (see above). Fix the declaration, " \
          'or the code it claims to describe.'
  end

  # The Array rule ClassLayout's ivar facts use (proven_array_source_scan: a block `map`/`select`/`reject`, a
  # core method returning a fresh Array, an `-> Array` annotation), as a value tracer.
  def array_value(registry)
    lambda do |irep, idx, reg|
      next nil unless defined?(proven_array_source_scan)

      'Array' if proven_array_source_scan(irep, idx, reg.to_s, registry) == 'Array'
    end
  end

  def report(result, loaded)
    declared = loaded.decls.map(&:ivar).uniq.size
    warn "== record types (RBS_RECORD_TYPES): #{result.verified.size} of #{declared} verified =="
    loaded.decls.each do |d|
      next unless result.verified.key?(d.ivar)

      hints = (result.hints[d.ivar] || {}).sort.map { |k, c| ":#{k} #{c}" }.join(', ')
      warn "  RECORD_TYPE  #{d.owner}#@#{d.ivar}  (#{d.fields.size} keys; hints: #{hints.empty? ? 'none' : hints})"
    end
    result.diagnostics.each { |x| warn "  #{x.file}:#{x.line}:#{x.col}: #{x.severity}: #{x.message} [#{x.code}]" }
    warn ''
  end

  # Installs a check result: verified names join RecordHash's table and readers, hints become visible.
  def install(result)
    RecordHash.table = (RecordHash.table || {}).merge(result.verified)
    RecordHash.readers = (RecordHash.readers || Set.new) | result.readers
    self.hints = result.hints
  end

  # RecordHash::Scanner with the extra writers a declaration admits, every failure located, and every
  # scan run (not just up to the first failure).
  class DeclScanner < RecordHash::Scanner
    attr_reader :writes, :nil_stores

    def initialize(name, sites, trusted, closed_world, registry, decl, root, escape_world: nil)
      super(name, sites, trusted, closed_world, registry)
      @decl = decl
      @root = root
      @escape_world = escape_world
      @analyzer = nil
      @callee_scans = Set.new # [callee label, parameter register] scanned or being scanned
      @depth = 0
      @errors = []
      @writes = [] # [keys, irep, index, value register]
      @nil_stores = []
    end

    def run_all
      @sites[:sets].each do |irep, i|
        @where = [irep, i]
        store_ok?(irep, i)
      end
      @where = nil
      %i[gets calls].each do |kind|
        @sites[kind].each { |irep, i| alias_scan(irep, i, BytecodeIR.for(irep).source_at(i).reg.to_i) }
      end
      @literals.each { |irep, d| literal_scan(irep, d) }
      if @literals.empty? && @errors.empty?
        @errors << [@decl.loc, "#{@decl.owner}#@#{@name}: no Hash literal is stored into it"]
      end
      return @errors unless @errors.empty?

      @literal_pairs.each { |irep, d, keys, vreg| @writes << [keys, irep, d, vreg] }
      @stores.each { |keys, irep, i, vreg| @writes << [keys, irep, i, vreg] }
      @errors
    end

    def slot_keys
      join_keys
    end

    # [[irep, hash index], Set of keys] of every literal stored into the ivar.
    def literal_keys
      per = @literals.to_h { |irep, d| [[irep, d], Set.new] }
      @literal_pairs.each { |irep, d, keys, _| per[[irep, d]]&.merge(keys) }
      per
    end

    private

    def record_error(why)
      irep, k = @where
      loc = irep ? RbsRecordTypes.site_loc(irep, k, @root) : @decl.loc
      @errors << [loc, "#{@decl.owner}#@#{@name}: #{why} (a write or use the record type cannot verify)"]
    end

    def fail!(why)
      record_error(why)
      @failure ||= why
      false
    end

    def escape(why)
      record_error(why)
      @failure ||= why
      nil
    end

    def store_ok?(irep, i)
      insn = BytecodeIR.for(irep).source_at(i)
      defs = BytecodeIR.reaching_definitions(irep, i, insn.regs.first, through_handlers: true, shared: true)
      return fail!('store source not provable') if defs.nil? || defs.empty?

      defs.each do |d|
        src = d.entry? ? nil : BytecodeIR.for(irep).source_at(d.index)
        if src&.op == :LOADNIL
          @nil_stores << [irep, i]
        elsif src&.op == :HASH
          @literals << [irep, d.index] unless @literals.any? { |l, x| l.equal?(irep) && x == d.index }
        else
          fail!(d.entry? ? 'store from an argument' : "store from #{src.op} (only a Hash literal or nil)")
        end
      end
      true
    end

    def step(irep, k, insn, state)
      lead = insn.reg&.to_i
      if insn.op == :SEND && lead && state.include?(lead)
        case insn.sym
        when 'update', 'merge!' then return update_step(irep, k, insn, state, lead)
        when 'store' then return store_step(irep, k, insn, state, lead)
        when 'delete' then return declared_delete_step(irep, k, insn, state, lead)
        when *READ_SENDS then return read_step(insn, state, lead)
        when *NIL_TESTS then return nil_test_step(insn, state, lead)
        when '!=' then return nil_compare_step(irep, k, insn, state, lead)
        end
      end
      return nil_test_step(insn, state, lead) if insn.op == :SEND0 && lead && state.include?(lead) &&
                                                 NIL_TESTS.include?(insn.sym)
      return nil_compare_step(irep, k, insn, state, lead) if insn.op == :EQ && state.include?(lead)
      if BytecodeIR::Ops::SEND.include?(insn.op) && lead
        unless held_call?(insn, state, lead)
          # Only a self send's leading register held it: overwritten with self, nothing is passed.
          return state.include?(lead) ? state.reject { |x| x >= lead }.to_set : super
        end
        held = held_positions(insn, state, lead)
        return call_step(insn, state, lead, held) if held
      end
      super
    end

    # A block in a callee that reads the parameter outlives the scan of the callee's own frame: an escape. In
    # the declaring code a captured read is an alias source of its own (RecordHash::Scanner).
    def scan_captures(irep, reg)
      return escape('captured by a block inside a callee') if @depth.positive? && !captured_reads(irep, reg).empty?

      super
    end

    # `h.nil?` / `!h`: a truth test of the receiver, unless the program or an outside source redefines it where
    # a Hash can reach it (the same check as update/merge!).
    def nil_test_step(insn, state, lead)
      return escape("Hash##{insn.sym} may be redefined") unless native_hash?(insn.sym)
      return escape("#{insn.sym} arity") unless insn.op == :SEND0 || plain_args?(insn, 0)

      state.reject { |x| x >= lead }.to_set
    end

    # `h == nil` (OP_EQ) / `h != nil`: an identity test against a literal nil.
    def nil_compare_step(irep, k, insn, state, lead)
      name = insn.op == :EQ ? '==' : '!='
      return escape("Hash##{name} may be redefined") unless native_hash?('==') && native_hash?(name)
      return escape("#{name} arity") unless insn.op == :EQ || plain_args?(insn, 1)
      return escape("#{name} of the Hash with itself") if state.include?(lead + 1)

      defs = BytecodeIR.reaching_definitions(irep, k, (lead + 1).to_s, through_handlers: true, shared: true)
      nil_operand = defs && !defs.empty? && defs.all? { |d| !d.entry? && BytecodeIR.for(irep).source_at(d.index).op == :LOADNIL }
      return escape("#{name} against a value other than nil") unless nil_operand

      state.reject { |x| x >= lead }.to_set
    end

    # Does the send read a register holding the Hash? A self send (SSEND*) only writes self into its leading
    # register, so the Hash there is dropped, not passed.
    def held_call?(insn, state, lead)
      self_send = BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op)
      hi = read_span(insn, lead)
      state.any? { |x| x >= lead && x <= hi && !(self_send && x == lead) }
    end

    # A send that takes the Hash: not an escape when the Hash is a plain positional
    # argument and, for every definition the name can reach, ESCAPE_ANALYSIS says the callee keeps none of
    # those arguments and the callee's parameter, scanned as one more alias of the Hash, passes these same
    # rules (its key writes join the checked stores). Anything else keeps the base rule (an escape).
    def call_step(insn, state, lead, held_args)
      return escape("receiver of #{insn.sym}") if !BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op) && state.include?(lead)
      return escape("passed to #{insn.sym} with a block") if BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(insn.op)
      return escape("passed to #{insn.sym} past the scan depth") if @depth >= INTERPROC_DEPTH

      world = @escape_world or return escape("passed to #{insn.sym} (no escape analysis world)")
      @analyzer ||= EscapeAnalysis::Analyzer.new(world)
      callees = world.defs_named(insn.sym)
      return escape("passed to #{insn.sym}, whose definitions cannot be enumerated") if callees.nil?

      held_args.each do |j|
        # The Hash is a literal never handed to anything that could extend it: exactly a Hash.
        next unless @analyzer.name_captures_arg?(insn.sym, j, klass: 'Hash')

        why = if world.native_name?(insn.sym) then 'has a native definition (no audited argument fact)'
              elsif callees.empty? then 'has no definition'
              else "may keep argument #{j + 1}"
              end
        return escape("passed to #{insn.sym}, which #{why} (ESCAPE_ANALYSIS)")
      end
      callees.each do |d|
        held_args.each { |j| return nil unless callee_ok?(d, j, insn.sym) }
      end
      state.reject { |x| x >= lead }.to_set
    end

    # 0-based positional argument indices that hold the Hash, or nil when it sits anywhere else in the window
    # (a splat, a keyword, the block) or the argument layout is not a plain count.
    def held_positions(insn, state, lead)
      n = BytecodeIR::Ops::ZERO_ARG_SEND.include?(insn.op) ? 0 : insn.argc
      spec = insn.argc_operand
      return nil if n.nil? || (spec && (spec[1].nil? || spec[1].to_i.positive?))

      block = BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(insn.op) ? lead + n + 1 : nil
      return nil if block && state.include?(block)

      found = (1..n).select { |j| state.include?(lead + j) }.map { |j| j - 1 }
      found.empty? ? nil : found
    end

    # The parameter of +d+ that receives argument +j+, scanned once per (body, register): a frame being scanned
    # is assumed to pass (co-inductive), which is sound because any failure in the cycle refuses the declaration.
    def callee_ok?(d, j, name)
      label = d.installer ? nil : d.irep
      callee = label && @escape_world.ireps[label]
      unless callee
        escape("passed to #{name}, a definition (#{d.owner}) without a scannable body")
        return false
      end
      fields = callee.enter&.enter_fields || []
      if fields[4].to_i.positive? || fields[5].to_i.positive? || j >= fields[0].to_i
        escape("passed to #{name} (#{d.owner}) as other than a mandatory positional parameter")
        return false
      end
      return true unless @callee_scans.add?([callee.label, j + 1])

      saved = [@where, @site]
      @where = [callee, 0]
      @depth += 1
      ok = alias_scan(callee, 0, j + 1, from_entry: true)
      @depth -= 1
      @where, @site = saved
      ok
    end

    # The receiver is a Hash literal (never extended: any other send escapes), so only a definer that can land
    # on Hash instances matters; mruby-hash-ext's own `merge!`/`alias update merge!` is core. A definer inside
    # `class << Const` (mruby-rgss's Graphics.update probe) answers that object only (instance_unknown_def?).
    def native_hash?(name)
      cw = @closed_world
      return false if cw.global_refusal || cw.instance_unknown_def?(name)
      return false if (@registry[name] || []).any? { |d| HASH_OWNERS.include?(d.owner) }

      !ForeignDefiners.defines?(cw.outside_ruby_paths.reject { |path| CoreDefs.core_source?(path) }, 'Hash', name)
    end

    def plain_args?(insn, count)
      insn.argc == count && insn.argc_operand && insn.argc_operand[1].to_i.zero?
    end

    # `h.update({k: v, ...})`: each pair is a store; the result is the Hash itself.
    def update_step(irep, k, insn, state, lead)
      return escape("Hash##{insn.sym} may be redefined") unless native_hash?(insn.sym) && native_hash?('__merge')
      return escape("#{insn.sym} arity (one Hash literal, no block)") unless plain_args?(insn, 1)
      return escape("#{insn.sym} of the Hash itself") if state.include?(lead + 1)

      defs = BytecodeIR.reaching_definitions(irep, k, (lead + 1).to_s, through_handlers: true, shared: true)
      lit = defs&.size == 1 && !defs.first.entry? && BytecodeIR.for(irep).source_at(defs.first.index)
      return escape("non-literal #{insn.sym}") unless lit && lit.op == :HASH && lit.uint_operand

      base = lit.reg.to_i
      lit.uint_operand.times do |j|
        keys = RecordHash.literal_keys(irep, defs.first.index, base + 2 * j)
        return escape("computed key in #{insn.sym}") unless keys

        @stores << [keys, irep, defs.first.index, base + 2 * j + 1]
      end
      state.reject { |x| x > lead }.to_set | [lead]
    end

    def store_step(irep, k, insn, state, lead)
      return escape('Hash#store may be redefined') unless native_hash?('store')
      return escape('store arity') unless plain_args?(insn, 2)
      return escape('stored as a value or key') if state.include?(lead + 1) || state.include?(lead + 2)

      keys = RecordHash.literal_keys(irep, k, lead + 1, for_write: true) or return escape('non-literal key store')
      @stores << [keys, irep, k, lead + 2]
      state.reject { |x| x >= lead }.to_set
    end

    def declared_delete_step(irep, k, insn, state, lead)
      keys = RecordHash.literal_keys(irep, k, lead + 1, for_write: true)
      required = Array(keys).reject { |key| @decl.fields[key]&.optional }
      return escape("delete of required key(s) #{required.map { |x| ":#{x}" }.join(', ')}") unless required.empty?

      delete_step(irep, k, insn, state, lead)
    end

    def read_step(insn, state, lead)
      return escape("Hash##{insn.sym} may be redefined") unless native_hash?(insn.sym)
      return escape("operand of #{insn.sym}") if insn.op != :SEND || insn.argc.nil? ||
                                                   (1..insn.argc).any? { |j| state.include?(lead + j) }

      state.reject { |x| x >= lead }.to_set
    end
  end
end
