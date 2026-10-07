# frozen_string_literal: true

# CORE_COMPILED_DEFINERS (docs/adr/0371): the compiled core Ruby of this run as a view of its own, next
# to the registry, which deliberately holds no core definition (ADR 0264 finding 1: every name-keyed fast
# path needs the registry to hold only the native definition of a name). The view answers one question:
# is the foreign Ruby definer of `name` on `owner` a method this run compiled, so a helper may call its
# `_impl` instead of dispatching by name?
#
# First consumer: the Hash arm of the `< <= > >=` helpers (ADR 0362 left it a by-name call because
# `Hash#<` is Ruby over `all?`, `key?` and `==`).
class CodeGen
  CORE_COMPILED_HASH_CMP = %w[< <= > >=].freeze

  # { simple owner => [definitions] } of the core-source methods this run compiles under `name`, hidden
  # ones and aliases included. Never read by the registry-keyed proofs.
  def core_compiled_definers(name)
    @core_compiled_by_name ||= begin
      index = {}
      block_core_index.each do |(owner, method_name), defs|
        ((index[method_name] ||= {})[owner.split('::').last] ||= []).concat(defs)
      end
      index
    end
    @core_compiled_by_name.fetch(name, {})
  end

  # BC2CPP_CORE_COMPILED_CMP=0 keeps the by-name Hash arm.
  def core_compiled_cmp_enabled?
    ENV['BC2CPP_CORE_COMPILED_CMP'] != '0'
  end

  # The compiled `Hash#<op` the helper may call, or nil. Every condition is one the by-name call answers
  # for free: the compiled body must be the one definition Hash's lookup reaches (the chain walk of
  # block_core_target refuses a project definition, a native registration, a prepend, an outside definer
  # or a computed installer), a clean `_impl` this link emits, and provably yield-free (no `==` of a stored
  # value can suspend a Fiber), because a direct call skips the entry's Fiber guard (ADR 0269) and the
  # helper has no block to relax it with (ADR 0283).
  def core_compiled_hash_cmp_target(op)
    return nil unless core_compiled_cmp_enabled? && CORE_COMPILED_HASH_CMP.include?(op)

    @core_compiled_hash_cmp ||= {}
    @core_compiled_hash_cmp.fetch(op) { @core_compiled_hash_cmp[op] = core_compiled_hash_cmp_proof(op) }
  end

  def core_compiled_hash_cmp_proof(op)
    return nil unless @yield_reach && block_core_world && @native_name_sources

    defs = core_compiled_definers(op)['Hash']
    return nil unless defs&.one? && call_facts_answers.foreign_definer?(op, 'Hash')

    target = block_core_target('Hash', %w[Hash Enumerable], op, 1, blockless: true)
    target if target && target.owner == 'Hash' && @yield_reach.yield_free?(target.irep)
  end

  # The Hash arm of a closed comparison helper: the compiled body for an exact Hash, a by-name dispatch (that
  # raises the proof violation if nothing answers) for anything else, or the old by-name call.
  def numeric_slow_hash_cmp_arm(op)
    target = core_compiled_hash_cmp_target(op)
    return "return mrb_funcall(M, a, \"#{op}\", 1, b);" unless target

    "// CORE_COMPILED_HASH_CMP :#{op} -- compiled core body, no by-name call (ADR 0371)\n    " \
      "if (mrb_obj_ptr(a)->c != M->hash_class) return bc2cpp_nomethod_named(M, a, \"#{op}\", 1, b);\n    " \
      "mrb_gc_arena_restore(M, ai);\n    " \
      "return #{cpp_name(target.owner, target.name)}_impl(M, a, b);"
  end
end
