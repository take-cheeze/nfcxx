# frozen_string_literal: true

require 'prism'
require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'bytecode_ir_containers'
require_relative 'call_site_index'
require_relative 'dynamic_names'
require_relative 'native_names'
require_relative 'closed_world'
require_relative 'nil_narrowing'
require_relative 'scan_cache'

# RBS only: a class parameter type in an RBS signature is trusted as written, not proven against its callers. Each
# declared parameter is a ClassAnnotations fact for the method's own body, and no caller is checked. A caller that
# passes another class is therefore not reported; the compiled body relies on the declaration.
module RbsParamCheck
  # IS_A_GUARD's two closed-world answers for NilNarrowing (CodeGen#is_a_guard_class, #raise_never_returns?).
  IsAGuard = Struct.new(:gen) do
    def is_a_class(irep, idx) = gen.is_a_guard_class(irep, idx)
    def raise_never_returns?(irep, idx) = gen.raise_never_returns?(irep, idx)
  end

  module_function

  # loaded: RbsSignatures.load's result; class_annotations: the merged table RbsSignatures.apply filled;
  # comment_class_args: label -> args the `# bc2cpp:` comments gave (they win and are not checked here).
  # Returns [diagnostics, verified] where verified is a Set of [label, position].
  # outside_names: outside_call_names' result (nil: no outside scan, every declaration is refused);
  # constructor_entries: a CodeGen built with `analysis_only: :constructor_sites` (constructor_entry_sites,
  # constructor_init_target); nil refuses every initialize declaration.
  # declared_returns: DeclaredReturns.from_signatures' entries (CodeGen.declared_returns). Each proves a call's
  # result: DECLARED_RETURN_CHECK aborts the build on a body that does not prove its declaration, and a
  # %a{bc2cpp:hint} one is checked on every return by its compiled body (DECLARED_RETURN_GUARD), which raises
  # instead of returning another type.
  def check(loaded, ireps, registry, class_annotations, comment_class_args:, call_sites:, outside_names:,
            superclass_of:, display_root: nil, applied: nil, constructor_entries: nil, declared_returns: nil)
    ctx = context(loaded, ireps, registry, superclass_of)
    ctx.merge!(ivar_cache: {}, ivar_active: Set.new, nil_cache: {},
               declared: (declared_returns || []).to_h { |e| [e.label, e] },
               nil_unanswerable: ->(name) { constructor_entries.nil_unanswerable?(name) },
               class_guard: IsAGuard.new(constructor_entries))
    ctx.merge!(outside: outside_names, display_root: display_root, call_sites: call_sites, applied: applied,
               class_annotations: class_annotations, comment_class_args: comment_class_args,
               constructor_entries: constructor_entries)
    # RBS only: every declared parameter class is trusted as written, so no caller is proven against it.
    trusted = targets(ctx).flat_map { |_sig, d, positions| positions.map { |pos, _cls| [d.irep, pos] } }.to_set
    [[], trusted]
  end

  # The tables every query reads: method owners (`self_of` only for def bodies, never blocks, whose self an
  # instance_exec may change; `owner_of` also for blocks, for lexical constant lookup) and the signature of each body.
  def context(loaded, ireps, registry, superclass_of)
    ctx = { ireps: ireps, registry: registry, subclassed: superclass_of.values.grep(String).to_set,
            dynamic: DynamicNames.universe(ireps), self_of: {}, method_name: {}, owner_of: {}, sig_of: {}, def_of: {},
            aliased: alias_names(ireps), parent: {} }
    defs_by = {}
    registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep

        ctx[:self_of][d.irep] = d.owner
        ctx[:method_name][d.irep] = d.name
        defs_by[[d.owner, d.name.to_s]] = d
      end
    end
    ctx[:owner_of].merge!(ctx[:self_of])
    parent = ctx[:parent]
    ireps.each_value { |irep| (irep.reps || []).each { |child| parent[child] = irep.label } }
    ireps.each_key do |label|
      up = label
      up = parent[up] until up.nil? || ctx[:self_of].key?(up)
      ctx[:owner_of][label] ||= ctx[:self_of][up] if up
    end
    loaded.methods.each_value do |sig|
      d = defs_by[[sig.owner, sig.name]]
      next unless d
      ctx[:sig_of][d.irep] = sig
      ctx[:def_of][d.irep] = d
    end
    ctx
  end

  # Both names of every `alias new old` (an ALIAS instruction; `alias_method` spells Symbols, DynamicNames).
  def alias_names(ireps)
    ireps.each_value.with_object(Set.new) do |irep, names|
      irep.each_with_op(:ALIAS) do |insn, _index|
        names << insn.sym if insn.sym
        old = insn.first_of(:name)&.value
        names << old if old
      end
    end
  end

  # [sig, def, [[position, class], ...]] for every signature whose class parameter reached ClassAnnotations.
  def targets(ctx)
    out = []
    ctx[:sig_of].each do |label, sig|
      d = ctx[:def_of][label]
      ann = ctx[:class_annotations][label]
      positions = sig.args.each_with_index.filter_map do |type, i|
        next unless type.kind == :class && ann && ann.args[i] == type.cls
        next if ctx[:comment_class_args][label]&.[](i)

        [i, type.cls]
      end
      out << [sig, d, positions] unless positions.empty?
    end
    out
  end

  # Every name code outside the analysed bytecode can call a Ruby method by: in a native source (comments dropped),
  # a string literal (`"name"`, mrb_intern_lit), an MRB_SYM-family token, or a hook the VM calls implicitly; in a
  # foreign Ruby source the closed world does not compile, any identifier. A C identifier that merely shares the
  # name (a local variable `range`) is not one: a native names a method only through a Symbol.
  def outside_call_names(native_paths, foreign_ruby_paths, compiled_files)
    names = Set.new(ClosedWorld::IMPLICIT_HOOKS)
    Array(native_paths).each do |path|
      text = File.binread(path).gsub(%r{"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|/\*.*?\*/|//[^\n]*}m) do |tok|
        tok.start_with?('/') ? ' ' : tok
      end
      text.scan(ClosedWorld::C_STRING) { |(lit)| names << lit }
      text.scan(MRB_SYM_TOKEN_RE) { |m, n| names << resolve_mrb_sym_token(m, n) }
    end
    Array(foreign_ruby_paths).each do |path|
      next if compiled_files.include?(path) || compiled_files.include?(File.expand_path(path))

      foreign_ruby_file_names(path).each { |t| names << t << ClosedWorld.token_stem(t) }
    end
    names
  end

  # foreign_ruby_names of one file, distinct and in first-seen order, kept in the scan cache under the file's digest (and
  # the Prism version that lexed it) so a warm run does not lex it. Dropping a repeat keeps the Set above in the same
  # order: the first insert already put the name and its stem there.
  def foreign_ruby_file_names(path)
    ScanCache.fetch("rbs_param_check.foreign_ruby_names.prism#{Prism::VERSION}", [path], cache_absent: false) do
      foreign_ruby_names(File.binread(path)).uniq
    end
  end

  # The words of a foreign Ruby source that can name a method: every code token, and a string or symbol whose whole
  # content is a name (what a computed send could pass on unchanged). Comments and the words inside prose strings
  # are not; `"an exclusive range"` names nothing a send can reach without composing it, which DynamicNames
  # already treats as computed. A source Prism cannot lex cleanly is read bluntly, every word a name.
  def foreign_ruby_names(text)
    blunt = -> { text.scan(/[A-Za-z_]\w*[?!=]?/) }
    lexed = Prism.lex(text.dup.force_encoding(Encoding::UTF_8))
    return blunt.call unless lexed.errors.empty?

    lexed.value.filter_map do |token, _state|
      value = token.value
      case token.type
      when :COMMENT, :EMBDOC_BEGIN, :EMBDOC_LINE, :EMBDOC_END, :__END__ then nil
      when :STRING_CONTENT then value if value.match?(/\A[A-Za-z_]\w*[?!=]?\z/)
      else value[/\A[A-Za-z_]\w*[?!=]?\z/]
      end
    end
  rescue ArgumentError, EncodingError
    blunt.call
  end

end
