# frozen_string_literal: true

require 'set'
require_relative 'native_sigs'
require_relative 'rbs_parse_memo'

# DECLARED_RETURN_CHECK: the RBS return declarations the compiler trusts.
#
# A return declaration `-> Integer`, `-> Array`, `-> Array[C]`, `-> C` or `-> C?` (C a class the program defines) is a
# fact about ONE definition, checked at run time by its compiled body (codegen_declared_returns.rb). This file only
# turns loaded signatures into entries (no bytecode is read here).
#
# Kinds (anything else keeps its previous role: an IR contract or a guarded seed, never a fact):
#   :fixnum   `Integer`             a Fixnum (Integer is not enough)
#   :array    `Array`, `Array[T]`   an Array; an element class stays the guarded seed it was
#   :class    `C`, `C?`             an instance of exactly C (`C?`: or nil)
#
# `%a{bc2cpp:hint}` marks a declaration whose check is always compiled, even where the return proofs prove it, and
# admits the further kinds in GUARD_ONLY_KINDS. A hinted declaration no compiled body can carry is a located TC1010
# error (hint_refusals), never an unchecked hint.
module DeclaredReturns
  Entry = Struct.new(:owner, :name, :label, :kind, :cls, :nilable, :text, :loc, :hint, keyword_init: true) do
    def key = "#{owner}##{name}"
  end

  KILL_ENV = 'BC2CPP_DECLARED_RETURNS'
  # `%a{bc2cpp:hint} def m: ...`: a reviewed return type the static checker cannot prove. The compiled body checks
  # every value it returns against it (DECLARED_RETURN_GUARD) and raises on a mismatch, so it is a fact for the
  # analysis and the other checkers, exactly as a statically checked declaration is.
  HINT_ANNOTATION = 'bc2cpp:hint'
  # The C++ marker on each guard, and the listing line of each guarded method.
  GUARD_MARKER = %r{/\* DECLARED_RETURN_GUARD (\S+ -> \S+) \*/}
  CODE = 'TC1010'

  module_function

  def enabled?
    ENV[KILL_ENV] != '0'
  end

  # A plain declaration is trusted as written, so its compiled body checks it at run time (BC2CPP_DECLARATION_GUARD=0
  # drops that check; %a{bc2cpp:hint} declarations keep theirs).
  def guard?
    ENV['BC2CPP_DECLARATION_GUARD'] != '0'
  end

  # [kind, class, nilable] for an RBS return type, or nil when the type is not a checked kind.
  def kind_of(type, known_owners)
    nilable = false
    if defined?(RBS::Types::Optional) && type.is_a?(RBS::Types::Optional)
      nilable = true
      type = type.type
    end
    if defined?(RBS::Types::Union) && type.is_a?(RBS::Types::Union)
      # UNION_LINEAR: each member is a checkable kind; the guard is the members' tests joined by `||`, one linear
      # test per member, so a union is only admitted when it is short (UNION_MAX members, none a union itself).
      return nil if nilable || type.types.size < 2 || type.types.size > UNION_MAX
      members = type.types.map { |t| kind_of(t, known_owners) }
      return nil if members.any? { |m| m.nil? || m[0] == :union }

      return [:union, members, false]
    end
    # A declared `bool` is not a checked kind: callers rely on truthiness, so it is never guarded (see RbsSignatures).
    # `bool` is checked as exactly true or false: the guard is `true || false`, with `nil` first when nilable.
    if defined?(RBS::Types::Bases::Bool) && type.is_a?(RBS::Types::Bases::Bool)
      return [:bool, nil, nilable]
    end
    if defined?(RBS::Types::Bases::Nil) && type.is_a?(RBS::Types::Bases::Nil)
      return nilable ? nil : [:nil, nil, false]
    end
    return nil unless defined?(RBS::Types::ClassInstance) && type.is_a?(RBS::Types::ClassInstance)

    name = type.name.to_s.delete_prefix('::')
    case name
    # A nilable simple kind (`Integer?`) admits nil as well as the class: the guard is `nil || test`.
    when 'Integer' then type.args.empty? ? [:fixnum, 'Integer', nilable] : nil
    # The element type is not checked (as before): an Array[T] return is the array kind.
    when 'Array'
      elem = type.args.size == 1 ? kind_of(type.args[0], known_owners) : nil
      if elem && ELEMENT_CHECKED_KINDS.include?(elem[0]) && !elem[2]
        [:array_of, elem, nilable]
      else
        [:array, 'Array', nilable]
      end
    when 'String' then type.args.empty? ? [:string, 'String', nilable] : nil
    when 'Hash'
      if type.args.empty?
        [:hash, 'Hash', nilable]
      elsif type.args.size == 2
        kk = kind_of(type.args[0], known_owners)
        vk = kind_of(type.args[1], known_owners)
        ok = kk && vk && ELEMENT_CHECKED_KINDS.include?(kk[0]) && ELEMENT_CHECKED_KINDS.include?(vk[0]) && !kk[2] && !vk[2]
        ok ? [:hash_of, [kk, vk], nilable] : nil
      end
    when 'Symbol' then type.args.empty? ? [:symbol, 'Symbol', nilable] : nil
    when 'Float' then type.args.empty? ? [:float, 'Float', nilable] : nil
    when 'Enumerable' then type.args.size <= 1 ? [:module, 'Enumerable', nilable] : nil
    else
      return nil unless type.args.empty?
      # A native class is checked by its class pointer like a program class; the constant is resolved at run time.
      known_owners.include?(name) || NATIVE_CHECKED_CLASSES.include?(name) ? [:class, name, nilable] : nil
    end
  end

  # Native classes a runtime-checked declaration may name (their class pointer is read at run time, as for a
  # program class). Other native names stay refused: a module, or a class with subclasses the exact test would miss.
  NATIVE_CHECKED_CLASSES = %w[RGSS::Rect RGSS::Color RGSS::Tone RGSS::Bitmap RGSS::Font Range Proc].freeze

  # The kinds that only a runtime-checked declaration (%a{bc2cpp:hint}) may take: no proof analysis reads them, so
  # the compiled body's guard is their whole check (codegen_declared_returns.rb). A native class is one too.
  # A module (Enumerable) is a kind-of test, since no exact class test matches its includers.
  GUARD_ONLY_KINDS = %i[nil string hash symbol float module union bool array_of hash_of].freeze
  # An element kind an Array[T] return checks element by element (a class element is not checked: see kind_of).
  ELEMENT_CHECKED_KINDS = %i[fixnum float string symbol bool].freeze
  UNION_MAX = 4

  # Entries for the loaded method signatures that name a bytecode definition with the signature's required arity
  # (RbsSignatures.apply reports the others). `ireps` is only read for that arity.
  def from_signatures(loaded, ireps, registry)
    return [] unless loaded && enabled?

    known_owners = registry.values.flatten.map(&:owner).to_set
    hinted = hinted_methods(loaded.files)
    defs_by = {}
    registry.each_value { |defs| defs.each { |d| defs_by[[d.owner, d.name.to_s]] = d if d.irep } }
    loaded.methods.each_value.filter_map do |sig|
      sig = sig.program if sig.loc.native && sig.program
      next if sig.loc.native

      d = defs_by[[sig.owner, sig.name]]
      next unless d && sig.return_type

      irep = ireps[d.irep]
      next unless irep

      mand = irep.enter ? irep.enter.enter_fields.first.to_i : 0
      next unless sig.args.size == mand

      kind, cls, nilable = kind_of(sig.return_type, known_owners)
      next unless kind
      guard_only = GUARD_ONLY_KINDS.include?(kind) || (kind == :class && !known_owners.include?(cls))
      next if guard_only && !hinted.include?([sig.owner, sig.name])

      Entry.new(owner: sig.owner, name: sig.name, label: d.irep, kind: kind, cls: cls, nilable: nilable,
                text: sig.return_type.to_s, loc: sig.loc, hint: hinted.include?([sig.owner, sig.name]))
    end
  end

  # Why each %a{bc2cpp:hint} declaration that from_signatures turns into no entry cannot be runtime-checked:
  # [{key:, text:, loc:, why:}]. Each is a TC1010 error: the declaration is not a fact and nothing checks it.
  # A hinted declaration needs a bytecode body the build compiles (not a native, an accessor or an undefined
  # method; no native fact proves a program return), the body's mandatory arity, and a checked kind.
  def hint_refusals(loaded, ireps, registry)
    return [] unless loaded && enabled?

    hinted = hinted_methods(loaded.files)
    return [] if hinted.empty?

    entered = from_signatures(loaded, ireps, registry).to_set { |e| [e.owner, e.name] }
    defs_by = {}
    registry.each_value { |defs| defs.each { |d| (defs_by[[d.owner, d.name.to_s]] ||= []) << d } }
    loaded.methods.each_value.filter_map do |sig|
      key = [sig.owner, sig.name]
      next unless hinted.include?(key) && !entered.include?(key)

      d = defs_by[key]&.find(&:irep)
      irep = d && ireps[d.irep]
      mand = irep&.enter ? irep.enter.enter_fields.first.to_i : 0
      why = if sig.loc.native then 'a native signature: no compiled body carries the check'
            elsif defs_by[key].nil? then 'the program defines no such method, so no compiled body carries the check'
            elsif d.nil? || irep.nil?
              'a native or accessor method: no compiled body carries the check, and no native fact proves it'
            elsif sig.return_type.nil? then 'no return type'
            elsif sig.args.size != mand
              "declares #{sig.args.size} required parameter(s), the body takes #{mand}"
            else
              "-> #{sig.return_type} is no checked kind (Integer, Array, String, Hash, Symbol, Float, nil, C or C? of a program or listed native class)"
            end
      { key: "#{sig.owner}##{sig.name}", text: sig.return_type.to_s, loc: sig.loc, why: why }
    end
  end

  # [owner, name] of the method declarations annotated %a{bc2cpp:hint} (owners as RbsSignatures keys them).
  def hinted_methods(files)
    require 'pathname'
    require 'rbs'
    out = Set.new
    walk = lambda do |decls, scope|
      decls.each do |decl|
        next unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

        name = (scope + [decl.name.to_s.delete_prefix('::')]).join('::')
        next if RbsSignatures.absent_classes.include?(name)

        decl.members.each do |m|
          next unless m.is_a?(RBS::AST::Members::MethodDefinition)
          next unless m.annotations.any? { |a| a.string.strip == HINT_ANNOTATION }

          out << [m.kind == :instance ? name : "#{name}.singleton", m.name.to_s]
        end
        walk.call(decl.members.grep(RBS::AST::Declarations::Base), [name])
      end
    end
    Array(files).each do |file|
      decls = RbsParseMemo.decls(file, File.read(file))
      walk.call(decls, [])
    rescue RBS::ParsingError
      next # RbsSignatures.load reports it (TC1002)
    end
    out
  end

  # The C++ marker of one guard: names the method and the declared type, so a listing can count and review it.
  def guard_marker(entry)
    "/* DECLARED_RETURN_GUARD #{entry.key} -> #{entry.text} */"
  end

  # "Owner#name -> T" of every guard in this run's compiled code, one per check site.
  def guard_sites(compiled)
    compiled.flat_map { |m| m[:code].to_s.scan(GUARD_MARKER).flatten }
  end

  # Why this run breaks the guard contract (empty when it does not), after compile_all and before SKIP_UNSUPPORTED
  # drops a body. The analysis trusted every runtime-checked declaration (`hints`) as a fact, which is sound only if
  # the body that answers the name is the compiled one carrying the guard. So each one whose owner this run compiles
  # must come out compiled, free of `#error` (which would leave it interpreted and unchecked), with its guard; one
  # whose owner no compiled gem of the build compiles cannot be checked at all. `only_owners` / `other_owners`:
  # this run's ONLY_OWNERS and OTHER_OWNERS (nil: a run that compiles every owner).
  def guard_failures(hints, compiled, only_owners, other_owners)
    by_label = compiled.each_with_object({}) { |m, h| h[m[:label]] ||= m if m[:label] }
    hints.filter_map do |e|
      where = "#{e.loc.file}:#{e.loc.line}:#{e.loc.col}: error: #{e.key} -> #{e.text} is runtime-checked " \
              '(%a{bc2cpp:hint}) in its compiled body, but'
      if only_owners && !only_owners.include?(e.owner)
        next if other_owners&.include?(e.owner)

        next "#{where} no compiled gem of this build compiles #{e.owner} [#{CODE}]"
      end
      m = by_label[e.label]
      next "#{where} this run does not compile it [#{CODE}]" unless m
      if m[:unsupported] || m[:code].include?('#error')
        next "#{where} its body does not compile, so it would run interpreted and unchecked [#{CODE}]"
      end
      next "#{where} the compiled body carries no guard [#{CODE}]" unless m[:code].include?(guard_marker(e))
    end
  end

  # DECLARED_OPTIONAL_PARAM: why this run breaks the optional parameter guard contract (empty when it does not). The
  # class pool seeds an optional declaration (CodeGen#setup_class_pools) for the body that checks it on entry, so each
  # body this run compiles cleanly must carry every one of its optional guards. A body that does not compile runs
  # interpreted and trusts nothing. `params`: CodeGen.declared_params.
  def optional_param_guard_failures(params, compiled)
    by_label = compiled.group_by { |m| m[:label] }
    (params || {}).flat_map do |label, guards|
      bodies = Array(by_label[label]).reject { |m| m[:unsupported] || m[:code].to_s.include?('#error') }
      guards.filter_map do |pos, _cls, key, text, _kind, _nilable, optional|
        next unless optional

        marker = "/* DECLARED_PARAM_GUARD #{key} arg #{pos + 1} */"
        next if bodies.all? { |m| m[:code].include?(marker) }

        "#{key} parameter #{pos + 1} (#{text}) is seeded from its declaration, but a compiled body carries no guard [#{CODE}]"
      end
    end
  end

  # TRACED_PARAM: why this run breaks the traced parameter contract (empty when it does not). An installed record
  # trace read a declared parameter as its declared classes (ValueTrace#entry_classes, #keyword_classes), which holds
  # only while that method runs compiled with the guard, so it must compile, cleanly, with the guard in every body. A
  # positional the impl takes unboxed (`mrb_int id`) is checked by its callers instead. `trusted`: [label, :arg,
  # position] / [label, :keyword, name]; `keys`: label => "Owner#name". A method another gem's run compiles
  # (other_owners) is that run's to check.
  def traced_param_failures(trusted, compiled, keys, only_owners, other_owners)
    by_label = compiled.group_by { |m| m[:label] }
    (trusted || []).filter_map do |label, form, which|
      key = keys[label] || label
      what = form == :arg ? "parameter #{which + 1}" : "keyword #{which}:"
      owner = key.to_s.split('#').first.delete_suffix('.singleton')
      if only_owners && !only_owners.include?(owner)
        next if other_owners&.include?(owner)

        next "#{key} #{what} is traced from its declaration, but no compiled gem of this build compiles #{owner} [#{CODE}]"
      end
      bodies = Array(by_label[label])
      if bodies.empty? || bodies.any? { |m| m[:unsupported] || m[:code].to_s.include?('#error') }
        next "#{key} #{what} is traced from its declaration, but the method does not compile [#{CODE}]"
      end

      marker = form == :arg ? "/* DECLARED_PARAM_GUARD #{key} arg #{which + 1} */" : keyword_guard_marker(key, which)
      next if bodies.all? { |m| m[:code].include?(marker) || (form == :arg && unboxed_param?(m[:code], which)) }

      "#{key} #{what} is traced from its declaration, but a compiled body carries no guard [#{CODE}]"
    end
  end

  # Aborts the run on a traced_param_failures failure of the record trace's trusted guards (a method of its own, so
  # bc2cpp.rb's top level, which mrbc compiles, keeps its local count).
  def check_traced_params!(compiled, only_owners, other_owners)
    return unless defined?(RbsRecordTypes) && defined?(CodeGen)

    keys = (CodeGen.declared_params || {}).merge(CodeGen.declared_keywords || {}).transform_values { |guards| guards.first&.[](2) }
    failures = traced_param_failures(RbsRecordTypes.trusted_params, compiled, keys, only_owners, other_owners)
    return if failures.empty?

    abort "\n[bc2cpp] TRACED_PARAM: #{failures.size} parameter declaration(s) a record trace trusted without their " \
          "compiled check:\n  #{failures.join("\n  ")}"
  end

  # The body's first `_impl(` definition takes positional `position` as a C scalar, not an mrb_value.
  def unboxed_param?(code, position)
    params = code[/^(?:static inline )?mrb_value \w+_impl(?:_unguarded)?\(([^)]*)\) \{$/, 1]
    type = params&.split(',')&.[](2 + position)&.strip&.sub(/\s*\w+\z/, '')
    !type.nil? && type != 'mrb_value'
  end

  def keyword_guard_marker(key, name)
    "/* DECLARED_KEYWORD_GUARD #{key} #{name}: */"
  end

  # DECLARED_KEYWORD_PARAM: why this run breaks the keyword guard contract (empty when it does not). The flow types a
  # declared keyword's KARG result (CodeGen#declared_keyword_mask) for the body that checks it there, so each body this
  # run compiles cleanly must carry every one of its keyword guards. `guards`: label => CodeGen#declared_keyword_guards.
  def keyword_guard_failures(guards, compiled)
    by_label = compiled.group_by { |m| m[:label] }
    guards.flat_map do |label, by_name|
      bodies = Array(by_label[label]).reject { |m| m[:unsupported] || m[:code].to_s.include?('#error') }
      by_name.filter_map do |name, (_name, _cls, key, text)|
        next if bodies.all? { |m| m[:code].include?(keyword_guard_marker(key, name)) }

        "#{key} keyword #{text} is typed from its declaration, but a compiled body carries no guard [#{CODE}]"
      end
    end
  end

  # Prints the outcome of CodeGen#check_declared_returns, adds its diagnostics to the signature diagnostics (the type
  # check reads them from there) and aborts a build on an error.
  def report(gen, sig_applied, abort_on_error:)
    # The class return fixpoint had no listing; one line per name, like RET / ARET, so a build can count it.
    warn "== methods proven to return one class (RETCLASS_SELF_CALL_SUPPORT): #{gen.class_return_names.size} =="
    gen.class_return_names.sort.each { |name, klass| warn "  CLASSRET #{name} (#{klass})" }
    entries = gen.declared_return_report
    return if entries.empty?

    diags = gen.declared_return_diagnostics
    warn "== declared returns checked against every return path (DECLARED_RETURN_CHECK, ADR 0455): #{entries.size} =="
    entries.each { |line| warn line }
    diags.each { |d| warn "  #{d[:file]}:#{d[:line]}:#{d[:col]}: #{d[:severity]}: #{d[:message]} [#{d[:code]}]" }
    sig_applied&.diagnostics&.concat(diags.map { |d| RbsSignatures::Diag.new(**d) })
    # A return declaration that does not hold is not trusted (its return stays any): reported, not fatal.
    errors = diags.count { |d| d[:severity] == 'error' }
    warn "[bc2cpp] DECLARED_RETURN_CHECK: #{errors} return path(s) do not prove their declaration; kept untrusted" if errors.positive?
  end
end
