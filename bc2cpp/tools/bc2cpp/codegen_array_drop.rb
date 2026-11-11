# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# ARRAY_DROP: `ary.drop(n)` on an exact Array copies the tail in one call. mruby has no Array#drop here, so the call
# reaches Enumerable#drop (mruby-enum-ext), which runs `each { |*val| ... }` and so makes a block call, a one-element
# Array for `*val` and an `__svalue` for every element, then `ary <<` for each kept one.
#
# A SEND of drop with one plain argument is rewritten when the world agrees that an Array receiver reaches that Ruby
# method and nothing else: no native registers drop on a class Array reaches (a newer mruby has Array#drop), the only definition of drop on
# Array's resolution chain is Enumerable's core one, and no Ruby definition of each outside the core reaches an Array
# (Enumerable#drop calls each), nothing is installed at run time under either name, and no module is prepended to Array
# or mixed into it unseen. The fast path runs when the receiver is exactly an Array (M->array_class) and the argument
# is an Integer that is not negative; a larger count gives an empty Array, as Enumerable#drop does. Any other
# receiver or argument (a negative count's ArgumentError, a Float or an object with to_int, a Range, a Hash, an
# Array subclass that may define each) runs the original instruction. BC2CPP_ARRAY_DROP=0 turns it off.
class CodeGen
  def array_drop_enabled?
    ENV['BC2CPP_ARRAY_DROP'] != '0'
  end

  # Is the Enumerable#drop of this world the only thing `array.drop(n)` can run, and does it read the elements through an
  # each that only the core defines? Computed once.
  def array_drop_safe?
    return @array_drop_safe if defined?(@array_drop_safe)

    @array_drop_safe = compute_array_drop_safe
  end

  private

  def compute_array_drop_safe
    return false unless array_drop_enabled? && @registry
    return false if devirt_blocked_name?('drop') || devirt_blocked_name?('each')

    chain = method_resolution_owners(['Array'])
    return false if chain.any? { |owner| !Array(@prepended_modules[owner]).empty? || @unknown_mixins.include?(owner) }

    # A native named drop on any class Array reaches (a newer mruby has Array#drop) would answer first; the map says
    # which classes register the name, where the registry's '<native>' owner does not.
    map = native_owner_map
    return false if map.nil?

    reach = chain | %w[Object Kernel BasicObject]
    return false unless NativeOwnerMap.verdict(map, 'drop', reach, core_dynamic_trusted: native_owner_map_mode == :trusted) == [:proven]

    drops = @registry['drop'] || []
    return false unless drops.any? { |d| d.owner == 'Enumerable' && d.core }
    return false if drops.any? { |d| chain.include?(d.owner) && !(d.owner == 'Enumerable' && d.core) }

    # Enumerable#drop calls each: a Ruby each outside the core on Array's chain would run instead of the core one.
    (@registry['each'] || []).none? { |d| chain.include?(d.owner) && !d.core }
  end

  def array_drop_site?(insn)
    insn.op == :SEND && insn.sym == 'drop' && insn.plain_fixed_argc? && insn.argc.to_i == 1 && !insn.keyword_arguments?
  end

  def array_drop_text(a, original)
    n = a + 1
    head = [
      "  // ARRAY_DROP: r#{a}.drop(r#{n}) copies the tail of an exact Array with an Integer count, with no block call per element\n",
      "  {\n",
      "    if (mrb_array_p(r#{a}) && mrb_obj_ptr(r#{a})->c == M->array_class && mrb_integer_p(r#{n}) && mrb_integer(r#{n}) >= 0) {\n",
      "      r#{a} = bc2cpp_ary_drop(M, r#{a}, mrb_integer(r#{n}));\n",
      "    } else {\n"
    ]
    (head + original.lines.map { |line| "  #{line}" } + ["    }\n", "  }\n"]).join
  end
end

# Prepended to CodeGen: one instruction, so no pairing state. A shifted body hands over the instruction with its
# registers already shifted, which the text uses as given.
module ArrayDropCompileInsn
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    return super unless array_drop_site?(insn) && array_drop_safe? && !@resumable

    reg = reg_int(insn.reg)
    return super unless reg

    array_drop_text(reg, super)
  end
end

CodeGen.prepend(ArrayDropCompileInsn)
