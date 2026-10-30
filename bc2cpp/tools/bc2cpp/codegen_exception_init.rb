# frozen_string_literal: true

# EXCEPTION_INIT: `super` in an initialize whose superclass chain reaches Exception#initialize (mruby's exc_initialize,
# error.c) is that native, so the super is its work done directly rather than a by-name call. exc_initialize reads its
# one optional argument with mrb_get_args "|o" and, when given, sets the message with mrb_exc_mesg_set (the function
# error.c defines without `static`; mruby/internal.h declares it without a C linkage guard, so the prelude declares it).
# Returns the exception.
#
# Only a chain whose classes define no initialize of their own up to Exception is taken: a Ruby or native initialize on
# one of them is the target instead. A super with more than one argument stays by name (exc_initialize takes at most one).
class CodeGen
  EXCEPTION_INIT_MARKER = 'bc2cpp_exc_init('

  EXCEPTION_INIT_PRELUDE = <<~CPP
    // EXCEPTION_INIT (error.c exc_initialize): mrb_exc_mesg_set is defined there without `static` and declared only in
    // mruby/internal.h, which has no C linkage guard.
    #include <mruby/error.h>
    extern "C" void mrb_exc_mesg_set(mrb_state*, struct RException*, mrb_value);
    static mrb_value bc2cpp_exc_init(mrb_state* M, mrb_value self, mrb_value mesg) {
      mrb_exc_mesg_set(M, mrb_exc_ptr(self), mesg);
      return self;
    }
  CPP

  # The `super` call for an Exception#initialize target, or nil when the target is another method or the chain is open.
  def native_exception_initialize(owner_def, irep, d_reg, n)
    return nil unless owner_def && owner_def.name == 'initialize' && n && n.to_i.between?(0, 1)
    return nil unless call_facts_enabled? && super_direct_call_allowed?(owner_def)
    return nil unless exception_initialize_chain?(owner_def.owner)

    note_super_site(:native_exception_init, owner_def, irep, nil)
    if n.to_i.zero?
      "  r#{d_reg} = self;\n"
    else
      "  r#{d_reg} = bc2cpp_exc_init(M, self, r#{d_reg.to_i + 1});\n"
    end
  end

  # Every class from owner's superclass up to Exception: none defines initialize (no registry body), and Exception's own
  # initialize is the native one.
  def exception_initialize_chain?(owner)
    chain = []
    cur = @superclass_of[owner]
    while cur.is_a?(String)
      chain << cur
      return false if chain.size > 32
      break if cur == 'Exception'

      cur = @superclass_of[cur] || native_superclass(cur)
    end
    return false unless chain.last == 'Exception'

    defs = @registry['initialize'] || []
    defs.none? { |d| d.irep && (chain.include?(d.owner) || d.owner == 'Exception') }
  end

  # The superclass of a builtin class, from ClassWorld's table (its ancestor list starts with the class itself).
  def native_superclass(name)
    entry = ClassWorld::NATIVE[name]
    entry && entry[0][1]
  end

  # File-scope helper for the `super` calls that use it, from the compiled method texts; '' when none does.
  def emit_exception_init_helpers(codes)
    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    return '' unless texts.any? { |t| t.include?(EXCEPTION_INIT_MARKER) }

    EXCEPTION_INIT_PRELUDE
  end
end
