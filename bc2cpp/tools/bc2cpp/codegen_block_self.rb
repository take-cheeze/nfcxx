# frozen_string_literal: true

require 'set'
require_relative 'block_self'
require_relative 'block_self_world'

# CodeGen: BLOCK_SELF.
#
# `self` inside a block is the self of the method that created it unless something runs the block with another
# self: instance_eval/instance_exec, class_eval/class_exec, module_eval/module_exec (mrb_yield_with_class),
# define_method (the block becomes a method body), Class.new/Module.new/Struct.new/Data.define. block_self_owner
# answers the method a block's self is, when every block on the nesting chain from it up to that method is:
#
#   * a literal block argument: the BLOCK that makes it is the instruction right before the SENDB/SSENDB that
#     takes it (plain fixed argc, block register dest + n + 1), so that call is the only code the Proc reaches;
#   * taken by a call whose every possible callee only calls the Proc:
#       - a call whose every callee is a checked block-return declaration (BLOCK_RETURNS,
#         codegen_block_returns.rb: a Ruby plain yielder, or a native whose scan shows mrb_yield/mrb_yield_argv,
#         which keep the Proc's self), such as `RGSS::Profiler.section/frame { }`;
#       - otherwise every definition of the name (the registry's, and the interpreted core bodies the registry
#         drops, CodeGen.block_self_bodies) must be a Ruby body that is a plain yielder, or an attr accessor (which
#         ignores a block); a native refuses. The name must have no definition out of sight: none the closed world
#         cannot place (ClosedWorld#unknown_def?), none in an outside Ruby source the build does not compile. Every
#         method_missing (what a receiver without the name runs, with the block) must be mruby's native one (it
#         raises NoMethodError) or a plain yielder.
#
# The plain-yielder test itself is BlockSelf.plain_yielder_why (block_self.rb). Nothing may read a local by name
# (captured_local_writers_absent?: no binding/eval in the world), and no Ruby `call` may sit on Proc's lookup path.
class CodeGen
  class << self
    # name -> every bytecode MethodDef (interpreted core bodies included); names an uncompiled outside Ruby defines.
    attr_accessor :block_self_bodies, :block_self_unread_names
    # BLOCK_SELF_WORLD: BlockSelfWorld's result for this build's closed world (bc2cpp.rb).
    attr_accessor :block_self_world
  end

  # The build's BlockSelfWorld result. A CodeGen built without one (a unit check) reads its own ireps only: the
  # rebound blocks are still known, and the world fact is refused.
  def block_self_world
    self.class.block_self_world ||
      (@block_self_world_local ||= BlockSelfWorld.analyze(ireps: @ireps, superclass_of: @superclass_of || {},
                                                          refusal: 'no closed-world scan (BLOCK_SELF_WORLD)'))
  end

  # A block a rebinder may run under another self (a literal block at a rebinder site, or nested in one).
  def block_self_rebound?(label)
    block_self_world.rebound.include?(label)
  end

  # Does a compiled block body check, at entry, that it runs under the self it captured? Only where the world
  # fact does not already prove it.
  def block_self_check?
    !block_self_world.holds?
  end

  # [owner MethodDef, nil] when the self of block +label+ is the self of the method that (transitively) creates it,
  # else [nil, why].
  def block_self_owner(label)
    @block_self_owner ||= {}
    @block_self_owner[label] ||= block_self_owner_uncached(label)
  end

  def block_self_owner_uncached(label)
    return [nil, 'a local may be read by name (binding or eval reachable)'] unless captured_local_writers_absent?

    why = block_self_proc_call_why
    return [nil, why] if why

    world = block_self_world.holds?
    cur = label
    loop do
      d = @owner_of[cur]
      return [d, nil] if d
      return [nil, "a rebinder may run block #{cur} under another self (BLOCK_SELF_WORLD)"] if block_self_rebound?(cur)

      parent, creation = numeric_block_parents[cur]
      return [nil, 'no creating BLOCK'] unless parent

      # BLOCK_SELF_WORLD: when the world fact holds, only a rebound block leaves its creator's self.
      unless world
        why = block_self_site_why(parent, creation, cur)
        return [nil, why] if why
      end

      cur = parent.label
    end
  end

  # Why a Ruby `call` might run instead of the native Proc#call, or nil.
  def block_self_proc_call_why
    path = %w[Proc Object Kernel BasicObject]
    path += path.flat_map { |klass| Array(@included_modules[klass]) + Array(@prepended_modules[klass]) }
    return 'Proc, Object or Kernel has an unresolved mixin' if path.any? { |klass| @unknown_mixins.include?(klass) }
    return 'a `call` is defined out of the registry\'s sight' if @closed_world.nil? || @closed_world.unknown_def?('call')

    defs = (@registry['call'] || []) + (self.class.block_self_bodies&.[]('call') || [])
    ruby = defs.find { |d| path.include?(d.owner) }
    ruby && "#{ruby.owner}#call is Ruby"
  end

  # nil when the BLOCK at +creation+ in +parent+ is a literal block argument of a call that only calls it.
  def block_self_site_why(parent, creation, child)
    program = BytecodeIR.for(parent)
    block = program.source_at(creation)
    send = program.source_at(creation + 1)
    where = "#{parent.file}:#{block.lineno}"
    return "the block at #{where} is a lambda" unless block.op == :BLOCK
    unless send && %w[SENDB SSENDB].include?(send.op) && send.plain_fixed_argc? &&
           block.reg.to_i == send.reg.to_i + send.argc.to_i + 1
      return "the block at #{where} is not a literal block argument"
    end
    return nil if block_return_site(parent, creation + 1, send)&.last&.label == child

    block_self_callee_why(send.sym.to_s)
  end

  def block_self_callee_why(name)
    @block_self_callee ||= {}
    return @block_self_callee[name] if @block_self_callee.key?(name)

    @block_self_callee[name] = block_self_callee_uncached(name)
  end

  def block_self_callee_uncached(name)
    return "#{name} is defined out of the registry's sight" if @closed_world.unknown_def?(name)
    return "#{name} has no bytecode table (BLOCK_SELF)" unless (bodies = self.class.block_self_bodies)
    unread = self.class.block_self_unread_names
    return "an outside Ruby source this build does not compile may define #{name}" if unread.nil? || unread.include?(name)

    defs = ((@registry[name] || []) + (bodies[name] || [])).uniq { |d| [d.owner, d.irep] }
    return "nothing defines #{name}" if defs.empty?

    defs.each do |d|
      if d.irep.nil?
        next if d.kind == :ivar_accessor && d.owner != '<native>'

        return "#{d.owner}##{name} is native and not a known plain yielder"
      end
      why = BlockSelf.plain_yielder_why(@ireps[d.irep], @ireps)
      return "#{d.owner}##{name} #{why}" if why
    end
    return 'an outside Ruby source this build does not compile may define method_missing' if unread.include?('method_missing')

    ((@registry['method_missing'] || []) + (bodies['method_missing'] || [])).each do |d|
      next if d.owner == '<native>' && d.irep.nil?
      return "#{d.owner}#method_missing is not a plain yielder" unless d.irep && BlockSelf.plain_yielder_why(@ireps[d.irep], @ireps).nil?
    end
    nil
  end

end
