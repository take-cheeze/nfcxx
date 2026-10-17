# frozen_string_literal: true

require 'set'
require_relative 'annotations'
require_relative 'core_fact_sigs'
require_relative 'native_sigs'
require_relative 'rbs_optional_hint'

# RBS_SIGNATURES (docs/adr/0413): RBS files as a source of the same hints the `# bc2cpp:` comments give.
#
# Directories come from BC2CPP_SIG_DIRS (File::PATH_SEPARATOR list; an empty value switches the feature off). Unset, the
# default is <repo>/sig/bc2cpp when it exists. With no .rbs file the compiler behaves exactly as before (nothing here
# runs, nothing is printed), so output is byte-identical. The compiler tooling runs under CRuby, so the `rbs` gem
# (a bundled gem of CRuby 3.x) does the parsing; without it a clear TC1002 diagnostic is produced, never a silent skip.
#
# Supported subset (everything else is listed, never dropped silently):
#   used     class / module (nested or `A::B`, reopened across files); `def name: (T a, T b) -> R` with required
#            positional parameters and one overload; `@ivar: T`; `attr_reader/attr_accessor name: T` (an ivar type).
#            Types: Integer (fixnum) and Symbol (embedding hints), Array / Hash (container hints), Array[C] / Hash[K, C]
#            (element class C), and any class name the program defines (class hint).
#   noted    (TC1005 info: accepted, gives no hint) optional / rest / keyword / block parameters and block types, `T?`,
#            unions, `untyped`, `void`, `bool`, `nil`, `self`, literal types, generics other than Array[]/Hash[], a class
#            the program does not define, constants, aliases, interfaces, mixins, visibility, a method
#            whose parameter count is not the definition's.
#   ADR 0456 `def self.x` returns type constant-receiver calls (RBS_SINGLETON_RETURN); an ivar `T?` and a return
#            `C?` feed the nil-tolerant facts (rbs_optional_hint.rb); a class parameter is checked at every caller
#            (rbs_param_check.rb).
#   error    (TC1002) a parse error, an overloaded `def`, any declaration or member kind not listed above.
# IR contracts separately retain nominal value classes for nullable, union, bool, nil and literal types;
# matched arguments, ivars and call returns seed IR queries (ADR 0442), without changing hint kinds.
# Receiver-relative self returns and runtime mixin lookup remain conditional reporting contracts.
# A signature never overrides a `# bc2cpp:` comment: where both name a slot the comment wins and the difference is TC1006.
module RbsSignatures
  Diag = Struct.new(:file, :line, :col, :severity, :code, :message, keyword_init: true) do
    def to_h = { 'file' => file, 'line' => line, 'col' => col, 'severity' => severity, 'code' => code, 'message' => message }
  end
  # native: the declaration is in a native signature file (NativeSigs), not a program declaration.
  Loc = Struct.new(:file, :line, :col, :native)
  # args: one Type per required positional parameter; ret: Type or nil
  MethodSig = Struct.new(:owner, :name, :args, :optional_args, :keywords, :required_keywords, :ret, :loc, :type_params, :argument_types, :return_type, :block_type, :type_param_bounds, :callback_supported, keyword_init: true)
  IvarSig = Struct.new(:owner, :name, :type, :loc, keyword_init: true)
  # kind: :int :sym :array :hash :class :other ; cls: class name (:class), element: class name for Array[C]/Hash[K, C]
  # optional: for `T?`, T's own Type (RBS_OPTIONAL_HINT, docs/adr/0456); the `T?` Type itself stays kind :other.
  Type = Struct.new(:kind, :cls, :element, :text, :value_classes, :self_return, :element_classes, :optional,
                    keyword_init: true)
  Loaded = Struct.new(:methods, :ivars, :diagnostics, :files, :supers, keyword_init: true)
  # SUBTREE_DISPATCH (docs/adr/0453): a `class C < S` declaration, checked against the program's own superclass.
  SuperDecl = Struct.new(:name, :super_name, :scope, :loc, keyword_init: true)


  module_function

  def dirs_from_env(root)
    value = ENV['BC2CPP_SIG_DIRS']
    return value.empty? ? [] : value.split(File::PATH_SEPARATOR) if value

    default = File.join(root, 'sig')
    File.directory?(default) ? [default] : []
  end

  def files_in(dirs)
    dirs.flat_map { |d| File.file?(d) ? [d] : Dir[File.join(d, '**/*.rbs')] }.sort
  end

  # The fact tables (CoreFactSigs::TABLES) are read by their own loaders and are not program signatures: some name
  # methods with mrblib bodies (Kernel#to_enum, Proc#yield), which a declaration would hint.
  def fact_table?(decl)
    name = NativeSigs.table_of(decl)
    !name.nil? && CoreFactSigs::TABLES.include?(NativeSigs.table(name))
  end

  # nil when there is nothing to load (the byte-identical path).
  def load(dirs, display_root: nil)
    files = files_in(dirs)
    return nil if files.empty?

    out = Loaded.new(methods: {}, ivars: {}, diagnostics: [], files: files, supers: [])
    begin
      require 'rbs'
    rescue LoadError
      out.diagnostics << Diag.new(file: files.first, line: 1, col: 1, severity: 'error', code: 'TC1002',
                                  message: 'the `rbs` gem is not installed (gem install rbs); signature files cannot be read')
      return out
    end
    files.each do |file|
      rel = display_root ? file.sub(%r{\A#{Regexp.escape(display_root)}/?}, '') : file
      begin
        _buf, _dirs, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: rel, content: File.read(file)))
      rescue RBS::ParsingError => e
        loc = e.location
        out.diagnostics << Diag.new(file: rel, line: loc ? loc.start_line : 1, col: loc ? loc.start_column + 1 : 1, severity: 'error',
                                    code: 'TC1002', message: "RBS syntax error: #{e.message.sub(/\A\S+:\d+:\d+\.\.\.\d+:\d+: /, '')}")
        next
      end
      decls.each { |d| declaration(out, d, [], rel, NativeSigs.native?(d)) unless fact_table?(d) }
    end
    out
  end

  def loc_of(node, rel, native)
    l = node.location
    Loc.new(rel, l ? l.start_line : 1, l ? l.start_column + 1 : 1, native)
  end

  def diag(out, loc, severity, code, message)
    out.diagnostics << Diag.new(file: loc.file, line: loc.line, col: loc.col, severity: severity, code: code, message: message)
  end

  def declaration(out, decl, scope, rel, native)
    case decl
    when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
      name = (scope + [decl.name.to_s.delete_prefix('::')]).join('::')
      if decl.is_a?(RBS::AST::Declarations::Class) && decl.super_class && out.supers
        out.supers << SuperDecl.new(name: name, super_name: decl.super_class.name.to_s, scope: name.split('::')[0...-1],
                                    loc: loc_of(decl, rel, native))
      end
      decl.members.each { |m| member(out, m, name, rel, native) }
      decl.members.grep(RBS::AST::Declarations::Base).each { |inner| declaration(out, inner, [name], rel, native || NativeSigs.native?(inner)) }
    when RBS::AST::Declarations::Constant, RBS::AST::Declarations::TypeAlias, RBS::AST::Declarations::Interface
      diag(out, loc_of(decl, rel, native), 'info', 'TC1005', "#{decl.class.name.split('::').last} #{decl.name} is accepted but gives no hint")
    else
      diag(out, loc_of(decl, rel, native), 'error', 'TC1002', "unsupported RBS syntax: #{decl.class.name.split('::').last} declaration")
    end
  end

  def member(out, m, owner, rel, native)
    kind = m.class.name.split('::').last
    loc = loc_of(m, rel, native)
    case m
    when RBS::AST::Declarations::Base
      nil # handled by declaration
    when RBS::AST::Members::MethodDefinition
      method_definition(out, m, owner, loc)
    when RBS::AST::Members::InstanceVariable
      out.ivars[[owner, m.name.to_s]] = IvarSig.new(owner: owner, name: m.name.to_s, type: type_of(m.type), loc: loc)
    when RBS::AST::Members::AttrReader, RBS::AST::Members::AttrAccessor
      if m.kind == :singleton
        diag(out, loc, 'info', 'TC1005', "singleton #{kind} #{m.name} is accepted but gives no hint")
      else
        iv = (m.ivar_name.is_a?(Symbol) ? m.ivar_name : "@#{m.name}").to_s
        out.ivars[[owner, iv]] = IvarSig.new(owner: owner, name: iv, type: type_of(m.type), loc: loc)
      end
    when RBS::AST::Members::Public, RBS::AST::Members::Private, RBS::AST::Members::Alias, RBS::AST::Members::Include,
         RBS::AST::Members::Extend, RBS::AST::Members::Prepend, RBS::AST::Members::AttrWriter
      diag(out, loc, 'info', 'TC1005', "#{kind} is accepted but gives no hint")
    else
      diag(out, loc, 'error', 'TC1002', "unsupported RBS syntax: #{kind} member")
    end
  end

  def method_definition(out, m, owner, loc)
    if m.overloads.size != 1
      # A native declaration may list several overloads (join with and without a separator); it is not a hint.
      if loc.native
        diag(out, loc, 'info', 'TC1005', "#{owner}##{m.name}: #{m.overloads.size} native overloads; no program hint")
        return
      end
      diag(out, loc, 'error', 'TC1002',
           "unsupported RBS syntax: #{m.name} has #{m.overloads.size} overloads (one signature per method; write the union as untyped)")
      return
    end
    mt = m.overloads.first.method_type
    fn = mt.type
    args = fn.required_positionals.map { |p| type_of(p.type) }
    extras = []
    extras << 'optional parameters' unless fn.optional_positionals.empty?
    extras << 'a rest parameter' if fn.rest_positionals
    extras << 'trailing parameters' unless fn.trailing_positionals.empty?
    extras << 'keyword parameters' unless fn.required_keywords.empty? && fn.optional_keywords.empty? && !fn.rest_keywords
    extras << 'a block type' if mt.block
    diag(out, loc, 'info', 'TC1005', "#{owner}##{m.name}: #{extras.join(', ')} accepted but give no hint") unless extras.empty?
    # `def self.x` is keyed by the owner the IR names singleton methods with (`Klass.singleton`).
    owner = "#{owner}.singleton" unless m.kind == :instance
    fresh = MethodSig.new(owner: owner, name: m.name.to_s, args: args,
                                                               optional_args: fn.optional_positionals.map { |param| type_of(param.type) },
                                                               keywords: (fn.required_keywords.merge(fn.optional_keywords)).to_h { |name, param| [name.to_s, type_of(param.type)] },
                                                               required_keywords: fn.required_keywords.keys.map(&:to_s).to_set,
                                                               ret: type_of(fn.return_type), loc: loc,
                                                               type_params: mt.type_params.map { |param| param.name.to_s }.freeze,
                                                               argument_types: fn.required_positionals.map(&:type).freeze,
                                                               return_type: fn.return_type, block_type: mt.block,
                                                               type_param_bounds: mt.type_params.to_h { |param| [param.name.to_s, param.upper_bound_type || param.default_type] }.freeze,
                                                               callback_supported: fn.optional_positionals.empty? && !fn.rest_positionals && fn.trailing_positionals.empty? && fn.required_keywords.empty? && fn.optional_keywords.empty? && !fn.rest_keywords)
    key = [owner, m.name.to_s]
    out.methods[key] = out.methods.key?(key) ? merge_method_sig(out.methods[key], fresh) : fresh
  end

  # A second declaration of one method (another file, or the same method in two signature files) fills the slots the
  # first left untyped; where both are typed, the later declaration wins, as before.
  def merge_method_sig(prev, fresh)
    untyped = ->(t) { t.nil? || (t.kind == :other && t.text == 'untyped') }
    merged = fresh.dup
    merged.args = fresh.args.each_with_index.map { |t, i| untyped.(t) && prev.args[i] && !untyped.(prev.args[i]) ? prev.args[i] : t }
    if untyped.(fresh.ret) && prev.ret && !untyped.(prev.ret)
      merged.ret = prev.ret
      merged.return_type = prev.return_type
    end
    merged
  end

  def type_of(t)
    type = hint_type_of(t)
    type.value_classes = value_classes_of(t)
    type.self_return = t.is_a?(RBS::Types::Bases::Self)
    type.optional = type_of(t.type) if t.is_a?(RBS::Types::Optional)
    if t.is_a?(RBS::Types::ClassInstance)
      name = t.name.to_s.delete_prefix('::')
      element = if name == 'Array' && t.args.size == 1 then t.args.first
                elsif name == 'Hash' && t.args.size == 2 then t.args.last
                end
      type.element_classes = value_classes_of(element) if element
    end
    type
  end

  def hint_type_of(t)
    text = t.to_s
    case t
    when RBS::Types::ClassInstance
      name = t.name.to_s.delete_prefix('::')
      args = t.args
      case name
      when 'Integer' then args.empty? ? Type.new(kind: :int, text: text) : Type.new(kind: :other, text: text)
      when 'Symbol' then Type.new(kind: :sym, text: text)
      when 'Array'
        elem = args.size == 1 ? class_name_of(args.first) : nil
        Type.new(kind: :array, element: elem, text: text)
      when 'Hash'
        elem = args.size == 2 ? class_name_of(args.last) : nil
        Type.new(kind: :hash, element: elem, text: text)
      else
        args.empty? ? Type.new(kind: :class, cls: name, text: text) : Type.new(kind: :other, text: text)
      end
    else
      Type.new(kind: :other, text: text)
    end
  end

  # Nominal bounds for IR contracts, never exact-class or embedding proofs (ADR 0441).
  def value_classes_of(t)
    values = case t
             when RBS::Types::ClassInstance
               return nil unless t.args.empty? || %w[Array Hash].include?(t.name.to_s.delete_prefix('::'))

               [t.name.to_s.delete_prefix('::').to_sym]
             when RBS::Types::Optional
               inner = value_classes_of(t.type) or return nil
               inner.to_a + [:NilClass]
             when RBS::Types::Union
               members = t.types.map { |member| value_classes_of(member) }
               return nil if members.any?(&:nil?)

               members.flat_map(&:to_a)
             when RBS::Types::Bases::Bool then [:TrueClass, :FalseClass]
             when RBS::Types::ClassSingleton then [:Class]
             when RBS::Types::Bases::Nil then [:NilClass]
             when RBS::Types::Literal
               case t.literal
               when Integer then [:Integer]
               when String then [:String]
               when Symbol then [:Symbol]
               when true then [:TrueClass]
               when false then [:FalseClass]
               else return nil
               end
             else return nil
             end
    values.to_set.freeze
  end

  def class_name_of(t)
    return nil unless t.is_a?(RBS::Types::ClassInstance) && t.args.empty?

    n = t.name.to_s.delete_prefix('::')
    %w[Integer Symbol String Float Hash].include?(n) ? nil : n
  end

  # --------------------------------------------------------------------------------------------- applying

  Applied = Struct.new(:ivar_classes, :ivar_elements, :ivar_hash_elements, :origins, :locs, :diagnostics, :ivar_sigs, :ir_arg_types, :ir_return_types, :ir_named_returns, :ir_ivar_types, :ir_owners, :ir_methods, :ir_arg_elements, :ir_ivar_elements, :ir_optional_types, :ir_keyword_types, :ir_block_signatures, :subtree_ivars, :subtree_args, :subtree_returns, :based, keyword_init: true)

  # Merges the signatures into the three comment-annotation tables (irep label -> struct), in place, and returns what
  # the ivar seeds and the diagnostics are. `annotations`, `class_annotations` and `element_annotations` are what
  # Annotations / ClassAnnotations / ElementAnnotations.extract returned; comment slots win.
  # `class_decls` (build_registry's): the program's class hierarchy, for SUBTREE_DISPATCH (docs/adr/0453). A class type
  # naming a class with descendants is a subtree hint (subtree_ivars / subtree_args / subtree_returns), never the exact
  # one a class with none gives; an RBS `class C < S` must agree with the program's superclass of C (TC1016).
  def apply(loaded, ireps, registry, annotations, class_annotations, element_annotations, class_decls: nil)
    known_owners = registry.values.flatten.map(&:owner).to_set
    ap = Applied.new(ivar_classes: Hash.new { |h, k| h[k] = {} }, ivar_elements: Hash.new { |h, k| h[k] = {} },
                     ivar_hash_elements: Hash.new { |h, k| h[k] = {} }, origins: {}, locs: {}, diagnostics: loaded.diagnostics.dup,
                     ivar_sigs: loaded.ivars, ir_block_signatures: {}, ir_optional_types: {}, ir_keyword_types: {}, ir_arg_types: {}, ir_arg_elements: {}, ir_ivar_elements: {}, ir_return_types: {}, ir_named_returns: {}, ir_ivar_types: {},
                     ir_methods: registry.values.flatten.map { |d| [d.owner, d.name.to_s].freeze }.to_set.freeze,
                     ir_owners: registry.values.flatten.select(&:irep).group_by(&:irep).filter_map do |label, defs|
                       owners = defs.map(&:owner).uniq
                       [label, owners.first] if owners.size == 1
                     end.to_h.freeze,
                     subtree_ivars: Hash.new { |h, k| h[k] = {} }, subtree_args: {}, subtree_returns: {},
                     based: based_classes(class_decls))
    check_supers(ap, loaded, class_decls) if class_decls
    defs_by = {}
    registry.each_value { |defs| defs.each { |d| defs_by[[d.owner, d.name.to_s]] = d if d.irep } }
    loaded.methods.each_value do |sig|
      d = defs_by[[sig.owner, sig.name]]
      unless d
        # sig/bc2cpp declares built-in and RGSS methods the program does not define; their tables are checked by the
        # generators (scripts/bc2cpp/native_sigs_check.rb), so they are declarations here, not errors.
        if sig.loc.native
          note(ap, sig.loc, 'info', 'TC1005', "#{sig.owner}##{sig.name}: native method declaration; no program hint")
        else
          note(ap, sig.loc, 'error', 'TC1003', "#{sig.owner}##{sig.name}: no such method in the program")
        end
        next
      end
      irep = ireps[d.irep]
      mand = irep.enter ? irep.enter.enter_fields.first.to_i : 0
      if sig.args.size != mand
        note(ap, sig.loc, 'error', 'TC1004', "#{sig.owner}##{sig.name}: signature lists #{sig.args.size} required parameter(s), method takes #{mand}; not used")
        next
      end
      unless annotations[d.irep] || class_annotations[d.irep] || element_annotations[d.irep]
        ap.origins[d.irep] = 'signature'
        ap.locs[d.irep] = sig.loc
      end
      # Comment declarations own their slots; do not seed a second, conflicting IR contract.
      ap.ir_arg_types[d.irep] = sig.args.each_with_index.filter_map do |type, index|
        commented = annotations[d.irep]&.args&.[](index) || class_annotations[d.irep]&.args&.[](index) ||
                    element_annotations[d.irep]&.arg_elements&.[](index)
        [((index + 1).to_s), type.value_classes] if type.value_classes && !commented
      end.to_h.freeze if ap.ir_owners[d.irep] == sig.owner
      if ap.ir_owners[d.irep] == sig.owner
        ap.ir_arg_elements[d.irep] = sig.args.each_with_index.filter_map do |type, index|
          register = (index + 1).to_s
          [register, type.element_classes] if type.element_classes && ap.ir_arg_types[d.irep]&.key?(register)
        end.to_h.freeze
      end
      if ap.ir_owners[d.irep] == sig.owner
        runtime = ireps[d.irep]
        optional_count = runtime.enter&.enter_fields&.[](1).to_i
        if Array(sig.optional_args).size == optional_count
          ap.ir_optional_types[d.irep] = Array(sig.optional_args).each_with_index.filter_map do |type, index|
            register = (mand + index + 1).to_s
            commented = annotations[d.irep]&.args&.[](mand + index) || class_annotations[d.irep]&.args&.[](mand + index) ||
                        element_annotations[d.irep]&.arg_elements&.[](mand + index)
            next if commented

            [register, type.value_classes] if type.value_classes
          end.to_h.freeze
        end
        runtime_keywords = runtime.instructions.filter_map { |insn| insn.sym.to_s if insn.op == 'KARG' }.to_set
        runtime_optional = runtime.instructions.filter_map { |insn| insn.sym.to_s if insn.op == 'KEY_P' }.to_set
        if runtime_keywords == (sig.keywords || {}).keys.to_set && runtime_keywords - runtime_optional == (sig.required_keywords || Set.new)
          ap.ir_keyword_types[d.irep] = (sig.keywords || {}).filter_map { |name, type| [name, type.value_classes] if type.value_classes }.to_h.freeze
        end
      end
      comment_return = annotations[d.irep]&.ret || element_annotations[d.irep]&.ret_class || element_annotations[d.irep]&.element
      if (sig.ret&.value_classes || sig.ret&.self_return) && !comment_return
        ap.ir_return_types[d.irep] = sig.ret.self_return ? Set[sig.owner.to_sym].freeze : sig.ret.value_classes if ap.ir_owners[d.irep] == sig.owner
        ap.ir_named_returns[[sig.owner, sig.name]] = sig.ret.self_return ? :self : sig.ret.value_classes
      end
      ap.ir_block_signatures[[sig.owner, sig.name]] = sig if sig.block_type
      merge_method(ap, sig, d, annotations, class_annotations, element_annotations, known_owners)
    end
    loaded.ivars.each_value do |iv|
      unless known_owners.include?(iv.owner)
        note(ap, iv.loc, 'error', 'TC1003', "#{iv.owner}: no such class in the program (#{iv.name})")
        next
      end
      ap.ir_ivar_types[[iv.owner, iv.name.delete_prefix('@')]] = iv.type.value_classes if iv.type.value_classes
      ap.ir_ivar_elements[[iv.owner, iv.name.delete_prefix('@')]] = iv.type.element_classes if iv.type.element_classes
      seed_ivar(ap, iv, known_owners)
    end
    ap
  end

  # Applied signatures have already been matched to the definition and its required arity.
  def ir_types(applied, irep, superclass_of: {}, included_modules: {}, prepended_modules: {}, unknown_mixins: Set.new, inferred_calls: {}, inferred_args: {}, source_resolver: nil, call_results: ENV['BC2CPP_IR_CALL_RESULTS'] != '0')
    require_relative 'bytecode_ir'
    owner = applied.ir_owners[irep.label]
    return BytecodeIR::Types.new(irep, inferred_calls: inferred_calls, inferred_args: inferred_args, source_resolver: source_resolver) unless owner

    lookup = ->(klass) { contract_owners(klass, superclass_of, included_modules: included_modules, prepended_modules: prepended_modules, unknown_mixins: unknown_mixins) }
    owners = lookup.call(owner)
    ivars = {}
    owners.reverse_each do |owner|
      applied.ir_ivar_types.each { |(decl_owner, name), types| ivars[name] = types if decl_owner == owner }
    end
    ivar_elements = {}
    owners.reverse_each do |contract_owner|
      applied.ir_ivar_types.each do |(decl_owner, name), _types|
        next unless decl_owner == contract_owner

        ivar_elements.delete(name)
        elements = applied.ir_ivar_elements[[decl_owner, name]]
        ivar_elements[name] = elements if elements
      end
    end
    calls = {}
    irep.instructions.each_with_index do |insn, index|
      # A breaking block can replace the normal return type (ADR 0443).
      next unless %w[SSEND SSEND0].include?(insn.op)

      target = owners.find { |candidate| applied.ir_methods.include?([candidate, insn.sym.to_s]) }
      types = applied.ir_named_returns[[target, insn.sym.to_s]] if target
      calls[index] = types == :self ? Set[owner.to_sym].freeze : types if types
    end
    named_returns = applied.ir_named_returns.transform_keys { |klass, name| [klass.dup.freeze, name.dup.freeze].freeze }.freeze
    resolver = lambda do |insn, receiver, refusal|
      if receiver.classes.size > 16
        refusal[:cause] ||= :call_receiver_union_cap
        next nil
      end
      classes = Set.new
      contracts = receiver.contracts.to_set
      failed = false
      receiver.classes.each do |klass|
        target = lookup.call(klass.to_s).find { |candidate| applied.ir_methods.include?([candidate, insn.sym.to_s]) }
        unless target && named_returns.key?([target, insn.sym.to_s])
          refusal[:cause] ||= "call_contract_missing:#{klass}##{insn.sym}"
          failed = true
          break
        end
        types = named_returns.fetch([target, insn.sym.to_s])
        classes.merge(types == :self ? Set[klass] : types)
        contracts << "call-result:#{target}##{insn.sym}".freeze
      end
      next nil if failed

      BytecodeIR::Types::Fact.new(classes: classes.freeze, declared: true, contracts: contracts.to_a.sort.freeze).freeze
    end
    BytecodeIR::Types.new(irep, declared_args: applied.ir_arg_types.fetch(irep.label, {}),
                         declared_optional_args: applied.ir_optional_types.fetch(irep.label, {}), declared_keywords: applied.ir_keyword_types.fetch(irep.label, {}),
                         declared_arg_elements: applied.ir_arg_elements.fetch(irep.label, {}),
                         declared_ivars: ivars, declared_ivar_elements: ivar_elements, declared_calls: calls, inferred_calls: inferred_calls, inferred_args: inferred_args, source_resolver: source_resolver, call_resolver: call_results ? resolver : nil)
  end

  # Match mruby lookup order; unknown/cyclic paths supply no inherited contracts.
  def contract_owners(owner, superclass_of, included_modules: {}, prepended_modules: {}, unknown_mixins: Set.new)
    owners = []
    visit = lambda do |current, active, inherit|
      return true unless current.is_a?(String)
      return false if active.include?(current) || unknown_mixins.include?(current)

      active = active.dup.add(current)
      Array(prepended_modules[current]).reverse_each { |mod| return false unless visit.call(mod, active, false) }
      owners << current unless owners.include?(current)
      Array(included_modules[current]).reverse_each { |mod| return false unless visit.call(mod, active, false) }
      return true unless inherit

      parent = superclass_of[current]
      parent = 'Object' if parent == :none && !%w[Object BasicObject].include?(current)
      visit.call(parent, active, true)
    end
    visit.call(owner, Set.new, true) ? owners : []
  end

  # SUBTREE_DISPATCH (docs/adr/0453): the declared classes some other declared class names as its superclass. A
  # superclass that is not itself a declared path stands for every declared class of its simple name (Ruby's lexical
  # constant lookup may reach any of them), so this over-approximates. Empty without a hierarchy.
  def based_classes(class_decls)
    return Set.new unless class_decls

    by_simple = class_decls.keys.group_by { |k| k.split('::').last }
    class_decls.values.flatten.each_with_object(Set.new) do |d, out|
      sup = d[:super]
      next unless sup.is_a?(String)

      class_decls.key?(sup) ? out << sup : out.merge(by_simple.fetch(sup.split('::').last, []))
    end
  end

  # A class type that names a class with descendants: a value of that type may be any of them.
  def based?(ap, cls)
    ap.based&.include?(cls)
  end

  # TC1016: an RBS `class C < S` whose S is not the program's superclass of C. A class the program does not declare,
  # a core class it only reopens, and a superclass the program does not name with certainty are not checked.
  def check_supers(ap, loaded, class_decls)
    Array(loaded.supers).each do |decl|
      next unless class_decls.key?(decl.name)

      program = program_superclass(decl.name, class_decls)
      next unless program

      declared = resolve_rbs_class(decl.super_name, decl.scope, class_decls)
      same = if class_decls.key?(program) then declared == program
             else declared.split('::').last == program.split('::').last
             end
      next if same

      note(ap, decl.loc, 'error', 'TC1016',
           "#{decl.name}: signature declares superclass #{declared}, the program's is #{program}")
    end
  end

  # The program's superclass of `klass` from its CLASS declarations (ClosedWorld#class_parent's reading): a declared
  # class's full path, an undeclared one as written, 'Object' for an implicit one, nil when it cannot be named.
  def program_superclass(klass, class_decls)
    supers = class_decls.fetch(klass).map { |d| d[:super] }.uniq
    return nil if supers.include?(nil)

    named = supers - [:none]
    if named.empty?
      # A core class the program reopens (`class Integer`) keeps the superclass mruby gave it.
      return core_class?(klass) ? nil : 'Object'
    end
    return nil unless named.one?

    return named.first if class_decls.key?(named.first)

    simple = named.first.split('::').last
    candidates = class_decls.keys.select { |c| c.split('::').last == simple }
    return named.first if candidates.empty?
    return nil unless candidates.one?

    parent = candidates.first
    parent == named.first || parent.end_with?("::#{named.first}") || named.first.end_with?("::#{parent}") ? parent : nil
  end

  def core_class?(klass)
    require_relative 'core_hierarchy_sigs'
    @core_classes ||= CoreHierarchySigs.load.first.keys.to_set
    @core_classes.include?(klass)
  rescue StandardError, LoadError
    true
  end

  # An RBS class reference resolved against the program: absolute (`::A`), else the innermost enclosing scope that
  # makes it a declared class, else as written.
  def resolve_rbs_class(name, scope, class_decls)
    return name.delete_prefix('::') if name.start_with?('::')

    scope.size.downto(0) do |i|
      candidate = (scope.first(i) + [name]).join('::')
      return candidate if class_decls.key?(candidate)
    end
    name
  end

  def note(ap, loc, severity, code, message)
    ap.diagnostics << Diag.new(file: loc.file, line: loc.line, col: loc.col, severity: severity, code: code, message: message)
  end

  def slot_hint(t, known_owners)
    case t.kind
    when :int then [:fixnum, nil, nil, nil]
    when :sym then [:symbol, nil, nil, nil]
    when :array then [:array, 'Array', t.element && known_owners.include?(t.element) ? t.element : nil, 'Array']
    when :hash then [nil, 'Hash', t.element && known_owners.include?(t.element) ? t.element : nil, 'Hash']
    when :class then [nil, (known_owners.include?(t.cls) ? t.cls : nil), nil, nil]
    else [nil, nil, nil, nil]
    end
  end

  def merge_method(ap, sig, d, annotations, class_annotations, element_annotations, known_owners)
    label = d.irep
    ann = annotations[label] || Annotations::Annotation.new(args: Array.new(sig.args.size), ret: nil)
    cann = class_annotations[label] || ClassAnnotations::Annotation.new(args: Array.new(sig.args.size))
    eann = element_annotations[label]
    arg_elements = eann ? eann.arg_elements.dup : Array.new(sig.args.size)
    arg_containers = eann ? eann.arg_containers.dup : Array.new(sig.args.size)
    element = eann&.element
    ret_class = eann&.ret_class
    ann_args = ann.args.dup
    cann_args = cann.args.dup
    ann_args.fill(nil, ann_args.size...sig.args.size)
    cann_args.fill(nil, cann_args.size...sig.args.size)
    arg_elements.fill(nil, arg_elements.size...sig.args.size)
    arg_containers.fill(nil, arg_containers.size...sig.args.size)
    ann_ret = ann.ret
    sig.args.each_with_index do |t, i|
      fix, cls, el, cont = slot_hint(t, known_owners)
      if t.kind == :class && cls.nil?
        note(ap, sig.loc, 'info', 'TC1005', "#{sig.owner}##{sig.name} parameter #{i + 1}: class #{t.cls} is not defined by the program; no hint")
      elsif t.kind == :other
        note(ap, sig.loc, 'info', 'TC1005', "#{sig.owner}##{sig.name} parameter #{i + 1}: type #{t.text} gives no hint")
      end
      norm = ->(v) { v == :array ? 'Array' : v }
      comment_has = norm.call(ann.args[i] || cann.args[i])
      if comment_has && (fix || cls) && comment_has != norm.call(fix || cls)
        note(ap, sig.loc, 'warning', 'TC1006', "#{sig.owner}##{sig.name} parameter #{i + 1}: the `# bc2cpp:` comment wins over signature type #{t.text}")
        next
      end
      ann_args[i] ||= fix unless fix == :array && el # Array[C] elements are ElementAnnotations, not a :array arg
      if t.kind == :class && cls && based?(ap, cls)
        # SUBTREE_DISPATCH: a base class is not an exact class; only the send devirtualization reads the subtree.
        (ap.subtree_args[label] ||= Array.new(sig.args.size))[i] ||= cls unless comment_has
        note(ap, sig.loc, 'info', 'TC1005', "#{sig.owner}##{sig.name} parameter #{i + 1}: class #{cls} has " \
                                            'subclasses; a subtree hint, not an exact one')
        next
      end
      cann_args[i] ||= cls if cls && (!fix || fix == :array)
      if el && based?(ap, el)
        note(ap, sig.loc, 'info', 'TC1005', "#{sig.owner}##{sig.name} parameter #{i + 1}: element class #{el} has " \
                                            'subclasses; no element hint')
        next
      end
      arg_elements[i] ||= el
      arg_containers[i] ||= cont if el
    end
    r = sig.ret
    if r
      fix, cls, el, = slot_hint(r, known_owners)
      ann_ret ||= fix
      ann_ret ||= :array if r.kind == :array
      if el && based?(ap, el)
        note(ap, sig.loc, 'info', 'TC1005', "#{sig.owner}##{sig.name} return: element class #{el} has subclasses; " \
                                            'no element hint')
      elsif r.kind == :array && el
        element ||= el
      elsif r.kind == :class && cls && !fix && based?(ap, cls)
        ap.subtree_returns[label] ||= cls unless ret_class
        note(ap, sig.loc, 'info', 'TC1005', "#{sig.owner}##{sig.name} return: class #{cls} has subclasses; a " \
                                            'subtree hint, not an exact one')
      elsif r.kind == :class && cls && !fix
        ret_class ||= cls
      elsif r.kind == :class
        note(ap, sig.loc, 'info', 'TC1005', "#{sig.owner}##{sig.name} return: class #{r.cls} is not defined by the program; no hint")
      elsif (inner = RbsOptionalHint.return_class(r, known_owners))
        ret_class ||= inner
      end
    end
    annotations[label] = Annotations::Annotation.new(args: ann_args, ret: ann_ret) if ann_args.any? || ann_ret
    class_annotations[label] = ClassAnnotations::Annotation.new(args: cann_args) if cann_args.any?
    if element || ret_class || arg_elements.any?
      element_annotations[label] = ElementAnnotations::Annotation.new(element: element, ret_class: ret_class,
                                                                      arg_elements: arg_elements, arg_containers: arg_containers)
    end
  end

  def seed_ivar(ap, iv, known_owners)
    name = iv.name.delete_prefix('@')
    t = iv.type
    case t.kind
    when :class
      if known_owners.include?(t.cls) && based?(ap, t.cls)
        ap.subtree_ivars[iv.owner][name] = t.cls
        note(ap, iv.loc, 'info', 'TC1005', "#{iv.owner}##{iv.name}: class #{t.cls} has subclasses; a subtree hint, " \
                                           'not an exact one')
      elsif known_owners.include?(t.cls)
        ap.ivar_classes[iv.owner][name] = t.cls
      else
        note(ap, iv.loc, 'info', 'TC1005', "#{iv.owner}##{iv.name}: class #{t.cls} is not defined by the program; no hint")
      end
    when :array
      ap.ivar_classes[iv.owner][name] = 'Array'
      if t.element && known_owners.include?(t.element) && !based?(ap, t.element)
        ap.ivar_elements[iv.owner][name] = t.element
      end
    when :hash
      ap.ivar_classes[iv.owner][name] = 'Hash'
      if t.element && known_owners.include?(t.element) && !based?(ap, t.element)
        ap.ivar_hash_elements[iv.owner][name] = t.element
      end
    when :int, :sym
      note(ap, iv.loc, 'info', 'TC1005',
           "#{iv.owner}##{iv.name}: #{t.text} is checked against the inference but not forced (an embedded slot needs a proof)")
    else
      # A record type is RbsRecordTypes' (ADR 0454), which checks it and reports its own diagnostics.
      return if t.text.start_with?('{')
      return if RbsOptionalHint.seed_ivar(ap, iv, name, known_owners)

      note(ap, iv.loc, 'info', 'TC1005', "#{iv.owner}##{iv.name}: type #{t.text} gives no hint")
    end
  end

  # Adds the seeds to a known-class table (ClassLayout.known shape: owner -> {ivar => class}); an inferred entry is kept.
  def seed_table(table, seeds)
    seeds.each do |owner, ivars|
      ivars.each { |name, cls| (table[owner] ||= {})[name] ||= cls }
    end
    table
  end
end
