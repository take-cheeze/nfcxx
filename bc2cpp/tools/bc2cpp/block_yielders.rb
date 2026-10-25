# frozen_string_literal: true

require_relative 'escape_analysis'

# BLOCK_YIELDERS: the one method that yields to a block body, for the BC2CPP_TRACE_TYPES dump (the BLOCK_YIELD rows
# param_trace.rb writes). The trace keys a block body's parameters by the body, not by the method that runs it, so the
# gate needs this join to compare them with the block type the RBS declares for that method.
#
# A body is joined to method M only when every fact below holds; otherwise it carries a reason and is undecided:
#   * the body is the literal block of one SENDB `name` (a BLOCK immediately before it, the region codegen emitted);
#   * that block does not escape its creating frame, and its only use is being handed to `name` (so the body runs only
#     inside the callee's frame, and only where the callee calls it);
#   * `name` has no native definition, and exactly one definition in the world (dispatch on any receiver reaches M),
#     which is a plain `def` (not an alias, module_function copy, define_method body or accessor);
#   * no program method_missing exists (a missing `name` could reach one that yields);
#   * M yields to its block (`yield`) and has no block parameter: its block is only ever called, never kept, passed on,
#     or read from a closure (so M runs the body and nothing else does). A `&blk` parameter, called or not, is refused;
#   * the body takes a plain positional parameter list: no optional, rest, post, keyword or block parameter.
# The row key is the trace key of M (`Owner#name`, or `Owner.singleton#name`), so a body yielded by M is compared only
# with M's own observations. See scripts/bc2cpp/rbs_suggestion_trace_check.rb for the comparison.
module BlockYielders
  Join = Struct.new(:key, :arity, :reason, keyword_init: true)

  module_function

  # { body `_impl` name => Join } for every block body the codegen emitted from a SENDB region. Without an escape world
  # (BC2CPP_ESCAPE_ANALYSIS=0) every body is undecided.
  def table(gen)
    analyzer = gen.escape_analyzer
    gen.proc_fallback_origins.to_h do |impl, regions|
      join = regions.size == 1 ? resolve(regions.first, analyzer) : undecided(:ambiguous_origin)
      [impl, join]
    end
  end

  def undecided(reason)
    Join.new(key: nil, arity: nil, reason: reason)
  end

  def resolve(region, analyzer)
    return undecided(:no_world) unless analyzer&.world
    return undecided(:not_sendb) unless region[:sendb_addr] && region[:block_index] && region[:parent_irep]

    world = analyzer.world
    parent = region[:parent_irep]
    body = region[:block_irep]
    name = region[:name].to_s
    block = EscapeAnalysis.insn_at(parent, region[:block_index])
    return undecided(:not_block_site) unless block.op == :BLOCK && block.addr == region[:block_addr]

    # 1. The block value: created here, handed to `name` and nothing else.
    created = analyzer.creation(parent, region[:block_index])
    return undecided(:block_escapes) if created.escapes?
    return undecided(:block_uses) unless created.uses.size == 1 && created.uses.first.kind == :pass_block &&
                                         created.uses.first.name.to_s == name

    # 2. Dispatch of `name` reaches exactly one definition, and it is compiled Ruby.
    return undecided(:native_name) if world.native_name?(name)

    defs = world.defs_named(name)
    return undecided(:dynamic_name) if defs.nil?
    return undecided(:no_definition) if defs.empty?
    return undecided(:not_unique) unless defs.size == 1

    definition = defs.first
    # A plain `def`: an alias or module_function copy, a define_method body or an accessor runs another body under the
    # same name, whose trace key is not this one.
    return undecided(:core_definition) if definition.core || definition.irep.nil?
    return undecided(:installed_definition) if definition.kind || definition.installer || definition.copy_irep || definition.site
    return undecided(:unnamed_owner) if definition.owner.to_s.start_with?('<')
    return undecided(:method_missing) if user_method_missing?(world)

    # 3. The definition runs the body only by calling its block, and nothing it does can call the body another way.
    yielder = world.ireps[definition.irep]
    return undecided(:yielder_missing) unless yielder

    return undecided(:yielder_block_param) if block_param?(yielder)

    verdict = analyzer.method_block_verdict(yielder)
    return undecided(:yielder_escapes) if verdict.escapes?
    return undecided(:yielder_no_yield) if verdict.uses.empty?
    return undecided(:yielder_passes_block) unless verdict.uses.all? { |use| use.kind == :call }

    # 4. The body's parameters are the yielded arguments one for one.
    shape = plain_arity(body)
    return undecided(:body_shape) unless shape

    Join.new(key: "#{definition.owner}##{name}", arity: shape, reason: :ok)
  end

  # Positional count of a body with no optional, rest, post, keyword or block parameter; nil otherwise.
  def plain_arity(body)
    fields = body.enter ? body.enter.enter_fields.map(&:to_i) : [0] * 7
    return nil unless fields.drop(1).first(6).all?(&:zero?)

    fields[0]
  end

  # A method with an `&blk` parameter (its block field is the register after the positionals, see block_verdict).
  def block_param?(irep)
    fields = irep.enter ? irep.enter.enter_fields.map(&:to_i) : []
    fields.fetch(6, 0).positive?
  end

  # A program (non-core) method_missing could yield a block for a name that resolves to nothing else.
  def user_method_missing?(world)
    defs = world.defs_named('method_missing')
    defs.nil? || defs.any? { |d| !d.core }
  end
end
