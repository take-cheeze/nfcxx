# frozen_string_literal: true

require 'set'

# CodeGen: PARAM_FOLD, behind BC2CPP_PARAM_FOLD=1.
#
# A decided-branch fold refuses a jump whose tested register reaches the method's entry: a method the flow
# does not enumerate can be called with an argument no call site shows. The pooled entry mask is the join of
# every call that can run the method only when nothing else can. That holds when the method's name is installed by a
# plain `def` alone, no send computes its name, and no method_missing answers for its owner.
class CodeGen
  def param_fold_enabled?
    ENV['BC2CPP_PARAM_FOLD'] == '1'
  end

  # True when the entry register +reg+ of +irep+ may be decided from its pooled mask: the gate is on, the method is
  # complete (see the header), and the register is a pooled candidate (its key is still in @entry_arg_numeric).
  def param_fold_proves_entry?(irep, reg, owner_def)
    return false unless param_fold_enabled? && owner_def && owner_def.irep == irep.label
    return false unless @entry_arg_numeric&.key?([irep.label, reg.to_i])

    param_fold_complete?(owner_def)
  end

  # A `def` alone reaches +owner_def+: its name is not installed by define_method or alias, no computed-name send
  # reaches it, the owner has no method_missing, and the closed world is whole.
  def param_fold_complete?(owner_def)
    world = @closed_world
    return false unless world && world.global_refusal.nil? && world.method_missing_classes.empty?

    name = owner_def.name
    installed = symbol_installed_names
    return false if installed.nil? || installed.include?(name) || numeric_dynamically_named?(name)

    defs = @registry.fetch(name, [])
    defs.size == 1 && defs.first.owner == owner_def.owner
  end
end
