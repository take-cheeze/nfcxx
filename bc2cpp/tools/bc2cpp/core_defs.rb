# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'scan_cache'

# CORE_DEFS: what decides whether a definition from mruby's own Ruby
# may be compiled and registered over the interpreter's. The registry walks a
# class body as straight-line code; these two facts are where that is false.
module CoreDefs
  # Where mruby's own Ruby lives: core mrblib, every core gem's mrblib, and the
  # external gems that ship Ruby (compiled_gems.rb BC2CPP_EXTERNAL_MRBLIB_GEMS).
  SOURCE = %r{/3rd/(?:mruby/(?:mrblib|mrbgems/[^/]+/mrblib)|mruby-stringio/mrblib|mruby-onig-regexp/mrblib)/}
  # The mruby core's own mrblib: the only Ruby that runs in mrb_init_mrblib, before any gem's C init has defined its
  # classes (a gem's mrblib, e.g. mruby-io's `class File < IO`, runs in the gem init after it).
  INIT_SOURCE = %r{/3rd/mruby/mrblib/}

  module_function

  def core_source?(file)
    file.to_s.match?(SOURCE)
  end

  # Irep labels of the method bodies a later definition of the same owner and
  # name replaces. Definition order is the registry's walk order, which is the
  # source order mrbc was given, i.e. the order the interpreter runs the class
  # bodies. Only a core-source definition is dropped (an engine definition that
  # replaces one is the live method; two engine definitions keep the registry's
  # conservative treatment). The replaced body stays reachable only through an
  # alias, which is interpreted either way.
  def shadowed_labels(registry, ireps)
    out = Set.new
    registry.each_value do |defs|
      defs.select(&:irep).group_by(&:owner).each_value do |same|
        next if same.size < 2

        same[0...-1].each { |d| out << d.irep if core_source?(ireps.fetch(d.irep).file) }
      end
    end
    out
  end

  # CORE_OUTSIDE_REDEFINED: the labels of the core-source definitions in +registry+ that a linked Ruby source this build does
  # not compile defines again on the same owner (mruby-require's Hash#to_h, which takes a block where mruby-hash-ext's
  # returns self). Those sources load after mruby's own Ruby, so the interpreter ends up with their method: the core body
  # may be neither bound nor registered over it (a self build registers after every gem has run). +paths+: the linked
  # Ruby sources (BC2CPP_LINKED_RUBY_SRCS); the ones +ireps+ compiles are left out. Read as bytecode, owner by owner: a
  # text or parse scan is no substitute, since keeping a core body interpreted is not free (an interpreted frame between
  # the steps of a compiled Fiber, Enumerator#next over Enumerator#each, is a C boundary its yield cannot cross), and the
  # parse scan drops a name some file defines outside a class body. The compile is kept (outside_compile) for
  # BlockSelfWorld's read of the same sources.
  # The variables compiling and registering the outside sources may read: mrbc's, the snapshot recorder's, the irep
  # cache's and the IR switches' are all BC2CPP_* or MRBC*; mrbc is found on PATH.
  OUTSIDE_PAIRS_ENV = %w[BC2CPP_* MRBC* PATH].freeze

  def outside_redefined_labels(registry, ireps, paths, symbol, out_dir)
    compiled = ireps.each_value.to_set { |irep| File.expand_path(irep.file.to_s) }
    unread = paths.map { |path| File.expand_path(path) }.uniq.sort.reject { |path| compiled.include?(path) }
    return Set.new if unread.empty?

    # The [owner, name] pairs depend on those sources, the compile's settings and the IR switches alone (OUTSIDE_PAIRS_ENV),
    # so ScanCache keeps them: the compile and the registry over every linked Prism and RBS source were most of this
    # phase. A compile that fails (deterministic for the same sources and settings) is kept as [:refused, why] and
    # reported each run: the block returns rather than raises, as a self-compiled bc2cpp left ScanCache's computing
    # count raised when an exception unwound its scan.
    pairs = ScanCache.fetch('core_defs.outside_pairs', unread, cache_absent: false, env: OUTSIDE_PAIRS_ENV) do
      compiled_outside = begin
        outside_compile(unread, symbol, out_dir)
      rescue ScanCache::Error
        raise
      rescue StandardError => e
        [:refused, e.message.lines.first&.strip]
      end
      if compiled_outside.first == :refused
        compiled_outside
      else
        outside_ireps, outside_root = compiled_outside
        build_registry(outside_ireps.dup, outside_root)[0].values.flatten.to_set { |d| [d.owner, d.name] }
      end
    end
    if pairs.is_a?(Array)
      # As BlockSelfWorld's read of the same sources: one that does not compile is reported, and nothing is learned.
      warn "bc2cpp: CORE_OUTSIDE_REDEFINED: an outside Ruby source does not compile (#{pairs[1]})"
      return Set.new
    end
    registry.values.flatten.select do |d|
      d.irep && pairs.include?([d.owner, d.name]) && core_source?(ireps.fetch(d.irep).file)
    end.to_set(&:irep)
  end

  # The outside Ruby sources +paths+ (sorted, expanded) as [ireps, root], compiled once per list for every reader.
  def outside_compile(paths, symbol, out_dir)
    @outside_compiles ||= {}
    @outside_compiles[paths] ||= compile_ireps(paths, "#{symbol}_block_self_world", out_dir,
                                                                 cache: IrepCache.analysis_directory(paths))
  end

  # CORE_LOOP_ALIASES: the names `%i[sub gsub].each { |v| alias_method v, :"onig_regexp_#{v}" }` installs, when the SENDB at
  # +idx+ of +irep+ is such a loop: `each` over an Array literal of Symbols, whose block aliases to a name its parameter
  # holds (the alias_method's first argument is a MOVE from R1). nil for any other send. The aliases replace whatever
  # method of those names the owner has, which a walk-order registry entry would otherwise stand for.
  def loop_alias_names(irep, idx, ireps)
    program = BytecodeIR.for(irep)
    send = program.source_at(idx)
    return nil unless send&.op == :SENDB && send.sym == 'each' && send.argc.to_i.zero? && idx >= 2

    block = program.source_at(idx - 1)
    literal = program.container_literal(idx - 2)
    return nil unless block&.op == :BLOCK && literal && literal.kind == :array && literal.base == send.reg.to_i

    names = (0...literal.count).map do |k|
      load = program.source_at(idx - 2 - literal.count + k)
      return nil unless load && load.reg.to_i == literal.base + k

      sym = case load.op
            when :LOADSYM then load.sym
            when :SYMBOL then load.pool_index && irep.pool&.[](load.pool_index.to_i)
            end
      return nil unless sym.is_a?(String)

      sym
    end
    child = block.block_index && irep.reps&.[](block.block_index.to_i)
    body = child && ireps[child]
    return nil unless body && loop_param_alias?(body)

    names
  end

  # Does the block +body+ send alias_method with its first parameter (R1) as the new name?
  def loop_param_alias?(body)
    program = BytecodeIR.for(body)
    found = false
    program.each_source do |insn, i|
      next unless insn.op == :SSEND && insn.sym == 'alias_method' && insn.plain_fixed_argc? && insn.argc.to_i == 2

      arg = insn.reg.to_i + 1
      writer = (0...i).reverse_each.lazy.map { |j| program.source_at(j) }.find { |w| w && w.reg.to_i == arg }
      found = true if writer && writer.op == :MOVE && writer.regs.map(&:to_i) == [arg, 1]
    end
    found
  end

  # Irep labels of every def instruction that a conditional forward jump can skip
  # (`def x ... end unless method_defined?(:x)`, a def in an `if` arm). The
  # registry sees the def, but at run time it may not happen, and a registration
  # would then define the method unconditionally.
  def conditional_def_labels(ireps)
    out = Set.new
    ireps.each_value do |irep|
      spans = BytecodeIR.for(irep).instructions_with_op(:JMPIF, :JMPNOT, :JMPNIL, :JMP).filter_map do |insn|
        target = insn.branch_target
        [insn.addr, target] if target && target > insn.addr
      end
      next if spans.empty?

      irep.each_with_op(:TDEF, :SDEF, :DEF) do |insn, index|
        next unless spans.any? { |from, to| from < insn.addr && insn.addr < to }

        label = def_body_label(irep, insn, index)
        out << label if label
      end
    end
    out
  end

  # `alias new old` in a core body, where `old` is the one live definition of its owner and
  # nothing else defines `new` there: [owner, old] => [new, ...]. The interpreter's alias
  # copied the method it replaced, so a compiled `old` is registered under `new` as well
  # (Array#map, #select, Hash#each_pair, ...) and the guard's fallback is `old`'s bytecode.
  def alias_map(sites, registry, ireps, shadowed_pairs)
    defs = registry.values.flatten.group_by { |d| [d.owner, d.name] }
    sites.each_with_object(Hash.new { |h, k| h[k] = [] }) do |site, out|
      next unless core_source?(ireps.fetch(site[:irep]).file)

      old_key = [site[:owner], site[:old]]
      # ALIAS_WALK_TIME: `old` had no definition when the alias ran (a native, or defined later in the source): the copy
      # is the native, which no registry entry stands for, so a later Ruby definition of `old` must not be the copy.
      next unless site[:defined]
      next if site[:new] == site[:old] || shadowed_pairs.include?(old_key)

      old_defs = defs[old_key]
      # `alias filter select` after `alias select find_all`: `select` is itself an alias, so the copy
      # is registered under the def it chains back to (Enumerable#filter).
      root = out.keys.find { |k| k[0] == site[:owner] && out[k].include?(site[:old]) } unless old_defs&.size == 1
      next unless root || (old_defs && old_defs.size == 1 && old_defs.first.irep && old_defs.first.core)
      next if defs.key?([site[:owner], site[:new]])
      next if sites.count { |other| other[:owner] == site[:owner] && other[:new] == site[:new] } > 1

      out[root || old_key] << site[:new]
    end
  end

  # CORE_UNSEEN_DEFINERS: a listed name must also count the Ruby definers the registry leaves out, or MONO binds a
  # plain Array's `map` to the program's lone Array-subclass `map` (docs/bc2cpp-core-definers.md). An unlisted name
  # stays absent, so its core-only proofs are unchanged. Returns the names flipped from MONO.
  def add_unseen_placeholders!(registry, ireps, core_defs, alias_sites, outside_names)
    unseen = Set.new(outside_names)
    core_defs.each { |d| unseen << d.name unless registry[d.name]&.any? { |r| r.owner == d.owner && r.irep == d.irep } }
    alias_sites.each do |site|
      next unless core_source?(ireps.fetch(site[:irep]).file)

      unseen << site[:new] unless registry[site[:new]]&.any? { |r| r.owner == site[:owner] }
    end
    flipped = []
    unseen.each do |name|
      defs = registry[name]
      next if defs.nil? || defs.empty? || defs.any? { |d| d.owner == '<native>' }

      flipped << name if defs.size == 1
      defs << MethodDef.new(name: name, owner: '<native>', irep: nil, visibility: :public)
    end
    flipped
  end

  # mruby-enumerator runs Enumerator#next and the generators on a Fiber.
  def fiber_gem?(file)
    file.to_s.include?('/mruby-enumerator/')
  end

  # Opcodes that build or forward a block, and the ENTER block field.
  BLOCK_OPS = (BytecodeIR::Ops::BLOCK_SEND | %i[BLKPUSH BLOCK LAMBDA]).freeze

  # Does the method body (or a block or lambda nested in it) take, build, yield to or
  # forward a block? Such a compiled frame stays on the C++ stack while the block
  # runs, and a `Fiber.yield` inside the block (the RGSS script host's
  # Graphics.update, an Enumerator#next) cannot cross it: mruby raises FiberError
  # for a yield through a C frame. The compiled entry of these "guarded" methods
  # hands the call to the bytecode whenever a Fiber runs.
  def touches_block?(irep, ireps)
    enter = irep.enter
    return true if enter && enter.enter_fields[6].to_i.positive?
    return true if BytecodeIR.for(irep).op?(*BLOCK_OPS)

    irep.reps.any? { |child| child && touches_block?(ireps.fetch(child), ireps) }
  end

  # Does the body build a lambda? It is the one opcode that can make a closure the
  # method's result; the guard covers frames that sit on the stack while a block runs,
  # not a closure that a Fiber calls after the frame is gone.
  def builds_lambda?(irep, ireps)
    return true if BytecodeIR.for(irep).op?(:LAMBDA)

    irep.reps.any? { |child| child && builds_lambda?(ireps.fetch(child), ireps) }
  end

  # Does the body name the Fiber class? mruby-enumerator's Enumerator#next and the
  # Generator run their iteration inside a Fiber; a compiled frame in there breaks
  # the same way.
  def references_fiber?(irep, ireps)
    return true if BytecodeIR.for(irep).instructions_with_op(:GETCONST, :GETMCNST).any? { |insn| insn.const_name == 'Fiber' }

    irep.reps.any? { |child| child && references_fiber?(ireps.fetch(child), ireps) }
  end

  # The child irep a TDEF/SDEF names, or, for the unfused DEF, the METHOD before it.
  # +idx+ is the index of +insn+ in +irep+.
  def def_body_label(irep, insn, idx)
    return irep.reps[insn.block_index] unless insn.op == :DEF

    method_idx = irep.previous_real_index(idx - 1)
    method_insn = method_idx >= 0 ? BytecodeIR.for(irep).source_at(method_idx) : nil
    method_insn && method_insn.op == :METHOD ? irep.reps[method_insn.block_index] : nil
  end
end
