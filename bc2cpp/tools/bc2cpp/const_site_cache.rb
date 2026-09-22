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
