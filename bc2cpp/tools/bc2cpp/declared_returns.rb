# frozen_string_literal: true

require 'set'

# DECLARED_RETURN_CHECK (docs/adr/0455): the RBS return declarations a body is checked against.
#
# A return declaration `-> Integer`, `-> Array`, `-> Array[C]`, `-> C` or `-> C?` (C a class the program defines) is a
# claim about every return path of ONE definition. CodeGen#check_declared_returns (codegen_declared_returns.rb) verifies
# each path with the tracing the return proofs use; a declaration that passes adds the fact the fixpoint proofs
# produce (FIXNUM_RETURN_PROOF, ARRAY_RETURN_PROOF, the class return fixpoint), and one that fails is a TC1010 error and
# a build abort. This file only turns loaded signatures into entries (no bytecode is read here).
#
# Kinds (anything else keeps its previous role: an IR contract or a guarded seed, never a proof fact):
#   :fixnum   `Integer`             every path is a proven Fixnum (the proof is Fixnum-exact; Integer is not enough)
#   :array    `Array`, `Array[T]`   every path is an Array; an element class stays the guarded seed it was
#   :class    `C`, `C?`             every path is an instance of exactly C (`C?`: or nil)
module DeclaredReturns
  Entry = Struct.new(:owner, :name, :label, :kind, :cls, :nilable, :text, :loc, :hint, keyword_init: true) do
    def key = "#{owner}##{name}"
  end

  KILL_ENV = 'BC2CPP_DECLARED_RETURNS'
  # `%a{bc2cpp:hint} def m: ...`: a reviewed return type the checker cannot prove. It keeps the role every return
  # declaration had before ADR 0455 (a guarded seed: annotated_array_return, the element and `-> C` tables, an IR
  # contract), is listed as unchecked, and never joins a proof's facts.
  HINT_ANNOTATION = 'bc2cpp:hint'
  CODE = 'TC1010'

  module_function

  def enabled?
    ENV[KILL_ENV] != '0'
  end

  # [kind, class, nilable] for an RBS return type, or nil when the type is not a checked kind.
  def kind_of(type, known_owners)
    nilable = false
    if defined?(RBS::Types::Optional) && type.is_a?(RBS::Types::Optional)
      nilable = true
      type = type.type
    end
    return nil unless defined?(RBS::Types::ClassInstance) && type.is_a?(RBS::Types::ClassInstance)

    name = type.name.to_s.delete_prefix('::')
    case name
    when 'Integer' then nilable || !type.args.empty? ? nil : [:fixnum, 'Integer', false]
    when 'Array' then nilable ? nil : [:array, 'Array', false]
    else
      type.args.empty? && known_owners.include?(name) ? [:class, name, nilable] : nil
    end
  end

  # Entries for the loaded method signatures that name a bytecode definition with the signature's required arity
  # (RbsSignatures.apply reports the others). `ireps` is only read for that arity.
  def from_signatures(loaded, ireps, registry)
    return [] unless loaded && enabled?

    known_owners = registry.values.flatten.map(&:owner).to_set
    hinted = hinted_methods(loaded.files)
    defs_by = {}
    registry.each_value { |defs| defs.each { |d| defs_by[[d.owner, d.name.to_s]] = d if d.irep } }
    loaded.methods.each_value.filter_map do |sig|
      next if sig.loc.file.include?('sig/native/')

      d = defs_by[[sig.owner, sig.name]]
      next unless d && sig.return_type

      irep = ireps[d.irep]
      next unless irep

      mand = irep.enter ? irep.enter.enter_fields.first.to_i : 0
      next unless sig.args.size == mand

      kind, cls, nilable = kind_of(sig.return_type, known_owners)
      next unless kind

      Entry.new(owner: sig.owner, name: sig.name, label: d.irep, kind: kind, cls: cls, nilable: nilable,
                text: sig.return_type.to_s, loc: sig.loc, hint: hinted.include?([sig.owner, sig.name]))
    end
  end

  # [owner, name] of the method declarations annotated %a{bc2cpp:hint} (owners as RbsSignatures keys them).
  def hinted_methods(files)
    require 'rbs'
    out = Set.new
    walk = lambda do |decls, scope|
      decls.each do |decl|
        next unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

        name = (scope + [decl.name.to_s.delete_prefix('::')]).join('::')
        decl.members.each do |m|
          next unless m.is_a?(RBS::AST::Members::MethodDefinition)
          next unless m.annotations.any? { |a| a.string.strip == HINT_ANNOTATION }

          out << [m.kind == :instance ? name : "#{name}.singleton", m.name.to_s]
        end
        walk.call(decl.members.grep(RBS::AST::Declarations::Base), [name])
      end
    end
    Array(files).each do |file|
      _buf, _dirs, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: file, content: File.read(file)))
      walk.call(decls, [])
    rescue RBS::ParsingError
      next # RbsSignatures.load reports it (TC1002)
    end
    out
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
    errors = diags.count { |d| d[:severity] == 'error' }
    return unless errors.positive? && abort_on_error

    abort "\n[bc2cpp] DECLARED_RETURN_CHECK: #{errors} return path(s) do not prove their declaration (see above). " \
          'Fix the declaration, or the code it claims to describe.'
  end
end
