# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'bytecode_ir_ops'
require_relative 'ir_block_operands'
require_relative 'core_hierarchy_sigs'
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
        when *SENDS
          scan_send(irep, idx, insn, ireps, parents, compiled)
        end
      end
    end

    def scan_send(irep, idx, insn, ireps, parents, compiled)
      name = insn.sym
      if STRING_EVALS.include?(name) && !BytecodeIR::Ops::BLOCK_SEND.include?(insn.op) && (name == 'eval' || insn.argc != 0)
        return fail!(irep, insn, "evaluates a String with #{name} (code this analysis cannot read)")
      end
      kind = if REBIND_NAMES.include?(name) then [:rebinder, name]
             elsif FACTORY_SENDS.key?(name) then factory_send?(irep, idx, insn) ? [:rebinder, name] : nil
             elsif NAME_SENDS.include?(name) || METHOD_MAKERS.include?(name) then computed_send(irep, idx, insn, ireps, parents)
             end
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
    def factory_send?(irep, idx, insn)
      # Only SEND-family ops reach here (scan_irep dispatches on SENDS), so SELF_SEND is the SS-prefixed ones.
      return true if BytecodeIR::Ops::SELF_SEND.include?(insn.op)

      factories = FACTORY_SENDS.fetch(insn.sym)
      const = IrBlockOperands.constant_name(irep, idx, insn.reg)
      return true unless const

      simple = const.split('::').last
      return true if assigned_constants.include?(simple)

      chain = ancestors(simple)
      chain.nil? || chain.any? { |klass| factories.include?(klass) || FACTORY_SENDS.values.any? { |set| set.include?(klass) } }
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
      defs = BlockSelfWorld.definitions(irep, idx, (insn.reg + 1)) or return :unknown
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

      hit = names.select { |n| REBIND_NAMES.include?(n) || FACTORY_SENDS.key?(n) }
      hit.empty? ? [:plain] : [:rebinder, "#{insn.sym}(:#{hit.sort.join(', :')})"]
    end

    # The names the first argument of +insn+ can hold: a Set, or :unknown.
    def name_operand(irep, idx, insn, ireps, parents)
      return :unknown unless insn.reg

      reg = (insn.reg + 1)
      return names_at(irep, idx, reg, ireps, parents) if insn.argc&.positive?
      return :unknown unless insn.n_spec == '*'

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
      BytecodeIR.own_upvar_written_regs(frame).include?(index.to_s)
    end

    # Every Symbol a block operand can be, which OP_SENDB turns into a Proc through Symbol#to_proc; :unknown when a
    # block operand is something other than a literal block, nil, a block parameter or a Symbol literal, or when
    # `to_proc` is sent by name anywhere (its receiver could be any Symbol).
    def symbol_block_names
      return @symbol_block_names if defined?(@symbol_block_names)

      @symbol_block_names = compute_symbol_block_names
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

    def scan_natives
      @native_paths.each do |path|
        rel = relative(File.expand_path(path))
        next if NATIVE_REBINDER_FILES.include?(rel) || NATIVE_DECLARATION_DIRS.any? { |dir| rel.start_with?(dir) }

        text = File.read(path, encoding: 'BINARY').gsub(%r{/\*.*?\*/}m, '').gsub(%r{//[^\n]*}, '')
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
