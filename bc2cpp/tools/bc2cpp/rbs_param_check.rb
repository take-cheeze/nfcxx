# frozen_string_literal: true

require 'prism'
require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'irep_arity'
require_relative 'call_site_index'
require_relative 'dynamic_names'
require_relative 'native_names'
require_relative 'closed_world'
require_relative 'nil_narrowing'
require_relative 'scan_cache'

# RBS only: a class parameter type in an RBS signature is trusted as written, not proven against its callers. Each
# declared parameter is a ClassAnnotations fact for the method's own body; the compiled body checks it on entry
# (DECLARED_PARAM_GUARD) and raises BC2cppDeclarationViolation for another class.
module RbsParamCheck
  # VALUE_KIND: the value kinds a parameter declaration can name besides a program class, and the class each stands for.
  VALUE_CLASSES = { float: 'Float', integer: 'Integer', symbol: 'Symbol' }.freeze

  # IS_A_GUARD's two closed-world answers for NilNarrowing (CodeGen#is_a_guard_class, #raise_never_returns?).
  IsAGuard = Struct.new(:gen) do
    def is_a_class(irep, idx) = gen.is_a_guard_class(irep, idx)
    def raise_never_returns?(irep, idx) = gen.raise_never_returns?(irep, idx)
  end

  module_function

  # loaded: RbsSignatures.load's result; class_annotations: the merged table RbsSignatures.apply filled;
  # comment_class_args: label -> args the `# bc2cpp:` comments gave (they win and are not checked here).
  # Returns [diagnostics, trusted, guards]: trusted is a Set of [label, position], guards the entry checks of those.
  # outside_names: outside_call_names' result (nil: no outside scan, every declaration is refused);
  # constructor_entries: a CodeGen built with `analysis_only: :constructor_sites` (constructor_entry_sites,
  # constructor_init_target); nil refuses every initialize declaration.
  # declared_returns: DeclaredReturns.from_signatures' entries (CodeGen.declared_returns), each checked on every
  # return by its compiled body (DECLARED_RETURN_GUARD).
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
    # RBS only: every declared parameter class is trusted as written, so no caller is proven against it. The compiled
    # body checks it at entry instead (DECLARED_PARAM_GUARD): guards is label => [[position, class, key, text], ...].
    found = targets(ctx)
    diags = optional_notes(ctx, found)
    trusted = found.flat_map { |_sig, d, positions| positions.map { |pos, *| [d.irep, pos] } }.to_set
    guards = found.to_h do |sig, d, positions|
      [d.irep, positions.map do |pos, cls, kind, nilable, optional|
        text = optional ? sig.optional_args[optional].text : sig.args[pos].text
        [pos, cls, "#{sig.owner}##{sig.name}", text, kind, nilable, optional]
      end]
    end
    [diags, trusted, guards]
  end

  # DECLARED_KEYWORD_PARAM: label => [[name, class, key, text, kind, nilable], ...] for the keyword parameters a
  # signature types with a guardable kind (as for a positional `T?`: a value kind, Array/Hash/String, or a program class
  # nothing subclasses). Only bodies whose KEY_P/KARG table is exactly the declared keywords (no `**rest`) qualify. The
  # compiled KARG checks the given value (CodeGen#declared_keyword_guard), and only KARG's result is typed: an
  # omitted keyword's default is ordinary code the flow reads.
  def keyword_guards(loaded, ireps, registry, superclass_of, comment_class_args: {})
    ctx = context(loaded, ireps, registry, superclass_of)
    ctx[:sig_of].each_with_object({}) do |(label, sig), out|
      next if (sig.keywords || {}).empty? || comment_class_args[label]

      table = ireps[label] && keyword_arg_table(ireps[label], rest_block: true)
      next unless table && table.to_h { |kw| [kw[:name], kw[:required]] } ==
                           sig.keywords.keys.to_h { |name| [name, sig.required_keywords.include?(name)] }

      guards = sig.keywords.filter_map do |name, type|
        inner = type.optional
        t = inner || type
        kind, cls = if VALUE_CLASSES.key?(t.value) then [t.value, VALUE_CLASSES[t.value]]
                    elsif (core = core_kind(t)) then [core, CORE_IVAR_KINDS.fetch(core)]
                    elsif t.kind == :class && ctx[:classes].include?(t.cls) && !ctx[:subclassed].include?(t.cls)
                      [:class, t.cls]
                    end
        [name, cls, "#{sig.owner}##{sig.name}", "#{name}: #{type.text}", kind, !inner.nil?] if kind
      end
      out[label] = guards unless guards.empty?
    end
  end

  # TC1005 info for each typed optional parameter optional_targets does not guard (and so gives no hint).
  def optional_notes(ctx, found)
    guarded = found.to_h { |_sig, d, positions| [d.irep, positions.map(&:first).to_set] }
    ctx[:sig_of].flat_map do |label, sig|
      mand = sig.args.size
      Array(sig.optional_args).each_with_index.filter_map do |type, k|
        next if type.value_classes.nil? || guarded[label]&.include?(mand + k) || ctx[:comment_class_args][label]&.[](mand + k)

        RbsSignatures::Diag.new(file: sig.loc.file, line: sig.loc.line, col: sig.loc.col, severity: 'info', code: 'TC1005',
                                message: "#{sig.owner}##{sig.name} parameter #{mand + k + 1}: optional #{type.text} gives " \
                                         'no hint (a guardable kind with a literal default of that kind is needed)')
      end
    end
  end

  # DECLARED_IVAR_GUARD: one `@x: T` declaration the compiled stores check. kind is :float, :integer, :symbol, :class
  # (the exact program class cls) or :array, :hash, :string (CORE_IVAR_KINDS: the core class cls, kept only in a build
  # with no subclass of it, see CodeGen#declared_ivar_entry); nilable admits nil too (`T?`).
  IvarGuard = Struct.new(:owner, :name, :cls, :kind, :nilable, :key, :text)
  CORE_IVAR_KINDS = { array: 'Array', hash: 'Hash', string: 'String' }.freeze

  # { [owner, name without @] => IvarGuard } of the instance-variable declarations (`@x: T`, `attr_reader x: T`) of a
  # program class whose type is Integer, Float, Symbol, an exact program class or a native class (native_ivar_kind), or
  # the same with `?`. A program class with a subclass is left out (the guard is the exact-class test, and a subclass
  # instance is a legal value), like a nilable class parameter; `bool` stays unchecked by design, as for parameters and
  # returns.
  def ivar_guards(loaded, superclass_of, closed_world: nil)
    classes = superclass_of.keys.to_set
    subclassed = superclass_of.values.grep(String).to_set
    loaded.ivars.each_value.with_object({}) do |iv, out|
      next if iv.owner.end_with?('.singleton') || !classes.include?(iv.owner)

      inner = iv.type.optional
      t = inner || iv.type
      nilable = !inner.nil?
      kind = VALUE_CLASSES.key?(t.value) ? t.value : nil
      cls = kind ? VALUE_CLASSES[kind] : t.cls
      # An element type is not checked: `Array[T]` is the Array kind.
      core = t.kind == :class && t.cls == 'String' ? :string : CORE_IVAR_KINDS.key?(t.kind) && t.kind
      kind, cls = core, CORE_IVAR_KINDS.fetch(core) if !kind && core
      unless kind
        native = native_ivar_kind(t, closed_world)
        next if native == :refused

        kind, cls = native if native
      end
      unless kind
        union = union_classes(iv.type, classes, superclass_of)
        if union && union.first.size > 1
          cls, nilable = union
          kind = :union
        else
          next unless t.kind == :class && classes.include?(t.cls) && !subclassed.include?(t.cls)

          kind = :class
        end
      end
      name = iv.name.delete_prefix('@')
      out[[iv.owner, name]] = IvarGuard.new(iv.owner, name, cls, kind, nilable, "#{iv.owner}##{iv.name}", iv.type.text)
    end
  end

  # DECLARED_NATIVE: a declaration naming a native class (ClosedWorld#native_class?: RGSS::Bitmap, also where the program
  # reopens it) is [:class, cls] when ClosedWorld#native_family is the class alone, else [:union, family], which the
  # guard tests class by class. :refused when the family is unbounded or BC2CPP_DECLARED_NATIVE=0; nil for a
  # non-native type.
  def native_ivar_kind(type, closed_world)
    return nil unless type.kind == :class && closed_world&.native_class?(type.cls)
    return :refused unless native_declarations?

    family = closed_world.native_family(type.cls)
    return :refused unless family && family.size <= DECLARED_UNION_MAX

    family.size == 1 ? [:class, type.cls] : [:union, family.freeze]
  end

  def native_declarations?
    ENV['BC2CPP_DECLARED_NATIVE'] != '0'
  end

  # The tables every query reads: method owners (`self_of` only for def bodies, never blocks, whose self an
  # instance_exec may change; `owner_of` also for blocks, for lexical constant lookup) and the signature of each body.
  def context(loaded, ireps, registry, superclass_of)
    ctx = { ireps: ireps, registry: registry, subclassed: superclass_of.values.grep(String).to_set, superclass_of: superclass_of,
            classes: superclass_of.keys.to_set,
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
        next if ctx[:comment_class_args][label]&.[](i)

        inner = type.optional # `T?`: T or nil
        t = inner || type
        nilable = !inner.nil?
        if (kind = t.value) && VALUE_CLASSES.key?(kind)
          # VALUE_KIND: Float, Integer (fixnum) and Symbol parameters are guarded by their kind, not by a program class
          # annotation; `T?` also admits nil.
          next [i, VALUE_CLASSES[kind], kind, nilable]
        end
        # CORE_IVAR_KINDS: Array, Hash and String by their kind test (CodeGen#declared_param_guards keeps them only
        # in a build with no subclass of the class).
        if (core = core_kind(t))
          next [i, CORE_IVAR_KINDS.fetch(core), core, nilable]
        end
        if (union = union_classes(type, ctx[:classes], ctx[:superclass_of])) && union.first.size > 1
          next [i, union.first, :union, union.last]
        end
        if nilable
          # A nilable program class gives no hint, so no annotation names it: take the class itself when it is a class
          # the program defines and nothing subclasses (the guard is the exact-class test).
          next unless t.kind == :class && ctx[:classes].include?(t.cls) && !ctx[:subclassed].include?(t.cls)

          next [i, t.cls, :class, true]
        end
        next unless type.kind == :class && ann && ann.args[i] == type.cls

        [i, type.cls, :class, false]
      end
      positions.concat(optional_targets(ctx, label, sig))
      out << [sig, d, positions] unless positions.empty?
    end
    out
  end

  # DECLARED_OPTIONAL_PARAM: [[position, class, kind, nilable, k], ...] for the optional parameters (k-th optional) whose
  # declaration the guard can test and whose default is a literal of that kind (optional_defaults). The guard checks
  # a given argument only (bc2cpp_given_opt > k); an omitted one holds its default, so either way the register has
  # the declared kind wherever the body reads it.
  def optional_targets(ctx, label, sig)
    types = Array(sig.optional_args)
    return [] if types.empty?

    irep = ctx[:ireps][label]
    mand = sig.args.size
    defaults = irep && optional_defaults(irep, mand, types.size)
    return [] unless defaults

    types.each_with_index.filter_map do |type, k|
      pos = mand + k
      next if ctx[:comment_class_args][label]&.[](pos)

      inner = type.optional
      t = inner || type
      nilable = !inner.nil?
      core = core_kind(t)
      kind, cls = if VALUE_CLASSES.key?(t.value) then [t.value, VALUE_CLASSES[t.value]]
                  elsif core then [core, CORE_IVAR_KINDS.fetch(core)]
                  elsif t.kind == :class && ctx[:classes].include?(t.cls) && !ctx[:subclassed].include?(t.cls)
                    [:class, t.cls]
                  end
      next unless kind

      default = defaults[k]
      next unless default && (default == kind || (default == :nil && nilable))

      [pos, cls, kind, nilable, k]
    end
  end

  # DECLARED_UNION: a union of program classes (`A | B`, `nil | A | B`) or a program class with subclasses (`A`, `A?`)
  # is checked as the exact classes it stands for: [classes, nilable], a member with subclasses standing for its
  # whole program subtree. Callers take only two or more classes: one is the :class kind's own rule. Kept only where
  # the closed world bounds every listed class's subclasses by the list (union_closed?). BC2CPP_DECLARED_UNION=0: none.
  DECLARED_UNION_MAX = 8
  UNION_CORE_NAMES = %w[BasicObject Object Module Class Kernel Comparable Enumerable Integer Float Numeric Symbol String
                        Array Hash Range Proc NilClass TrueClass FalseClass Exception].to_set.freeze

  def union_classes(type, classes, superclass_of)
    return nil if ENV['BC2CPP_DECLARED_UNION'] == '0' || superclass_of.nil?

    values = type.value_classes
    return nil unless values && !values.empty?

    nilable = values.include?(:NilClass)
    members = values.reject { |v| v == :NilClass }.map(&:to_s)
    return nil if members.empty?
    return nil unless members.all? { |m| classes.include?(m) && !UNION_CORE_NAMES.include?(m) }

    children = Hash.new { |h, k| h[k] = [] }
    superclass_of.each { |k, sup| children[sup] << k if sup.is_a?(String) }
    listed = Set.new
    work = members.dup
    until work.empty?
      k = work.pop
      work.concat(children[k]) if listed.add?(k)
    end
    return nil if listed.size > DECLARED_UNION_MAX

    [listed.to_a.sort.freeze, nilable]
  end

  # DECLARED_UNION: a union guard is kept only where the closed world sees every subclass of each listed class and
  # lists it too, so "A or a subclass" is exactly the listed classes. Without a closed world none is kept.
  def union_closed?(classes, closed_world)
    return false unless closed_world

    classes.all? do |k|
      subs = closed_world.known_subclasses(k) || (native_declarations? && closed_world.native_family(k))
      subs && subs.all? { |sub| classes.include?(sub) }
    end
  end

  def closed_union_params(guards, closed_world)
    guards.transform_values do |list|
      list.reject { |_pos, cls, _key, _text, kind, *| kind == :union && !union_closed?(cls, closed_world) }
    end.reject { |_label, list| list.empty? }
  end

  def closed_union_ivars(guards, closed_world)
    guards.reject { |_key, entry| entry.kind == :union && !union_closed?(entry.cls, closed_world) }
  end

  # :array, :hash or :string for an `Array` / `Array[T]` / `Hash` / `Hash[K, V]` / `String` type (elements unchecked).
  def core_kind(t)
    return t.kind if %i[array hash].include?(t.kind)

    :string if t.kind == :class && t.cls == 'String'
  end

  # Ops that write their register from their operands alone and read no register (OPTIONAL_DEFAULT_READS).
  DEFAULT_LITERAL_OPS = (BytecodeIR::Ops::LOADI_OPS | %i[LOADNIL LOADTRUE LOADFALSE LOADSYM LOADL STRING LOADSELF]).freeze
  # Past it a LOADI32 literal may not be a fixnum on a 32-bit mrb_int target (see mrb_fixnum_p).
  DEFAULT_FIXNUM_LIMIT = 0x2000_0000

  # The kind of each optional default (:integer, :symbol, :nil, or nil for anything else) when the ENTER jump table is
  # the plain one (optional_arg_table's shape) and every default reads no register; nil otherwise.
  # OPTIONAL_DEFAULT_READS: an omitted optional is nil, not its declared kind, until its own default runs, and only the
  # defaults before it run first. Default code that reads no register cannot see it, so the entry state the class pool
  # seeds (declared kind) is what every read of the register finds.
  def optional_defaults(irep, mand, count)
    enter = irep.enter
    return nil unless enter

    fields = enter.enter_fields.map(&:to_i)
    return nil unless fields[0] == mand && fields[1] == count

    program = BytecodeIR.for(irep)
    first = irep.enter_index + 1
    return nil unless first + count + 1 <= program.size

    jmps = (first..first + count).map { |index| program.source_at(index) }
    return nil unless jmps.all? { |insn| insn.op == :JMP }

    targets = jmps.map(&:jmp_addr)
    index = first + count + 1
    count.times.map do |k|
      segment = []
      while index < program.size && program.source_at(index).addr < targets[k + 1]
        segment << program.source_at(index)
        index += 1
      end
      return nil unless segment.first&.addr == targets[k] && segment.all? { |insn| default_reads_nothing?(insn) }

      literal = segment.size == 1 && segment.first.reg == mand + 1 + k ? segment.first : nil
      literal && default_kind(literal)
    end.then { |kinds| program.source_at(index)&.addr == targets[count] ? kinds : nil }
  end

  # `ARRAY R3 0` / `HASH R3 0` (`[]`, `{}`) read the zero registers after R3.
  def default_reads_nothing?(insn)
    DEFAULT_LITERAL_OPS.include?(insn.op) || (%i[ARRAY HASH].include?(insn.op) && insn.uint_operand&.zero?)
  end

  def default_kind(insn)
    case insn.op
    when :LOADNIL then :nil
    when :LOADSYM then :symbol
    when :STRING then :string
    when :ARRAY then insn.uint_operand&.zero? ? :array : nil
    when :HASH then insn.uint_operand&.zero? ? :hash : nil
    when *BytecodeIR::Ops::LOADI_OPS
      value = BytecodeIR::Ops::LOADI_SLOT_VALUE[insn.op] || (insn.op == :LOADI__1 ? -1 : insn.imm_operand)
      value = -value.abs if value && insn.op == :LOADINEG
      value && value.abs < DEFAULT_FIXNUM_LIMIT ? :integer : nil
    end
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
