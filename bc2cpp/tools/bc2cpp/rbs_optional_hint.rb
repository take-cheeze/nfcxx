# frozen_string_literal: true

# RBS_OPTIONAL_HINT (docs/adr/0456): a declared `T?` feeds the same "T or nil" facts an inferred one does.
#
# The facts it feeds are nil-tolerant by contract, so a `T?` declaration says no more than they already mean:
#   * an ivar `@x: C?`, `@x: Array[C]?`, `@x: Hash[K, C]?` seeds ClassLayout (and its element tables) exactly like
#     `@x: C`: ClassLayout facts are "C or nil" since NIL_TOLERANT_JOIN (`@x = nil` is skipped, not joined), and every
#     consumer re-checks the class at run time -- a TYPED/IVAR_ACCESSOR guard with a by-name or hint-violation else
#     (nil fails `mrb_obj_class(v) == C`), or a loop emitter's mrb_array_p / mrb_hash_p tripwire;
#   * a return `-> C?` gives ElementAnnotations' ret_class C, whose contract is already "every non-nil value is
#     exactly C" (a nil fails the guard, annotations.rb).
# Not fed, because their consumers are exact: Integer?/Symbol? (IvarLayout embeds typed slots, FIXNUM_NIL_IVARS is
# the reviewed opt-in for that), an `Array?`/`Hash?` return (annotated_array_return admits the result as a proven
# Array), `Array[C?]` elements, and parameters (a declared parameter is a checked call-site fact, RbsParamCheck).
module RbsOptionalHint
  module_function

  # The class a `C?` return gives as ret_class, or nil.
  def return_class(type, known_owners)
    inner = type.optional
    return nil unless inner && inner.kind == :class && known_owners.include?(inner.cls)

    inner.cls
  end

  # Seeds `@x: T?` like `@x: T` for class / Array / Hash T; true when it did.
  def seed_ivar(applied, ivar_sig, name, known_owners)
    inner = ivar_sig.type.optional
    return false unless inner

    case inner.kind
    when :class
      return false unless known_owners.include?(inner.cls)

      applied.ivar_classes[ivar_sig.owner][name] = inner.cls
    when :array
      applied.ivar_classes[ivar_sig.owner][name] = 'Array'
      element = inner.element if inner.element && known_owners.include?(inner.element)
      applied.ivar_elements[ivar_sig.owner][name] = element if element
    when :hash
      applied.ivar_classes[ivar_sig.owner][name] = 'Hash'
      element = inner.element if inner.element && known_owners.include?(inner.element)
      applied.ivar_hash_elements[ivar_sig.owner][name] = element if element
    else
      return false
    end
    true
  end
end
