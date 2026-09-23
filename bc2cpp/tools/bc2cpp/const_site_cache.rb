# frozen_string_literal: true

# CONST_SITE_CACHE: a GETCONST inside a namespaced owner resolves its lexical
# scope chain on every execution -- one mrb_const_get per owner path segment,
# then one probe per scope, innermost first (Game::Interpreter#execute does it
# in every `when` arm).
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

# NATIVE_CLASS_CONSTANT_CACHE: the same cache for bare names a native
# `mrb_define_class`/`_module` defines (Symbol, Array, ... and every native
# gem's classes), which leave no CLASS/MODULE bytecode for `analyze` to see --
# e.g. `LCF::Array1D#[]`'s `idx.is_a? Symbol`. The names come from the real
# native sources, never a hand-written builtin list. Kept separate from
# `analyze` (whose claim is "exactly one Ruby class/module statement"); the
# caller unions the two.
#
# Soundness:
# 1. A native definition runs once per VM, at gem init, before any compiled
#    code (the same trust the owner-class cache already rests on). A bare name
#    defined by more than one distinct native site is refused.
# 2. After that, the constant can only be rebound by SETCONST/SETMCNST,
#    const_set, remove_const or autoload (3rd/mruby/src/variable.c) -- the
#    same bare-name-keyed poisoning StableClassConstants already applies.
# 3. A Ruby `class Symbol` reopening (closed world or foreign, e.g.
#    3rd/mruby/mrblib/symbol.rb) reuses the existing class via OP_CLASS and
#    never rebinds the constant, so only a foreign plain assignment
#    disqualifies a name here (foreign_reassigned_names).
# 4. A same-named class nested elsewhere is harmless: emit_const_site_cache
#    keys each helper by [owner_path, name] and still runs that site's full
#    lexical lookup on first call; only the reuse of that result is proven.
module StableClassConstants
  # The call shapes NativeExpressionDevirt.analyze_exact_class_expressions
  # recognizes (`mrb_define_(class|module)_id(mrb, MRB_SYM(Name), ...)`,
  # `mrb_define_(class|module)(_under)?(mrb, "Name", ...)`, class.c's
  # `boot_defclass`+`mrb_define_const_id`), reduced to the bare names.
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
    # Refuse a bare name defined by more than one distinct native site.
    counts.select { |_name, count| count == 1 }.keys.to_set
  end

  # Only the `Name = value` half of `IntegerConstants.foreign_const_names`: its
  # `class`/`module` half also matches a harmless reopening (point 3 above).
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

  # The native sibling of `analyze`; the caller unions the two Sets. Both require
  # the same non-reassignment preconditions, so an overlap is only redundant.
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
