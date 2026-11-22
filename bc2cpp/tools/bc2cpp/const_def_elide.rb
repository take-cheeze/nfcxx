# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'dynamic_names'

# CONST_DEF_ELIDE: a class-body SETCONST of an immediate (a Fixnum, Symbol, true, false or nil) is not emitted when no
# path of the program can observe the binding by name. The binding only lives in its owner's constant table, so the
# table entry is what is saved (flash at the site, heap in the table). The soundness condition, enforced by analyze:
#   world: no bytecode runs (BC2CPP_VM_FREE, the build's MRB_VM_FREE); every constant binding is static
#     (ClosedWorld#constants_static?); no Ruby send, Symbol, computed name or native funcall names a method that reads
#     or enumerates a constant table or hooks a write (REFLECTION), except a by-name read of a Symbol literal
#     (literal_name_read?); every computed-name table read in linked native code is a reviewed one
#     (NATIVE_COMPUTED_READS).
#   name: every GETCONST/GETMCNST of the bare name folds to its value (IntegerConstants' INTEGER_CONSTANT_VALUE_PROOF),
#     or there is none and every binding is an immediate literal; every binding is a SETCONST in a known lexical scope
#     (LexicalConsts) whose class can never be frozen and that no reviewed native reader reaches; no CLASS/MODULE, other
#     opcode, or native string or MRB_SYM spells the name.
# assert_unnamed! then checks that the generated text of each run names no elided constant.
# BC2CPP_CONST_DEF_ELIDE=0 keeps every definition.
module ConstDefElide
  # Methods that read a constant table by name, enumerate it, measure it, or run on a write.
  # String evaluation needs the VM, which the world gate rules out; `eval` is listed all the same.
  REFLECTION = %w[constants const_get const_defined? const_source_location const_missing const_added const_set
                  remove_const eval memsize_of memsize_of_all].to_set.freeze
  CONST_OPS = %i[GETCONST GETMCNST SETCONST SETMCNST].to_set.freeze
  IMMEDIATE_CLASSES = %i[NilClass TrueClass FalseClass Symbol].to_set.freeze
  # Calls that read a class's iv/constant table by a name (or walk it). The name argument's position follows.
  NATIVE_READ = /\b(mrb_const_get|mrb_const_defined(?:_at)?|mrb_cv_get|mrb_cv_defined|mrb_mod_cv_get|mrb_mod_cv_defined|
                   mrb_iv_get|mrb_iv_defined|mrb_obj_iv_get|mrb_obj_iv_defined|mrb_vm_const_get|
                   mrb_(?:class|module)_(?:get|defined)(?:_under)?(?:_id)?|mrb_iv_foreach)\s*\(/x
  NATIVE_LITERAL_NAME = /\A\s*(?:"(?:[^"\\]|\\.)*"|mrb_intern_(?:lit|cstr|static)\s*\(\s*\w+\s*,\s*"(?:[^"\\]|\\.)*"\s*\)|
                         MRB_(?:IV|CV|GV|OP)?SYM(?:_[QBE])?\(\s*\w+\s*\))\s*\z/x
  NATIVE_SPELLED = /"((?:[^"\\\n]|\\.)*)"|\bMRB_SYM(?:_[QBE])?\(\s*(\w+)\s*\)/
  # mruby's own runtime: its computed-name reads are the reflection methods above, the VM's opcodes (not run here),
  # the class-definition and lookup APIs whose callers pass the name (scanned at each caller), and ivar/cvar accessors
  # that reject a non-@ name. Audited against 3rd/mruby/src.
  NATIVE_TRUSTED = %r{/3rd/mruby/src/}
  # NATIVE_COMPUTED_READS: reviewed computed-name reads in linked native code outside mruby's src, keyed by the path
  # suffix and the call with its whitespace squeezed. :literal -- the name comes from a string literal of the same file,
  # which the spelled-name scan already counts; :validated -- an ivar/cvar accessor that rejects a constant name;
  # an Array -- the read reaches only these owners' tables (mrb_const_get then walks their ancestors and Object's).
  NATIVE_COMPUTED_READS = {
    'mruby-lcf/src/schema_tables.hxx' => { 'mrb_const_get(M, mrb_obj_value(schema), sym(varint()))' => ['LCF::Schema'] },
    'mruby-rgss/src/lib.cxx' => {
      'mrb_iv_get(M, self, font_iv)' => :literal, 'mrb_const_defined(M, obj, sym)' => :literal,
      'mrb_const_get(M, obj, sym)' => :literal, 'mrb_const_defined(M, rgss_mod, font_sym)' => :literal,
      'mrb_const_get(M, rgss_mod, font_sym)' => :literal, 'mrb_iv_get(M, v, bitmap_sym)' => :literal,
      'mrb_iv_get(M, self, mrb_intern_cstr(M, iv))' => :literal
    },
    'src/error_dump.cxx' => { 'mrb_const_defined(M, owner, sym)' => :literal, 'mrb_const_get(M, owner, sym)' => :literal },
    'mruby-metaprog/src/metaprog.c' => {
      'mrb_iv_defined(mrb, self, sym)' => :validated, 'mrb_iv_get(mrb, self, iv_name)' => :validated,
      'mrb_cv_defined(mrb, mod, id)' => :validated, 'mrb_cv_get(mrb, mod, id)' => :validated
    }
  }.freeze

  Result = Struct.new(:names, :refusal, :kept, keyword_init: true) do
    def elide?(name) = names.include?(name)
  end

  module_function

  def enabled?
    ENV['BC2CPP_CONST_DEF_ELIDE'] != '0'
  end

  # ireps: the whole program. folded: bare name => value (CodeGen.integer_constant_values). facts: the
  # BYTECODE_CONSTANT_FACTS groups. site_keys: LexicalConsts site keys. linked_native: the native sources linked into
  # the image; spelled_native: every native source the build names (a superset is only a missed elision).
  # mixins: the registry's tables (superclass_of:, included:, prepended:, unknown:, modules:) for the owners a reviewed
  # native read reaches (lookup_scope).
  def analyze(ireps:, folded:, facts:, site_keys:, closed_world:, linked_native:, spelled_native:, mixins:)
    refusal = world_refusal(ireps, closed_world, linked_native)
    reached = Set.new
    native_reads(linked_native).each do |_path, _call, verdict|
      next unless verdict.is_a?(Array)

      verdict.each do |owner|
        scope = lookup_scope(owner, **mixins)
        scope ? reached.merge(scope) : refusal ||= "the ancestors of #{owner} are not known"
      end
    end
    return Result.new(names: Set.new, refusal: refusal, kept: {}) if refusal

    spelled = spelled_names(spelled_native)
    candidates, kept = bindings(ireps, site_keys)
    reads = Hash.new(0)
    other = Set.new
    ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn, _idx|
        case insn.op
        when :GETCONST, :GETMCNST then reads[insn.const_name] += 1
        when :CLASS, :MODULE then other << insn.sym.to_s
        else
          sym = insn.sym
          other << sym.to_s if sym && !CONST_OPS.include?(insn.op)
        end
      end
    end
    names = Set.new
    candidates.each do |name, owners|
      why = name_refusal(name, owners, folded, facts, reads, other, spelled, reached, closed_world)
      why ? kept[name] = why : names << name
    end
    Result.new(names: names, refusal: nil, kept: kept)
  end

  def report(result)
    if result.refusal
      warn "== constant definitions elided (CONST_DEF_ELIDE): off (#{result.refusal}) =="
    else
      warn "== constant definitions elided (CONST_DEF_ELIDE): #{result.names.size} names, #{result.kept.size} kept =="
      result.names.sort.each { |name| warn "  CONST_DEF_ELIDE #{name}" }
      result.kept.sort.each { |name, why| warn "  CONST_DEF_KEPT #{name} (#{why})" }
    end
    warn ''
  end

  # The generated text of a run must name no elided constant: a lookup the codegen kept would find nothing. Read are
  # every MRB_SYM and interned literal of +texts+ and every literal of the run's symbol table (escapes decoded, `::`
  # paths split); a String value's literal is no name. Aborts on a hit.
  SYMBOL_CALLS = %w[mrb_intern_cstr mrb_intern_lit mrb_intern_static mrb_intern BC2CPP_LIT_SYM
                    bc2cpp_const_path_has].to_set.freeze
  GENERATED_NAME = /(?:\b(\w+)\(M,\s*)?"((?:[^"\\\n]|\\.)*)"|\bMRB_SYM(?:_[QBE])?\(\s*(\w+)\s*\)/

  def assert_unnamed!(result, texts, symbol_literals)
    return if result.nil? || result.names.empty?

    hits = {}
    texts.each { |text| scan_names(result, text, hits) { |fn| SYMBOL_CALLS.include?(fn) } }
    scan_names(result, symbol_literals.join("\n"), hits) { true }
    return if hits.empty?

    abort "bc2cpp: CONST_DEF_ELIDE: the generated code still names #{hits.keys.sort.join(', ')}, whose definitions were " \
          "elided (BC2CPP_CONST_DEF_ELIDE=0 keeps them):\n#{hits.map { |name, at| "  #{name}: ...#{at}..." }.join("\n")}"
  end

  # Records in +hits+ (name => context) each elided name of +text+; a literal counts when the block accepts its call.
  def scan_names(result, text, hits)
    text.scan(GENERATED_NAME) do |fn, lit, sym|
      at = Regexp.last_match.begin(0)
      next if lit && !yield(fn)

      names = sym ? [sym] : lit.gsub(/\\x(\h\h)/) { Regexp.last_match(1).hex.chr }.split('::')
      names.each { |name| hits[name] ||= text[[at - 80, 0].max, 160].gsub(/\s+/, ' ') if result.names.include?(name) }
    end
  end

  def world_refusal(ireps, closed_world, linked_native)
    return 'BC2CPP_CONST_DEF_ELIDE=0' unless enabled?
    return 'bytecode can run (the build does not define MRB_VM_FREE)' unless ENV['BC2CPP_VM_FREE'] == '1'
    return 'no closed world' unless closed_world
    return 'constant bindings are not static' unless closed_world.constants_static?

    ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn, idx|
        name = insn.sym.to_s
        next unless REFLECTION.include?(name)
        next if literal_name_read?(irep, idx, insn)

        return "#{File.basename(irep.file.to_s)} #{irep.label}:#{idx} names :#{name}"
      end
    end
    dynamic = DynamicNames.universe(ireps) & REFLECTION
    return "a computed name may be :#{dynamic.min}" unless dynamic.empty?

    linked_native.each do |path|
      next if path.match?(NATIVE_TRUSTED) || !File.file?(path)

      text = File.read(path, encoding: 'BINARY')
      # native_funcall_names seeds the hooks mruby itself calls (const_missing on a failed lookup): not calls here.
      called = ((ClosedWorld.native_funcall_names(text) - ClosedWorld::IMPLICIT_HOOKS) +
                ClosedWorld.native_other_literals(text)).to_set & REFLECTION
      return "#{path} names :#{called.min}" unless called.empty?
    end
    unreviewed = native_reads(linked_native).find { |_path, _call, verdict| verdict.nil? }
    return "unreviewed native table read #{unreviewed[0]}: #{unreviewed[1]}" if unreviewed

    nil
  end

  # `Object.const_defined?(:Float)`: a by-name read whose name is a Symbol literal reads that name only, and the
  # LOADSYM already keeps it (name_refusal's other opcodes).
  LITERAL_NAME_READS = %w[const_get const_defined? const_source_location].to_set.freeze

  def literal_name_read?(irep, idx, insn)
    return false unless LITERAL_NAME_READS.include?(insn.sym.to_s) && BytecodeIR::Ops::SEND.include?(insn.op)
    return false unless [1, 2].include?(insn.argc) && !BytecodeIR::Ops::BLOCK_SEND.include?(insn.op)

    irep.walk_dominating_writers(idx - 1, insn.reg + 1, use: idx, follow_moves: true) do |writer, _index|
      writer.op == :LOADSYM
    end == true
  end

  # [path, squeezed call, verdict] of each computed-name table read in a linked native file outside mruby's src.
  def native_reads(paths)
    @native_reads ||= {}
    @native_reads[paths] ||= paths.flat_map do |path|
      next [] if path.match?(NATIVE_TRUSTED) || !File.file?(path)

      text = File.read(path, encoding: 'BINARY').gsub(%r{//[^\n]*|/\*.*?\*/}m, ' ')
      reviewed = NATIVE_COMPUTED_READS.find { |suffix, _| path.end_with?("/#{suffix}") }&.last || {}
      text.to_enum(:scan, NATIVE_READ).filter_map do
        match = Regexp.last_match
        fn = match[1]
        args = bc2cpp_c_call_args(text[match.end(0)..])
        position = if fn == 'mrb_iv_foreach' then nil
                   elsif fn.match?(/\Amrb_(?:class|module)_/) then fn.include?('_under') ? 2 : 1
                   else 2
                   end
        next if position && args[position].to_s.match?(NATIVE_LITERAL_NAME)
        # A prototype or the definition's own header is no read.
        next if args.first.to_s.match?(/\A\s*mrb_state\s*\*/)

        call = "#{fn}(#{args.map(&:strip).join(', ')})".gsub(/\s+/, ' ')
        [path, call, reviewed[call]]
      end
    end
  end

  # Every name a native source spells as a string literal or an MRB_SYM.
  def spelled_names(paths)
    names = Set.new
    paths.each do |path|
      next unless File.file?(path)

      File.read(path, encoding: 'BINARY').scan(NATIVE_SPELLED) { |lit, sym| names << (lit || sym) }
    end
    names
  end

  # name => [owner, ...] for every SETCONST, and name => why for the names a binding refuses.
  def bindings(ireps, site_keys)
    owners = Hash.new { |h, k| h[k] = [] }
    kept = {}
    ireps.each_value do |irep|
      BytecodeIR.for(irep).each_with_op(:SETCONST, :SETMCNST) do |insn, _idx|
        name = insn.const_name
        next unless name

        if insn.op == :SETMCNST
          kept[name] = 'a `Scope::NAME =` binding'
        elsif (key = site_keys[insn])
          owners[name] << (key.include?('::') ? key.delete_suffix("::#{name}") : 'Object')
        else
          kept[name] = 'a binding in an unknown lexical scope'
        end
      end
    end
    [owners.reject { |name, _| kept.key?(name) }, kept]
  end

  # Every binding is nil, true, false, a Symbol, or an Integer inside the Fixnum margin.
  def immediate_fact?(fact)
    classes = fact&.classes
    return false if classes.nil? || classes.empty?
    return true if classes.subset?(IMMEDIATE_CLASSES)

    classes == Set[:Integer] && !(fact.value || fact.interval).nil?
  end

  # The owners whose tables mrb_const_get(owner, name) reads (variable.c const_get): the owner, its mixins and
  # superclasses, then Object's chain when the owner is a module. nil when a step is not known.
  def lookup_scope(owner, superclass_of:, included:, prepended:, unknown:, modules:)
    seen = Set.new
    queue = [owner]
    queue << 'Object' if modules.include?(owner)
    until queue.empty?
      current = queue.shift
      next unless seen.add?(current)
      return nil if unknown.include?(current)

      queue.concat(Array(prepended[current]), Array(included[current]))
      next if modules.include?(current) || %w[BasicObject Kernel].include?(current)

      parent = current == 'Object' ? 'BasicObject' : superclass_of[current]
      parent = 'Object' if parent == :none
      return nil if parent.nil? && current != 'BasicObject'

      queue << parent.to_s if parent
    end
    seen | Set['Kernel']
  end

  def name_refusal(name, owners, folded, facts, reads, other, spelled, reached, closed_world)
    unless folded.key?(name)
      return 'read and not folded' if reads[name].positive?
      return 'not an immediate' unless immediate_fact?(facts[name])
    end
    return 'spelled by another opcode' if other.include?(name)
    return 'spelled by native code' if spelled.include?(name)

    owners.each do |owner|
      return "#{owner} is reached by a native constant read" if reached.include?(owner)
      return "#{owner} may be frozen" if closed_world.class_object_freeze_possible?(owner.split('::').last)
    end
    nil
  end
end
