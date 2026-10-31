# frozen_string_literal: true

require_relative 'native_owner_map'
require_relative 'core_hierarchy_sigs'

# CodeGen: OWNER_NATIVE_CHAIN (BC2CPP_OWNER_NATIVE_READ=1). CHA_SELF's name gate (inherited_lookup_safe?) refuses a
# name any outside source defines, even when no class on the receiver's lookup path is one of those definers. This
# gate asks instead whether each owner-listed outside definer (outside_owner_call_owners) sits on that path. The proof
# and the cases it refuses: docs/bc2cpp-owner-native-chain.md.
class CodeGen
  # Off unless BC2CPP_OWNER_NATIVE_READ=1: then the gate is inherited_lookup_safe? alone, as before.
  def owner_native_chain_enabled?
    ENV['BC2CPP_OWNER_NATIVE_READ'] == '1'
  end

  # The owner proof for CHA_SELF, asked only when inherited_lookup_safe? refuses the name: false with the flag off.
  def cha_owner_native_proof?(name, self_owner, hierarchy)
    owner_native_chain_enabled? && owner_native_chain_safe?(name, self_owner, hierarchy)
  end

  # Every refusal is false: an unnamed definer (outside_owner_call_owners is nil), an unresolved descendant, or a
  # definer on the path of self_owner or one of its descendants.
  def owner_native_chain_safe?(name, self_owner, hierarchy)
    return false if hierarchy[:wild].any? || @closed_world.unknown_def?(name)
    return false unless @closed_world.stable_class_constant?(self_owner)

    definers = outside_owner_call_owners(name)
    return false unless definers

    path = owner_native_lookup_path([self_owner, *hierarchy[:descendants]])
    return false unless path

    definers.none? { |owner| path.include?(owner) }
  end

  # The classes and modules a lookup from an instance of each of +classes+ visits, as a Set; nil when one of them is not
  # named by the closed world. Object's core tail (Kernel, BasicObject) is added whole.
  def owner_native_lookup_path(classes)
    map = owner_native_map
    return nil unless map

    path = Set.new
    pending = classes.to_a.dup
    until pending.empty?
      current = pending.pop
      next unless path.add?(current)
      return nil unless current.is_a?(String) && !@unknown_mixins.include?(current)

      pending.concat(Array(@included_modules[current]), Array(@prepended_modules[current]))
      if current == 'Object'
        path.merge(CoreHierarchySigs.ancestors('Object'))
      elsif @closed_world.class_declared?(current)
        parent = @closed_world.class_parent(current)
        return nil if parent.nil?

        pending << (parent == :none ? 'Object' : parent)
      else
        # A declared module reached as a mixin: its own mixins are walked above; its identity must be stable.
        return nil unless CodeGen.module_names&.include?(current) && @closed_world.stable_constant_identity?(current)
      end
    end

    map.mixins.each do |target, mod, core|
      next if core && target == NativeOwnerMap::UNKNOWN
      return nil if target == NativeOwnerMap::UNKNOWN
      next unless path.include?(target)
      return nil unless path.include?(mod)
    end
    path
  end

  # The map outside_owner_call_decide reads, shared with it.
  def owner_native_map
    paths = owner_call_world.native_paths
    return nil unless paths

    CodeGen::NATIVE_OWNER_MAP_CACHE[paths] ||= NativeOwnerMap.build(paths)
  end
end
