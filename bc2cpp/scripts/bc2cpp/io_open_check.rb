#!/usr/bin/env ruby
# frozen_string_literal: true

# The IO.open producer and the IO binding model (docs/bc2cpp-type-check.md, "IO.open"). Each fixture is compiled by the
# host mrbc and analysed in process: the closed world is built over the fixture plus two synthetic native files that
# define IO exactly as mruby-io's io.c and mruby-stringio's stringio.c do, and the gates are read off it.
# The engine's own run (type_check.rb) is the end-to-end check; a --files run has no mruby-io, so IO is not defined
# there and this check supplies the native definers itself. Needs MRBC; without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/io_open_check.rb

require 'tmpdir'
require 'set'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/type_facts'

unless ENV['MRBC'] && File.executable?(ENV['MRBC'])
  puts 'SKIP io_open_check: MRBC is not set to a host mrbc'
  exit 0
end

# The two definers mruby-io (io.c) and mruby-stringio (stringio.c) make of IO. Both are plain Object-superclass defines.
NATIVE_IO_IO_C = <<~C
  void mrb_mruby_io_gem_init(mrb_state *mrb) {
    struct RClass *io = mrb_define_class_id(mrb, MRB_SYM(IO), mrb->object_class);
  }
C
NATIVE_IO_STRINGIO_C = <<~C
  void mrb_mruby_stringio_gem_init(mrb_state *mrb) {
    struct RClass *io = mrb_define_class(mrb, "IO", mrb->object_class);
  }
C

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# Builds the closed world over +source+ with the two native IO definers, and the gates of the producer.
analysis = lambda do |source|
  Dir.mktmpdir do |dir|
    rb = File.join(dir, 'fixture.rb')
    File.write(rb, source)
    io_c = File.join(dir, 'io.c')
    stringio_c = File.join(dir, 'stringio.c')
    File.write(io_c, NATIVE_IO_IO_C)
    File.write(stringio_c, NATIVE_IO_STRINGIO_C)
    ireps, root = compile_ireps([rb], 'io_open', dir)
    registry, _superclass_of, _containers, included, prepended, unknown, _structs, decls, walked, = build_registry(ireps, root)
    world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: decls, walked: walked.to_a & ireps.keys,
                            native_paths: [io_c, stringio_c], ruby_paths: [], module_names: Set.new)
    gen = Object.new
    gen.instance_variable_set(:@closed_world, world)
    gen.instance_variable_set(:@native_name_sources, {})
    ctx = Struct.new(:gen, :registry, :included_modules, :prepended_modules, :unknown_mixins)
                .new(gen, registry, included, prepended, unknown)
    safe = TypeFacts.io_open_safe?(ctx)
    # The constant sites: every SETCONST value, with the predicate the producer runs on it.
    sites = ireps.values.flat_map do |irep|
      irep.instructions.each_index.filter_map do |idx|
        insn = irep.instructions[idx]
        next unless insn.op == :SETCONST

        # SETCONST keeps its value register in regs[0] (its reg is nil).
        [insn.const_name.to_s, DeclaredConstants.io_open_site?(irep, idx, insn.regs[0], io_open_safe: safe)]
      end
    end
    {
      unshadowed: world.native_class_unshadowed?('IO'),
      safe: safe,
      typed: sites.to_h
    }
  end
end

puts '== blockless IO.open: IO binding, root reopen, two native definers'
blockless = <<~RUBY
  class IO
  end
  IoProbeStdin = IO.open(0, "r")
  IoProbeStdout = IO.open(1, "w")
RUBY
b = analysis.call(blockless)
check.call('IO is the one native class (both native definers and the root `class IO` reopen bind nothing new)', b[:unshadowed])
check.call('the IO.open gates hold (io_open_safe?)', b[:safe])
check.call('IoProbeStdin (blockless IO.open) is typed IO', b[:typed]['IoProbeStdin'] == true)
check.call('IoProbeStdout (blockless IO.open) is typed IO', b[:typed]['IoProbeStdout'] == true)

puts '== IO.open with a block is not typed (the block value is the result)'
with_block = <<~RUBY
  IoProbeBlock = IO.open(0, "r") { |io| io }
RUBY
w = analysis.call(with_block)
check.call('IoProbeBlock (IO.open with a block) is not typed', w[:typed]['IoProbeBlock'] == false)

puts '== a program redefining IO.open is refused'
redefined = <<~RUBY
  class IO
    def self.open(*args)
      nil
    end
  end
  IoProbeRedef = IO.open(0, "r")
RUBY
r = analysis.call(redefined)
check.call('io_open_safe? is false (a Ruby `open` on IO.singleton)', !r[:safe])
check.call('IoProbeRedef stays untyped', r[:typed]['IoProbeRedef'] == false)

puts '== a nested class IO shadows the constant: no IO typing'
nested = <<~RUBY
  module IoProbeNest
    class IO
    end
  end
  IoProbeNested = IO.open(0, "r")
RUBY
n = analysis.call(nested)
check.call('native_class_unshadowed?(IO) is false (a nested CLASS IO declares a constant)', !n[:unshadowed])
check.call('IoProbeNested stays untyped', n[:typed]['IoProbeNested'] == false)

puts '== a root-level rebinding of IO is refused'
rebound = <<~RUBY
  IO = 1
  IoProbeRebound = IO.open(0, "r")
RUBY
rb = analysis.call(rebound)
check.call('native_class_unshadowed?(IO) is false (a SETCONST binds IO)', !rb[:unshadowed])

if failures.empty?
  puts 'io_open_check: all checks passed'
else
  puts "io_open_check: #{failures.size} failure(s)"
  exit 1
end
