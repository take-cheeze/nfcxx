# frozen_string_literal: true

# CONST_SITE_CACHE: a GETCONST inside a namespaced owner resolves its lexical
# scope chain on every execution -- one mrb_const_get per owner path segment,
# then one probe per scope, innermost first. In the RPG2k map scene that was
# about a third of a frame's instructions (Game::Interpreter#execute's command
# switch does it in every `when` arm).
#
# Caching the result per site is only sound if the lookup can never resolve
# differently later. StableClassConstants proves that for a bare name that
#   (a) is introduced by exactly ONE `class`/`module` statement in the program,
#       so no other scope can define, reopen-as-something-else or shadow it;
#   (b) is never assigned with `Name = ...` (SETCONST/SETMCNST), which is how a
#       constant gets reassigned, nor defined by a native (mrb_define_class /
#       mrb_define_const / mrb_const_set) or foreign Ruby source compiled into
#       the same VM; and
#   (c) lives in a program that never calls const_set / remove_const / autoload,
#       the other ways a constant table changes.
# (`const_get` only reads, and `const_missing` only runs on a FAILED lookup,
# which is never cached, so neither matters.) The name then denotes one class
# object for the life of the VM, and a lookup either finds it or raises
# NameError, so caching the found value is exact. When the native/foreign inputs
# are absent (a unit check building a CodeGen directly) (b) cannot be proven and
# nothing is cached.
module StableClassConstants
  DYNAMIC_MUTATION = /\b(?:const_set|remove_const|autoload)\b/

  module_function

  def analyze(ireps, native_paths, foreign_paths)
    return Set.new unless native_paths && foreign_paths

    class_defs = Hash.new(0)
    assigned = Set.new
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        case insn.op
        when 'CLASS', 'MODULE'
          name = insn.args[/:(\S+)/, 1]
          class_defs[name] += 1 if name
        when 'SETCONST'
          assigned << insn.args[/\A(\S+)/, 1]
        when 'SETMCNST'
          assigned << insn.args[/::(\S+)/, 1]
        when 'SEND', 'SEND0', 'SSEND', 'SSEND0', 'SENDB', 'SSENDB', 'LOADSYM'
          return Set.new if insn.args.match?(DYNAMIC_MUTATION)
        end
      end
    end
    Array(foreign_paths).each do |path|
      text = begin
        File.read(path, encoding: 'UTF-8')
      rescue StandardError => e
        warn "[bc2cpp] StableClassConstants: cannot read #{path}: #{e.message}"
        return Set.new
      end
      return Set.new if text.match?(DYNAMIC_MUTATION)
    end
    outside = IntegerConstants.native_defined_const_names(native_paths) |
              IntegerConstants.foreign_const_names(foreign_paths)
    class_defs.select { |name, count| count == 1 && !assigned.include?(name) && !outside.include?(name) }.keys.to_set
  end
end

