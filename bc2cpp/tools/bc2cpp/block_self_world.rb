# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'bytecode_ir_ops'
require_relative 'ir_block_operands'
require_relative 'core_hierarchy_sigs'
require_relative 'lexical_consts'
require_relative 'send_names'

# BLOCK_SELF_WORLD: `self` inside a block is the self of the frame that created it, unless something
# runs the block under another self. mruby has exactly one way to do that, mrb_yield_with_class and its siblings,
# reached only through the rebinders: instance_eval/instance_exec, class_eval/class_exec, module_eval/module_exec
# (vm.c eval_under, object-ext), define_method/define_singleton_method (the block becomes a method body), and `new` on
# Class/Module/Struct and Data.define (class.c, struct.c, data.c class_eval the block). This analysis reads every Ruby
# source of the closed world as bytecode (the compiled ones, and the outside ones bc2cpp.rb compiles for it alone) and
# the outside native sources, and answers two things:
#
#   rebound   the labels of the blocks a rebinder may run under another self: a LITERAL block (the BLOCK/LAMBDA right
#             before the SENDB/SSENDB that takes it) at a rebinder site, and every block nested in it. Such a block
#             never keeps its creator's self, so it is never compiled with a captured self (codegen) and BLOCK_SELF
#             never answers its creator for it. This holds in every world.
#   why       nil when the WORLD FACT holds: no rebinder ever receives a Proc other than such a literal block, so
#             every other block runs under the self it was created with. Else the first reason it does not (a site),
#             and `failures` lists them all. Unknown is a failure.
#
# The fact fails on:
#   * a rebinder send whose block is not a literal block (`&blk`, a stored Proc, a forwarded block register), or that
#     passes a Proc as an argument (define_method(:x, proc));
#   * a computed-name send (send/__send__/public_send) or a Method-object maker (method, instance_method, ...) whose
#     name is not proven, unless it carries no block and at most one argument after the name (no rebinder can then
#     receive a Proc through it). Proven names are Symbol literals, and the `self` of mruby's Symbol#to_proc, which is
#     one of the Symbols the program passes as a block (`&:sym`): every block operand of every send is then a literal
#     block, nil, a block parameter (already a Proc: OP_SENDB converted it) or a Symbol literal. A proven name that is
#     itself a computed-name sender, a Method maker or `to_proc` is not proven;
#   * a rebind name spelled as a Symbol or String literal, aliased, or defined in Ruby;
#   * a String eval (`eval`, or instance_eval/class_eval/module_eval with arguments and no block);
#   * an outside native source, other than the rebinders' own implementations (NATIVE_REBINDER_FILES), that runs a
#     Proc under a self it chooses (mrb_yield_with_class and friends), spells a rebind or computed-send name, or
#     passes a block to a method it names by a variable.
module BlockSelfWorld
  REBIND_NAMES = Set['instance_eval', 'instance_exec', 'class_eval', 'class_exec', 'module_eval', 'module_exec',
                     'define_method', 'define_singleton_method'].freeze
  # `new` with a block on these classes (and their subclasses) runs the block as the new class's body
  # (class.c mrb_class_initialize / mrb_mod_initialize, struct.c mrb_struct_s_def); `Data.define` likewise (data.c).
  FACTORY_SENDS = { 'new' => Set['Class', 'Module', 'Struct'], 'define' => Set['Data'] }.freeze
  NAME_SENDS = Set.new(SendNames::FORWARDING_SENDS).freeze
  # String eval (mruby-eval): code no scan reads, so the fact fails on it.
  STRING_EVALS = Set['eval', 'instance_eval', 'class_eval', 'module_eval'].freeze
  METHOD_MAKERS = Set['method', 'singleton_method', 'instance_method'].freeze
  # Names whose presence among a computed send's names leaves that send's own names unproven.
  INDIRECT_NAMES = (NAME_SENDS | METHOD_MAKERS | Set['to_proc']).freeze
  SENDS = BytecodeIR::Ops::SEND
  # Ops that WRITES_LEADING_REG_OPS lists but that do not write R(a): stores, branches, returns and no-ops.
  LEAD_NOT_WRITTEN = Set[:SETGV, :SETSV, :SETIV, :SETCV, :SETCONST, :SETMCNST, :SETIDX, :JMP, :JMPIF,
                         :JMPNOT, :JMPNIL, :RETURN, :RETURN_BLK, :BREAK, :STOP, :DEBUG, :NOP].freeze
  # The rebinders' own implementations and the VM that runs them: the only natives allowed to run a Proc under a self
  # they choose. vm.c: yield, instance_eval/module_eval (eval_under), send, Proc#call and the top-level run; class.c:
  # Class.new/Module.new and define_method; load.c: runs a loaded irep under the top self (not a block); proc.c: Proc.new;
  # struct.c/data.c: Struct.new/Data.define; eval.c: string eval (a global refusal of its own) and its block form;
  # object-ext/class-ext: instance_exec/class_exec; metaprog.c: define_singleton_method; method.c: Method#call of a
  # define_method body (already a rebinder site); fiber.c: resumes a Fiber's proc under the env's own self.
  NATIVE_REBINDER_FILES = %w[
    3rd/mruby/src/vm.c 3rd/mruby/src/class.c 3rd/mruby/src/load.c 3rd/mruby/src/proc.c
    3rd/mruby/mrbgems/mruby-struct/src/struct.c 3rd/mruby/mrbgems/mruby-data/src/data.c
    3rd/mruby/mrbgems/mruby-eval/src/eval.c 3rd/mruby/mrbgems/mruby-object-ext/src/object.c
    3rd/mruby/mrbgems/mruby-class-ext/src/class.c 3rd/mruby/mrbgems/mruby-metaprog/src/metaprog.c
    3rd/mruby/mrbgems/mruby-method/src/method.c 3rd/mruby/mrbgems/mruby-fiber/src/fiber.c
  ].freeze
  # Symbol#to_proc's native body: it passes the block it is called with to the Symbol it closes over (a computed
  # name), exactly the send symbol.rb used to make. It is held to the same proof, computed_send's, instead of the
  # blanket native rule: the Symbols are the ones the program passes as blocks, and none may be a rebinder.
  NATIVE_SYMBOL_PROC_FILE = '3rd/mruby/src/symbol.c'.freeze
  # Hash#to_proc's native body spells `to_proc` once, as the name it registers (a definition, not a send), and sends a
  # fixed `[]` to its Hash: no computed name and no block. That one registration line is cut before the native scan, so
  # the rest of the file is held to the blanket rule.
  NATIVE_HASH_PROC_FILE = '3rd/mruby/mrbgems/mruby-hash-ext/src/hash_ext.c'.freeze
  NATIVE_HASH_PROC_ENTRY = /MRB_MT_ENTRY\(hash_to_proc,\s*MRB_SYM\(to_proc\),\s*MRB_ARGS_NONE\(\)\)/
  # mruby's API headers declare these functions; a declaration runs nothing.
  NATIVE_DECLARATION_DIRS = %w[3rd/mruby/include/].freeze
  NATIVE_SELF_RUNNERS = /\bmrb_(?:yield_with_class|yield_cont|obj_instance_eval|mod_module_eval|exec_irep|vm_run|vm_exec|top_run)\b/
  NATIVE_NAMED = (REBIND_NAMES | NAME_SENDS | METHOD_MAKERS | Set['to_proc']).to_a.join('|')
  NATIVE_NAME_SPELLING = /"(?:#{NATIVE_NAMED})"|\bMRB_Q?SYM\((?:#{NATIVE_NAMED})\)/
  NATIVE_COMPUTED_BLOCK_CALL = /\bmrb_funcall_with_block\s*\(\s*\w+\s*,[^,;]+,\s*+(?!MRB_Q?SYM\()/

  Result = Struct.new(:why, :failures, :rebound, :sites, keyword_init: true) do
    def holds?
      why.nil?
    end
  end

  module_function

  # +ireps+: label => Irep of every compiled Ruby source (REBOUND labels are theirs); +outside_ireps+: label => Irep
  # of the outside Ruby sources compiled for this analysis only; +native_paths+: every outside native source;
  # +method_labels+: label => [owner, name] of every bytecode method body; +superclass_of+: class => superclass;
  # +root+: the repository root NATIVE_REBINDER_FILES are relative to; +refusal+: a reason the caller already knows
  # the world cannot be read (an outside Ruby source mrbc rejected).
  def analyze(ireps:, outside_ireps: {}, native_paths: [], method_labels: {}, superclass_of: {}, root: nil, refusal: nil)
    World.new(ireps, outside_ireps, native_paths, method_labels, superclass_of, root).result(refusal)
  end

  # Is the send at +idx+ given exactly one literal block or lambda (IR_BLOCK_OPERANDS)? Its irep label, or nil.
  def literal_block_label(irep, idx)
    IrBlockOperands.literal_block_label(irep, idx)
  end

  # The register a SENDB/SSENDB reads its block from (vm.c OP_SENDB: R(a + argc + kwargs + 1), a packed `*` argument
  # list and a packed `**` hash taking one register each).
  def block_register(insn)
    IrBlockOperands.block_register(insn)
  end

  # Every literal block the send at +idx+ may be given, or nil when its operand may be anything else.
  def literal_block_labels(irep, idx)
    IrBlockOperands.literal_block_labels(irep, idx)
  end

  # Reaching definitions with the irep's nested SETUPVAR writes counted (BytecodeIR.reaching_definitions).
  def definitions(irep, idx, reg, **options)
    BytecodeIR.reaching_definitions(irep, idx, reg, through_handlers: true, **options)
  end

  class World
    def initialize(ireps, outside_ireps, native_paths, method_labels, superclass_of, root)
      @ireps = ireps
      @outside = outside_ireps
      @native_paths = native_paths
      @method_labels = method_labels
      @superclass_of = superclass_of
      @root = root
      @failures = []
      @rebound = Set.new
      @sites = []
    end

    def result(refusal)
      @failures << refusal if refusal
      [[@ireps, true], [@outside, false]].each do |ireps, compiled|
        parents = parent_map(ireps)
        ireps.each_value { |irep| scan_irep(irep, ireps, parents, compiled) }
      end
      scan_natives
      rescan_scoped_writes
      Result.new(why: @failures.first, failures: @failures.uniq.freeze, rebound: @rebound.freeze, sites: @sites.freeze)
    end

    private

    def parent_map(ireps)
      parents = {}
      ireps.each_value { |irep| Array(irep.reps).each { |child| parents[child] = irep } }
      parents
    end

    def where(irep, insn)
      "#{relative(irep.file)}:#{insn.respond_to?(:lineno) ? insn.lineno : '?'}"
    end

    def relative(path)
      @root && path.to_s.start_with?("#{@root}/") ? path.to_s.delete_prefix("#{@root}/") : path.to_s
    end

    def fail!(irep, insn, reason)
      @failures << "#{where(irep, insn)}: #{reason}"
    end

    def scan_irep(irep, ireps, parents, compiled)
      irep.each_with_op(:LOADSYM, :STRING, :ALIAS, :DEF, :TDEF, :SDEF, *SENDS) do |insn, idx|
        case insn.op
        when :LOADSYM
          fail!(irep, insn, "spells the rebinder :#{insn.sym}") if REBIND_NAMES.include?(insn.sym)
        when :STRING
          entry = irep.pool[insn.pool_index.to_i]
          fail!(irep, insn, "spells the rebinder \"#{entry}\"") if entry.is_a?(String) && REBIND_NAMES.include?(entry)
        when :ALIAS
          names = insn.typed.map { |operand| operand.value.to_s }
          fail!(irep, insn, "aliases the rebinder #{names.join(' ')}") if names.any? { |n| REBIND_NAMES.include?(n) }
        when :DEF, :TDEF, :SDEF
          name = insn.op == :DEF ? insn.sym_token : insn.sym
          fail!(irep, insn, "defines the rebinder #{name} in Ruby") if REBIND_NAMES.include?(name)
        when SENDS
          scan_send(irep, idx, insn, ireps, parents, compiled)
        end
      end
    end

    def scan_send(irep, idx, insn, ireps, parents, compiled)
      name = insn.sym
      if STRING_EVALS.include?(name) && !BytecodeIR::Ops::BLOCK_SEND.include?(insn.op) && (name == 'eval' || insn.argc != 0)
        return fail!(irep, insn, "evaluates a String with #{name} (code this analysis cannot read)")
      end
      @scoped_write_used = false
      kind = if REBIND_NAMES.include?(name) then [:rebinder, name]
             elsif FACTORY_SENDS.key?(name) then factory_send?(irep, idx, insn) ? [:rebinder, name] : nil
             elsif NAME_SENDS.include?(name) || METHOD_MAKERS.include?(name) then computed_send(irep, idx, insn, ireps, parents)
             end
      # SCOPED_CONSTANT_WRITES: kept to be scanned again without the lenient proof (rescan_scoped_writes).
      (@scoped_write_sends ||= []) << [irep, idx, insn, ireps, parents, compiled] if @scoped_write_used
      return unless kind

      what, detail = kind
      if METHOD_MAKERS.include?(name)
        fail!(irep, insn, "makes a Method object of #{detail}") if what != :plain
        return
      end
      return if what == :plain

      block = BytecodeIR::Ops::BLOCK_SEND.include?(insn.op)
      labels = block && BlockSelfWorld.literal_block_labels(irep, idx)
      if labels
        if compiled
          labels.each do |label|
            @sites << [irep.label, idx, name, label]
            mark_rebound(label, ireps)
          end
        end
      elsif block && !nil_block?(irep, idx, insn)
        fail!(irep, insn, "passes a block that is not a literal block to #{detail}")
      elsif proc_argument_possible?(insn, name)
        fail!(irep, insn, "may pass a Proc argument to #{detail}")
      end
    end

    # define_method/define_singleton_method take the method body as a Proc argument too; a computed send with two or
    # more arguments after the name (or a splat) may be such a call.
    def proc_argument_possible?(insn, name)
      computed = NAME_SENDS.include?(name)
      definer = %w[define_method define_singleton_method].include?(name)
      return false unless computed || definer

      argc = insn.argc
      after_name = argc && (computed ? argc - 1 : argc)
      after_name.nil? || after_name >= 2
    end

    def nil_block?(irep, idx, insn)
      reg = BlockSelfWorld.block_register(insn)
      defs = reg && BlockSelfWorld.definitions(irep, idx, reg)
      defs && !defs.empty? && defs.all? { |df| !df.entry? && BytecodeIR.for(irep).source_at(df.index).op == :LOADNIL }
    end

    def mark_rebound(label, ireps)
      return if @rebound.include?(label)

      @rebound << label
      Array(ireps[label]&.reps).each { |child| mark_rebound(child, ireps) }
    end

    # `new`/`define` on a receiver that may be a class factory: anything but a constant naming a class known not to
    # derive from Class/Module/Struct/Data (by its declaration or sig/bc2cpp/declarations.rbs#core_hierarchy) and never assigned.
    # +name+ is the factory name: the send's own, or the one a computed send (`Fiber.send(:new) { }`) forwards to.
    def factory_send?(irep, idx, insn, name = insn.sym)
      # Only SEND-family ops reach here (scan_irep dispatches on SENDS), so SELF_SEND is the SS-prefixed ones.
      return true if BytecodeIR::Ops::SELF_SEND.include?(insn.op)

      factories = FACTORY_SENDS.fetch(name)
      const = IrBlockOperands.constant_name(irep, idx, insn.reg)
      return true unless const

      simple = const.split('::').last
      if assigned_constants.include?(simple)
        return true if @scoped_writes_off || assignment_may_reach?(irep, idx, insn.reg, simple)

        @scoped_write_used = true
      end

      chain = ancestors(simple)
      chain.nil? || chain.any? { |klass| factories.include?(klass) || FACTORY_SENDS.values.any? { |set| set.include?(klass) } }
    end

    # SCOPED_CONSTANT_WRITES: may one of the Ruby writes of the constant +simple+ be what the receiver read at +idx+
    # (register +reg+) finds? assigned_constants matches by simple name, so `RBS::BuiltinNames::Hash = ...` (rbs's
    # mrblib) would make every `Hash.new { }` a possible factory and its block rebound. A bare read (every writer of
    # +reg+ a GETCONST) is resolved by mruby's vm.c mrb_vm_const_get: the body's own class, then the classes of the
    # lexically enclosing bodies (the proc->upper chain), then const_get on the innermost class: its ancestors, then
    # Object. A write in scope S binds S::simple, so it can only be found when S is on the read's lexical chain
    # (LexicalConsts.chain_of, which ends at the top level, Object's table), is Object, or may be an ancestor of the
    # reading class (ancestor_scope?; mruby reaches the top level's Object before any ancestor, which this does not use).
    # Anything not proven keeps the old answer (true): a scoped read (`A::Hash`), a
    # read whose body's scope is unknown (a compact `class A::B`, `class << x`), a write in an unknown scope (SETMCNST,
    # or below such a body), or a world read without its native sources (a unit check).
    def assignment_may_reach?(irep, idx, reg, simple)
      return true if @native_paths.empty?
      return true unless IrBlockOperands.all_writers?(irep, idx, reg) { |w| w.op == :GETCONST }

      read_scope = scope_of(irep)
      return true if read_scope == :unknown

      chain = LexicalConsts.chain_of(read_scope)
      constant_write_scopes.fetch(simple, [:unknown]).any? do |scope|
        scope == :unknown || scope == 'Object' || chain.include?(scope) || ancestor_scope?(scope)
      end
    end

    # The lexical scope (LexicalConsts::Model) of a body of either Ruby set, or :unknown. The two sets are compiled
    # apart, so their labels may coincide: the set is picked by identity.
    def scope_of(irep)
      ireps = @ireps[irep.label].equal?(irep) ? @ireps : (@outside[irep.label].equal?(irep) ? @outside : nil)
      return :unknown unless ireps

      @scope_models ||= {}.compare_by_identity
      model = (@scope_models[ireps] ||= LexicalConsts::Model.new(ireps, scopes_only: true))
      model.scope_of(irep.label)
    end

    # simple name => the scopes its SETCONST writes sit in (:unknown for a SETMCNST, `A::K = v`).
    def constant_write_scopes
      @constant_write_scopes ||= begin
        out = Hash.new { |h, k| h[k] = Set.new }
        [@ireps, @outside].each do |ireps|
          ireps.each_value do |irep|
            irep.each_with_op(:SETCONST, :SETMCNST) do |insn, _|
              next unless insn.const_name

              out[insn.const_name.to_s.split('::').last] << (insn.op == :SETCONST ? scope_of(irep) : :unknown)
            end
          end
        end
        out.default_proc = nil
        out
      end
    end

    # Can the body +scope+ be an ancestor of the class a constant read starts from? A class always may be (a `class`
    # statement's superclass, `Class.new(sup)`, ...). A module only through a mixin: a Ruby mixin call (mixin_names), or a
    # native source that names it (mrb_include_module of a module it looks up). Matched by the last segment of the name.
    # mruby's Kernel, Comparable and Enumerable are mixed in natively, and their names are spelled there.
    def ancestor_scope?(scope)
      return true if scope == LexicalConsts::TOP

      last = scope.split('::').last
      return true if class_statement_names.include?(last)

      mixins = mixin_names
      mixins.nil? || mixins.include?(last) || native_spelled?(last)
    end

    # The sends that make a module an ancestor (the hooks include/prepend/extend call are public too).
    MIXIN_SENDS = Set['include', 'prepend', 'extend', 'append_features', 'prepend_features', 'extend_object'].freeze

    # Simple names of every module Ruby code may mix in, or nil when one is not proven. A mixin call is a send of a
    # MIXIN_SENDS name, or a SUPER in a method of such a name; each argument must be a constant, or (in a method of such a
    # name, the forwarder mruby-toplevel-ext's `def include(*modules) = Object.include(*modules)` is) one of that
    # method's own parameters or its zsuper list, which only a mixin call passes it. A mixin name must not be the old name
    # of an ALIAS or an alias_method, or a name a computed-name send (send/__send__/public_send, a Method maker,
    # Symbol#to_proc) is proven to send. A computed send whose names are NOT proven already fails the world fact
    # (scan_send), and a compiled block then checks its self at entry (bc2cpp_block_self_check), as for every other
    # unproven rebinding.
    #
    # That proof is lenient about one thing the world fact does not refuse: an alias_method whose old name it cannot
    # prove. It is skipped here and recorded in @mixin_alias_unproven, which rescan_scoped_writes reads.
    def mixin_names
      return @mixin_names if defined?(@mixin_names)

      # WORLD_SCAN_CACHE: a whole-world pass over the same sources as every other scan here, so ScanCache keeps it.
      # The unproven-alias flag it leaves behind is part of the value.
      names, unproven = cached_world_scan('mixin_names') do
        @mixin_alias_unproven = false
        names = compute_mixin_names
        [names, @mixin_alias_unproven]
      end
      @mixin_alias_unproven = unproven
      @mixin_names = names
    end

    # The value of a whole-world scan +name+, kept by ScanCache under the Ruby sources and native sources this world
    # reads and the environment the scan may read (a source it cannot key is computed, not stored). The block's value
    # must be Marshal-able data.
    def cached_world_scan(name, &block)
      sources = (@ireps.values + @outside.values).map { |irep| irep.file.to_s }
      inputs = (sources + @native_paths.map(&:to_s)).map { |path| File.expand_path(path) }.uniq.sort
      # The reaching-definitions (bytecode_ir_dataflow.rb) reads these IR switches: their values are keyed. Named one by
      # one, since a prefix entry would list the whole environment, which a scan may not do.
      ScanCache.fetch("block_self_world.#{name}", inputs, cache_absent: false,
                      env: %w[BC2CPP_IR_QUERY_KEYS BC2CPP_IR_SHARED_DEFINITIONS BC2CPP_IR_SCALAR_SEEN
                              BC2CPP_IR_DENSE_SEEN], &block)
    end

    # SCOPED_CONSTANT_WRITES: the world fact is now known. When it holds, no compiled block checks its self at entry,
    # so the lenient mixin proof is not enough: if an alias_method it skipped is in the world, every send the refinement
    # answered (recorded by scan_send) is scanned again with the old answer, as a factory send.
    def rescan_scoped_writes
      return if @scoped_write_sends.nil? || !@failures.empty? || !@mixin_alias_unproven

      @scoped_writes_off = true
      @scoped_write_sends.each { |args| scan_send(*args) }
    end

    def compute_mixin_names
      out = Set.new
      symbols = symbol_block_names
      return nil if symbols != :unknown && symbols.intersect?(MIXIN_SENDS)

      [@ireps, @outside].each do |ireps|
        parents = nil
        def_names = method_def_names(ireps)
        ireps.each_value do |irep|
          forwarder = MIXIN_SENDS.include?(def_names[irep.label])
          irep.each_with_op(:ALIAS, :SUPER, *SENDS) do |insn, idx|
            parents ||= parent_map(ireps) if insn.op == :SUPER
            name = insn.sym
            if insn.op == :ALIAS
              # OP_ALIAS a b: the new name a for the method b. Only an old name that is a mixin passes one on.
              return nil if MIXIN_SENDS.include?(insn.typed[1]&.value.to_s)
            elsif insn.op == :SUPER
              # A SUPER in a block calls the super method of the method the block is in.
              next unless MIXIN_SENDS.include?(enclosing_def_name(irep, def_names, parents))
              return nil unless mixin_arguments(irep, idx, insn, forwarder, out)
            elsif MIXIN_SENDS.include?(name)
              return nil unless mixin_arguments(irep, idx, insn, forwarder, out)
            elsif name == 'alias_method'
              parents ||= parent_map(ireps)
              old = insn.reg && insn.argc == 2 && !insn.positional_splat? ? names_at(irep, idx, insn.reg + 2, ireps, parents) : :unknown
              if old == :unknown
                @mixin_alias_unproven = true
              elsif old.intersect?(MIXIN_SENDS)
                return nil
              end
            elsif NAME_SENDS.include?(name) || METHOD_MAKERS.include?(name)
              parents ||= parent_map(ireps)
              names = name_operand(irep, idx, insn, ireps, parents)
              # Unproven (or forwarded again): the world fact fails on this send, see above.
              next if names == :unknown || names.intersect?(INDIRECT_NAMES)
              return nil if names.intersect?(MIXIN_SENDS) || names.include?('alias_method')
            end
          end
        end
      end
      out
    end

    # Adds the simple names of the constants a mixin call at +idx+ passes to +out+; false when an argument is neither a
    # constant nor (+forwarder+: the call sits in a method of a mixin name) the method's own parameter or zsuper list.
    def mixin_arguments(irep, idx, insn, forwarder, out)
      return false unless insn.reg

      regs = insn.positional_splat? || insn.argc.nil? ? [insn.reg + 1] : (1..insn.argc).map { |k| insn.reg + k }
      regs.all? do |reg|
        const = !insn.positional_splat? && IrBlockOperands.constant_name(irep, idx, reg)
        if const
          out << const.split('::').last
          true
        else
          forwarder && forwarded_parameters?(irep, idx, reg)
        end
      end
    end

    # Does +reg+ at +idx+ hold only the method's own parameters: an entry value, the zsuper list (ARGARY), or an Array
    # packed from those (`f(*a)` is LOADNIL, MOVE, ARYCAT; vm.c OP_ARYCAT/OP_ARYPUSH append R(b) to R(a) in place)?
    def forwarded_parameters?(irep, idx, reg, depth = 0)
      return false if depth > 8

      defs = BlockSelfWorld.definitions(irep, idx, reg)
      return false if defs.nil? || defs.empty?

      defs.all? do |df|
        next true if df.entry?

        w = BytecodeIR.for(irep).source_at(df.index)
        case w.op
        when :ARGARY, :LOADNIL then true
        when :ARYCAT, :ARYPUSH
          w.regs.size == 2 && forwarded_parameters?(irep, df.index, w.regs[0], depth + 1) &&
            forwarded_parameters?(irep, df.index, w.regs[1], depth + 1)
        else false
        end
      end
    end

    # The `def` name of the method +irep+ is (or, for a block, sits in), or nil.
    def enclosing_def_name(irep, def_names, parents)
      label = irep.label
      until def_names.key?(label)
        parent = parents[label]
        return nil unless parent

        label = parent.label
      end
      def_names[label]
    end

    # label => the name its `def` gives each method body of +ireps+ (TDEF/SDEF, or METHOD then DEF).
    def method_def_names(ireps)
      @method_def_names ||= {}.compare_by_identity
      @method_def_names[ireps] ||= ireps.each_value.with_object({}) do |irep, out|
        program = BytecodeIR.for(irep)
        irep.each_with_op(:TDEF, :SDEF, :DEF) do |insn, idx|
          if insn.op == :DEF
            at = idx.positive? ? irep.previous_real_index(idx - 1) : -1
            method = at >= 0 ? program.source_at(at) : nil
            next unless method&.op == :METHOD && method.reg == insn.paren_reg

            out[irep.reps[method.block_index]] = insn.sym
          else
            out[irep.reps[insn.block_index]] = insn.sym
          end
        end
      end
    end

    # Simple names a `class` statement opens.
    def class_statement_names
      @class_statement_names ||= (@ireps.values + @outside.values).each_with_object(Set.new) do |irep, out|
        irep.each_with_op(:CLASS) { |insn, _| out << insn.sym.split('::').last if insn.sym }
      end
    end

    # Does a native source of the world spell +name+ (it may look the module up and mix it in)?
    def native_spelled?(name)
      @native_spelled ||= {}
      return @native_spelled[name] if @native_spelled.key?(name)

      pattern = /\b#{Regexp.escape(name)}\b/
      @native_spelled[name] = @native_paths.any? do |path|
        File.file?(path) ? File.read(path, encoding: 'BINARY').match?(pattern) : true
      end
    end

    # Simple names a SETCONST assigns anywhere (`K = Class` is not a class declaration).
    def assigned_constants
      @assigned_constants ||= (@ireps.values + @outside.values).each_with_object(Set.new) do |irep, out|
        irep.each_with_op(:SETCONST, :SETMCNST) do |insn, _|
          out << insn.const_name.to_s.split('::').last if insn.const_name
        end
      end
    end

    # Simple class names along the superclass chain of every class +simple+ names, or nil when a link is unknown.
    # The links come from every `class` statement of the world's Ruby (CLASS's superclass operand: nil is Object, a
    # constant its last segment, anything else unknown), the registry's superclass_of, and, for classes mruby
    # defines natively, sig/bc2cpp/declarations.rbs#core_hierarchy. Classes are matched by their last name segment, so two
    # same-named classes contribute both chains.
    def ancestors(simple)
      out = []
      seen = Set.new
      queue = [simple]
      until queue.empty?
        name = queue.shift
        next unless seen.add?(name)

        out << name
        next if name == 'BasicObject'

        supers = superclass_links[name]
        return nil if supers.nil? || supers.empty? || supers.include?(:unknown)

        queue.concat(supers.to_a)
      end
      out
    end

    # simple class name => Set of simple superclass names (:unknown for an unresolved one).
    def superclass_links
      @superclass_links ||= begin
        links = Hash.new { |h, k| h[k] = Set.new }
        core_super, = CoreHierarchySigs.hierarchy
        core_super.each { |name, sup| links[name.split('::').last] << sup.split('::').last if sup }
        @superclass_of.each do |name, sup|
          links[name.split('::').last] << (sup == :none ? 'Object' : sup.to_s.split('::').last)
        end
        (@ireps.values + @outside.values).each do |irep|
          irep.each_with_op(:CLASS) do |insn, idx|
            next unless insn.reg && insn.sym

            links[insn.sym.split('::').last] << class_statement_super(irep, idx, insn)
          end
        end
        links.default_proc = nil
        links
      end
    end

    # The superclass operand every reaching definition agrees on, else :unknown.
    def class_statement_super(irep, idx, insn)
      defs = BlockSelfWorld.definitions(irep, idx, (insn.reg + 1))
      return :unknown unless defs
      found = defs.map do |df|
        next :unknown if df.entry?

        writer = BytecodeIR.for(irep).source_at(df.index)
        case writer.op
        when :LOADNIL then 'Object'
        when :GETCONST, :GETMCNST then writer.const_name.to_s.split('::').last
        else :unknown
        end
      end.uniq
      found.size == 1 && found.first.is_a?(String) && !found.first.empty? ? found.first : :unknown
    end

    # [:plain] when the names a computed-name send or Method maker can reach are proven and none is a rebinder,
    # [:rebinder, detail] otherwise.
    def computed_send(irep, idx, insn, ireps, parents)
      names = name_operand(irep, idx, insn, ireps, parents)
      return [:rebinder, "#{insn.sym} with a name it cannot prove"] if names == :unknown
      return [:rebinder, "#{insn.sym} with a name it cannot prove (#{(names & INDIRECT_NAMES).to_a.sort.join(', ')})"] if names.intersect?(INDIRECT_NAMES)

      hit = names.select { |n| REBIND_NAMES.include?(n) || (FACTORY_SENDS.key?(n) && factory_send?(irep, idx, insn, n)) }
      hit.empty? ? [:plain] : [:rebinder, "#{insn.sym}(:#{hit.sort.join(', :')})"]
    end

    # The names the first argument of +insn+ can hold: a Set, or :unknown.
    def name_operand(irep, idx, insn, ireps, parents)
      return :unknown unless insn.reg

      reg = (insn.reg + 1)
      return names_at(irep, idx, reg, ireps, parents) if insn.argc&.positive?
      return :unknown unless insn.positional_splat?

      packed_first_names(irep, idx, reg, ireps, parents)
    end

    # The first element of the Array a `*` call packs its positional arguments into (vm.c OP_ARRAY R(a) n: R(a) =
    # [R(a)..R(a+n-1)]; OP_ARRAY2 R(a) R(b) n, decoded as ARRAY with two registers: R(a) = [R(b)..]; OP_ARYCAT and
    # OP_ARYPUSH append to R(a) in place).
    def packed_first_names(irep, idx, reg, ireps, parents)
      defs = BlockSelfWorld.definitions(irep, idx, reg, follow_moves: false)
      return :unknown if defs.nil? || defs.empty?

      defs.each_with_object(Set.new) do |df, out|
        return :unknown if df.entry?

        w = BytecodeIR.for(irep).source_at(df.index)
        count = w.typed.find { |operand| operand.kind == :int }&.value.to_i
        source = w.regs.size >= 2 ? w.regs[1] : reg
        found = case w.op
                when :ARYCAT, :ARYPUSH then packed_first_names(irep, df.index, reg, ireps, parents)
                when :ARRAY then count.positive? ? names_at(irep, df.index, source, ireps, parents) : :unknown
                else :unknown
                end
        return :unknown if found == :unknown

        out.merge(found)
      end
    end

    def names_at(irep, idx, reg, ireps, parents)
      defs = BlockSelfWorld.definitions(irep, idx, reg)
      return :unknown if defs.nil? || defs.empty?

      defs.each_with_object(Set.new) do |df, out|
        found = df.entry? ? entry_names(irep, df.reg, ireps) : writer_names(irep, df.index, ireps, parents)
        return :unknown if found == :unknown

        out.merge(found)
      end
    end

    def writer_names(irep, index, ireps, parents)
      insn = BytecodeIR.for(irep).source_at(index)
      case insn.op
      when :LOADSYM then Set[insn.sym]
      when :LOADSELF then entry_names(irep, 0, ireps)
      when :LOADNIL, :LOADTRUE, :LOADFALSE then Set.new
      when :GETUPVAR then upvar_names(irep, insn, ireps, parents)
      else :unknown
      end
    end

    # `self` of mruby's Symbol#to_proc is a Symbol the program passed as a block; nothing else is known at entry.
    def entry_names(irep, reg, _ireps)
      return :unknown unless reg == 0 && @method_labels[irep.label] == %w[Symbol to_proc]

      symbol_block_names
    end

    # A captured local: every value its frame (or any block inside it) writes into it.
    def upvar_names(irep, insn, ireps, parents)
      index, level = insn.upvar_ref
      return :unknown unless index

      frame = irep
      (level + 1).times { frame = frame && parents[frame.label] }
      return :unknown unless frame
      return :unknown if setupvar_target?(frame, index, ireps)

      out = Set.new
      BytecodeIR.for(frame).each_source do |w, j|
        next unless w.reg == index && writes_leading?(w)

        found = w.op == :MOVE ? names_at(frame, j, w.regs[1], ireps, parents) : writer_names(frame, j, ireps, parents)
        return :unknown if found == :unknown

        out.merge(found)
      end
      out
    end

    def writes_leading?(insn)
      BytecodeIR::WRITES_LEADING_REG_OPS.include?(insn.op) && !LEAD_NOT_WRITTEN.include?(insn.op)
    end

    # Does a block nested (at any depth) in +frame+ store into its local +index+?
    def setupvar_target?(frame, index, _ireps)
      BytecodeIR.own_upvar_written_regs(frame).include?(index)
    end

    # Every Symbol a block operand can be, which OP_SENDB turns into a Proc through Symbol#to_proc; :unknown when a
    # block operand is something other than a literal block, nil, a block parameter or a Symbol literal, or when
    # `to_proc` is sent by name anywhere (its receiver could be any Symbol).
    def symbol_block_names
      return @symbol_block_names if defined?(@symbol_block_names)

      @symbol_block_names = cached_world_scan('symbol_block_names') { compute_symbol_block_names }
    end

    def compute_symbol_block_names
      out = Set.new
      [@ireps, @outside].each do |ireps|
        parents = parent_map(ireps)
        ireps.each_value do |irep|
          irep.each_with_op(*SENDS) do |insn, idx|
            return :unknown if insn.sym == 'to_proc'
            next unless BytecodeIR::Ops::BLOCK_SEND.include?(insn.op)
            next if BlockSelfWorld.literal_block_label(irep, idx)

            found = block_operand_symbols(irep, idx, insn, ireps, parents)
            return :unknown if found == :unknown

            out.merge(found)
          end
        end
      end
      out
    end

    def block_operand_symbols(irep, idx, insn, ireps, parents)
      reg = BlockSelfWorld.block_register(insn)
      defs = reg && BlockSelfWorld.definitions(irep, idx, reg)
      return :unknown if defs.nil? || defs.empty?

      defs.each_with_object(Set.new) do |df, out|
        if df.entry?
          return :unknown unless df.reg == block_param_register(irep)

          next
        end
        w = BytecodeIR.for(irep).source_at(df.index)
        case w.op
        when :LOADSYM then out << w.sym
        when :LOADNIL, :BLOCK, :LAMBDA then next
        when :GETUPVAR then return :unknown unless captured_block_param?(irep, w, ireps, parents)
        else return :unknown
        end
      end
    end

    # The register ENTER puts the block in (1 + required + optional + rest + post + the keyword dict).
    def block_param_register(irep)
      fields = irep.enter&.enter_fields
      return nil unless fields

      req, opt, rest, post, key, kdict = fields.first(6).map(&:to_i)
      1 + req + opt + rest + post + (key.positive? || kdict.positive? ? 1 : 0)
    end

    # A GETUPVAR of an enclosing frame's local that only ever holds that frame's block (mrbc copies a named `&block`
    # into a local: `MOVE R3 R2`), a literal block or nil, and no nested block stores into.
    def captured_block_param?(irep, insn, ireps, parents)
      index, level = insn.upvar_ref
      frame = irep
      (level + 1).times { frame = frame && parents[frame.label] }
      return false unless frame && index
      return false if setupvar_target?(frame, index, ireps)

      writers = BytecodeIR.for(frame).each_source.select { |w, _| w.reg == index && writes_leading?(w) }
      !writers.empty? && writers.all? do |w, j|
        case w.op
        when :LOADNIL, :BLOCK, :LAMBDA then true
        when :MOVE
          defs = BlockSelfWorld.definitions(frame, j, w.regs[1])
          defs && !defs.empty? && defs.all? { |df| df.entry? && df.reg == block_param_register(frame) }
        else false
        end
      end
    end

    # The native Symbol#to_proc sends each Symbol the program passes as a block (symbol_block_names) to its first
    # argument with the call's block; that is a computed-name send, proven when no such Symbol is a rebinder.
    def scan_symbol_proc_native
      names = symbol_block_names
      if names == :unknown
        @failures << "#{NATIVE_SYMBOL_PROC_FILE}: Symbol#to_proc sends a name it cannot prove"
      elsif (bad = names & (INDIRECT_NAMES | REBIND_NAMES | FACTORY_SENDS.keys)).any?
        @failures << "#{NATIVE_SYMBOL_PROC_FILE}: Symbol#to_proc sends a rebinder or computed-name sender (:#{bad.to_a.sort.join(', :')})"
      end
    end

    def scan_natives
      @native_paths.each do |path|
        rel = relative(File.expand_path(path))
        next if NATIVE_REBINDER_FILES.include?(rel) || NATIVE_DECLARATION_DIRS.any? { |dir| rel.start_with?(dir) }

        if rel == NATIVE_SYMBOL_PROC_FILE
          scan_symbol_proc_native
          next
        end

        text = File.read(path, encoding: 'BINARY').gsub(%r{/\*.*?\*/}m, '').gsub(%r{//[^\n]*}, '')
        text = text.sub(NATIVE_HASH_PROC_ENTRY, '') if rel == NATIVE_HASH_PROC_FILE
        if (m = text.match(NATIVE_SELF_RUNNERS))
          @failures << "#{rel}: runs a Proc under a self it chooses (#{m[0]})"
        elsif (m = text.match(NATIVE_NAME_SPELLING))
          @failures << "#{rel}: names #{m[0]}, a rebinder or a computed-name sender"
        elsif text.match?(NATIVE_COMPUTED_BLOCK_CALL)
          @failures << "#{rel}: passes a block to a method it names by a variable (mrb_funcall_with_block)"
        end
      end
    end
  end
end