# NATIVE_CLASS_CONSTANT_CACHE: StableClassConstants.analyze above only admits a
# bare name introduced by a Ruby `class`/`module` STATEMENT -- every built-in
# core class (Symbol, Array, Hash, Integer, String, Range, Object, Struct, ...)
# and every class a native mrbgem defines is invisible to it: `mrb_define_class`
# runs from C, leaving no CLASS/MODULE bytecode instruction anywhere. That is a
# real, measured cost: `LCF::Array1D#[]`'s bare `idx.is_a? Symbol` (and its
# sibling call sites) pays this class's full GETCONST lookup chain -- resolve
# `LCF::Array1D`'s own const table (miss), `LCF`'s (miss), then Object's,
# through mrb_intern_cstr + mrb_const_get every single call -- roughly 70
# executed lookups per rendered frame in the RPG2k map scene.
#
# Deriving WHICH bare names are genuinely native-defined has to come from the
# real native/foreign sources, exactly like every other proof in this file --
# never a hand-written "well-known builtins" list, which would silently miss a
# gem-defined class or (worse) admit a name some OTHER gem happens to reuse for
# something unrelated. `native_class_module_names` below parses the real
# `mrb_define_(class|module)(_id|_under)?` / `mrb_class_get(_id)?` /
# `mrb->xxx_class` / `boot_defclass`+`mrb_define_const_id` call shapes --
# exactly the same shapes NativeExpressionDevirt.analyze_exact_class_expressions
# already recognizes to resolve an owner's real runtime class, reused here
# rather than re-invented, so a future change to how a class gets named only
# has to be taught to one parser.
#
# Analyze below is deliberately NOT folded into StableClassConstants.analyze:
# that method's own doc comment claims exactly one Ruby class/module STATEMENT;
# widening it to also accept a native definition would make that claim false.
# The two proofs are unioned by the caller instead, once each name has cleared
# its own bar.
#
# Soundness, reasoned from first principles rather than by analogy:
#
# 1. A native mrb_define_class(_id/_under) call site inside a gem's own
#    gem_init (or mruby core's own mrb_init_core) runs EXACTLY ONCE per VM,
#    before any Ruby code the closed world compiles can run -- the same
#    "boots once, at gem-init time" assumption this file's own owner-class
#    cache (`emit_owner_class_cache`) and every generated exact-class guard
#    already rest on with no extra proof attached. This module adds one more
#    check beyond that existing trust level: if the SAME bare name is defined
#    by more than one DISTINCT native call site (two different gems each
#    naming a class "Foo" at different nesting, however unlikely), the name is
#    refused -- caching one of two genuinely different classes under a shared
#    bare name would be a real, silent wrong answer, not just a missed
#    optimization.
#
# 2. Once bound at gem-init time, could the SAME bare name's constant
#    thereafter point somewhere else? Only via SETCONST/SETMCNST (Ruby
#    `Name = ...`), Module#const_set, Module#remove_const, or Kernel#autoload
#    -- there is no other mechanism (checked directly against
#    3rd/mruby/src/variable.c). All four are already exactly what
#    StableClassConstants's own `assigned`/DYNAMIC_MUTATION scan looks for,
#    bare-name keyed (poisoning every site that shares the name, not just the
#    one instruction involved) -- reused here unchanged rather than
#    re-derived, so both proofs stay poisoned by the identical set of dynamic
#    mutations.
#
# 3. Could a Ruby-level `class Symbol; ... end` REOPENING the real native
#    class (adding methods, never changing what the constant itself is bound
#    to) invalidate this? No: `OP_CLASS`'s own real semantics (looking up an
#    existing same-named constant and reusing it rather than allocating a new
#    RClass) mean reopening changes what METHODS the class has, never what the
#    "Symbol" constant, from any given call site, resolves to. Unlike
#    StableClassConstants (whose whole claim is anchored on the Ruby-side
#    CLASS/MODULE bytecode being the class's only real definition), this
#    proof is deliberately silent on `class_defs`'s own count for the name --
#    admission here does not require, and is not blocked by, a Ruby-side
#    reopening of the same class. This holds equally for a reopening inside
#    the closed world's own bytecode and one in a FOREIGN Ruby source (mruby
#    core's own mrblib reopens `Symbol` this exact way,
#    `3rd/mruby/mrblib/symbol.rb`) -- both run through the identical OP_CLASS
#    reuse-if-present semantics in the SAME VM, so `foreign_reassigned_names`
#    below is deliberately narrower than `IntegerConstants.foreign_const_names`
#    (which folds a `class`/`module` statement and a `Name = value` assignment
#    into one Set for a DIFFERENT purpose -- disqualifying a name
#    StableClassConstants.analyze would otherwise admit purely because some
#    outside code touches it at all, reopening included): only a foreign
#    PLAIN ASSIGNMENT is a real reassignment risk here.
#
# 4. Could a DIFFERENT class, nested somewhere else in the program under the
#    SAME bare name, make the cache wrong for a site that is lexically inside
#    that nested scope (`module Foo; class Symbol; end; end`, referenced from
#    inside Foo)? No -- and this is the one place this module leans on the
#    caller's own architecture rather than reasoning about the name in
#    isolation: `emit_const_site_cache` keys its cache per `[owner_path,
#    name]`, one independent helper per real call site's own real lexical
#    scope, and each helper still runs that SAME site's own real, full
#    scope-chain-then-Object lookup on its first (and only its first) call --
#    this proof only lets that one real lookup's result be reused afterward
#    instead of re-run, so whatever a genuine reopening/shadow would cause a
#    real Ruby program to resolve on every call, THIS site's own helper
#    resolves and caches on its first call too, identically. A name is only
#    unsound to admit here if its RESOLUTION could change between two calls of
#    the identical instruction -- reasons 1-2 above are the only such changes
#    that exist, and both are already covered.
module StableClassConstants
  # Parses the exact call shapes NativeExpressionDevirt.analyze_exact_class_
  # expressions already recognizes for a native class/module definition --
  # `mrb_define_(class|module)_id(mrb, MRB_SYM(Name), ...)`,
  # `mrb_define_(class|module)(_under)?(mrb, "Name", ...)`, and the
  # `boot_defclass`+`mrb_define_const_id` shape class.c's own BasicObject/
  # Object/Module/Class boot sequence uses -- reduced here to just the bare
  # names introduced, since the const-site cache does not need the field/tag
  # bookkeeping that method's own exact-class-guard callers do.
  def self.native_class_module_names(native_paths)
    counts = Hash.new(0)
    Array(native_paths).each do |path|
      next unless File.file?(path)

      source = File.read(path, encoding: 'UTF-8')
      source.scan(/\bmrb_define_(?:class|module)_id\s*\(\s*\w+\s*,\s*MRB_SYM\((\w+)\)/) { counts[Regexp.last_match(1)] += 1 }
      source.scan(/\bmrb_define_(?:class|module)(?:_under)?\s*\(\s*\w+(?:\s*,\s*\w+)?\s*,\s*"([^"]+)"/) do
        counts[Regexp.last_match(1)] += 1
      end
      booted = source.scan(/(\w+)\s*=\s*boot_defclass\s*\(/).flatten
      source.scan(/mrb_define_const_id\s*\(\s*\w+\s*,\s*(\w+)\s*,\s*MRB_SYM\((\w+)\)\s*,\s*mrb_obj_value\(\1\)\s*\)/) do |variable, name|
        counts[name] += 1 if booted.include?(variable)
      end
    end
    # Reject a bare name more than one distinct native site defines -- the
    # program-wide count intentionally does not dedupe identical repeated
    # scans of the SAME source file/site (this method is called once per
    # whole-program analysis, not per file), so this only ever fires for a
    # real second, different mrb_define_(class|module) call elsewhere.
    counts.select { |_name, count| count == 1 }.keys.to_set
  end

  # `IntegerConstants.foreign_const_names`'s own `Name = value` half only --
  # deliberately not its `class`/`module` half, which a real reopening (see
  # point 3 above) matches identically to a genuinely different definition
  # and so cannot be trusted to disqualify anything here.
  def self.foreign_reassigned_names(paths)
    names = Set.new
    Array(paths).each do |path|
      text = begin
        File.read(path, encoding: 'UTF-8')
      rescue StandardError
        next
      end
      text.scan(/^\s*([A-Z][A-Za-z_0-9]*)\s*=[^=~]/) { names << Regexp.last_match(1) }
    end
    names
  end

  # The native/builtin sibling of `analyze` above. Returns a Set unioned into
  # `analyze`'s own result by the caller; never overlaps with it in practice
  # (analyze's own `outside` check already excludes any name a native source
  # touches at all), but this does not rely on that -- a name proven stable by
  # BOTH would just be redundant, never contradictory, since both proofs
  # require the same non-reassignment/non-mutation preconditions.
  def self.analyze_native(ireps, native_paths, foreign_paths)
    return Set.new unless native_paths && foreign_paths

    assigned = Set.new
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        case insn.op
        when 'SETCONST'
          assigned << insn.args[/\A(\S+)/, 1]
        when 'SETMCNST'
          assigned << insn.args[/::(\S+)/, 1]
        when 'SEND', 'SEND0', 'SSEND', 'SSEND0', 'SENDB', 'SSENDB', 'LOADSYM'
          return Set.new if insn.args.match?(DYNAMIC_MUTATION)
        end
      end
    end
    Array(foreign_paths).each do |path|
      text = begin
        File.read(path, encoding: 'UTF-8')
      rescue StandardError => e
        warn "[bc2cpp] StableClassConstants: cannot read #{path}: #{e.message}"
        return Set.new
      end
      return Set.new if text.match?(DYNAMIC_MUTATION)
    end
    foreign_reassigned = foreign_reassigned_names(foreign_paths)
    native_class_module_names(native_paths).reject { |name| assigned.include?(name) || foreign_reassigned.include?(name) }.to_set
  end
end
