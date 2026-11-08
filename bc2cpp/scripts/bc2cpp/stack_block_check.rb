#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# STACK_BLOCK: a direct-entry literal block passed to a compiled core arm whose callee only calls its block
# (BlockSelf.plain_yielder_why) is built in the caller's frame (Bc2cppBlock) instead of on the heap; the
# heap RProc is built only where the code still dispatches by name.
#
#   generated code (needs a host mrbc)
#     - `a.each { }` on an unproven receiver: the Array and Hash arms take the stack block, the Range arm (Range#each
#       passes its block on) and the owner-call else build the heap RProc on demand;
#     - a block that yields to the frame's own block (`needs_blk`) and a callee that passes its block on keep the
#       heap RProc;
#     - BC2CPP_STACK_BLOCKS=0 builds every block on the heap.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for captured-variable writes, nested callee blocks
#       (Enumerable#each_with_index), GC.start and allocation inside the block, an exception raised through the
#       block, receivers that take the else (Hash, Range, a user Enumerable), and the same calls inside a Fiber.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/stack_block_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

# The fixture is its own closed world: the repository signatures name classes it does not define.
ENV['BC2CPP_SIG_DIRS'] = ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

SRC = <<~'RUBY'
  class SbFx
    def sum(a); s = 0; a.each { |x| s += x.to_i }; s; end
    def strs(a); acc = +''; a.each { |x| acc << x.to_s << ','; GC.start }; acc; end
    def churn(a); r = []; a.each { |x| 40.times { |k| r << "#{x}-#{k}" }; r.shift(20) }; r.size; end
    def idx(a); r = []; a.each_with_index { |x, i| r << "#{i}:#{x}" }; r; end
    def boom(a); n = 0; a.each { |x| n += 1; raise ArgumentError, "at #{x}" if x == 2 }; n; rescue ArgumentError => e; [e.message, n]; end
    def nested(a); r = []; a.each { |x| a.each { |y| r << x * 10 + y.to_i if y.is_a?(Integer) } }; r; end
    def fwd(a); a.each { |x| yield x }; end
    def gen(a); i = 0; while i < a.size; yield a[i]; i += 1; end; self; end
    def use_gen(a); s = 0; gen(a) { |x| s += 1 unless x.nil? }; s; end
    def keep(&b); @kept = b; end
    def use_keep(a); keep { |x| x.to_s * 2 }; [@kept.call(a), @kept.call(2)]; end
    def stash; hold { |x| yield x }; end
    def hold(&b); @held = b; end
    def use_stash(a); stash { |x| x.to_s * 3 }; GC.start; [@held.call(a), @held.call(4)]; end
    # A nested block that yields to the method's block, sent to Integer#times: its heap env holds the block, so the
    # frame-local block the caller passes must be copied to the heap there (it must not outlive its frame).
    def repeat(n); n.times { |k| yield k }; self; end
    def use_repeat(a); r = []; repeat(a.size) { |k| r << k }; GC.start; r; end
    # A yielder with a `rescue` clause: behaviour must match interpreted.
    def guarded(default); yield; rescue StandardError => e; [default, e.message]; end
    def use_guarded(a); guarded(:none) { a.map { |x| x.to_i + 1 } }; end
    def use_guarded_raise(a); guarded(:none) { raise ArgumentError, "bad #{a.size}" if a.size > 1; a.size }; end
    # A rescue that keeps the block in an ivar is no plain yielder.
    def guarded_keep(&b); b.call; rescue StandardError; @kept = b; :kept; end
    def use_guarded_keep(a); guarded_keep { raise "x" if a.size > 1; a.size }; end
  end

  class SbColl
    include Enumerable
    def initialize(*a); @a = a; end
    def each; @a.each { |x| yield x }; self; end
  end
RUBY

def code_of(code, name)
  code[/^mrb_value SbFx_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

def generate_world(env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: %w[SbFx SbColl]) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

baseline_dir = Dir.mktmpdir('bc2cpp-stack-block')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: %w[SbFx SbColl])
sum = code_of(code, 'sum')
check.call('sum: the Array arm runs the compiled Array#each with the frame-local block',
           sum.match?(/Bc2cppBlock bc2cpp_blk_stack_(\d+)\(M, \d+, bc2cpp_blk_env_\1\);/) &&
             sum.match?(/Array_each_impl\(M, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/))
check.call('sum: the Hash arm and Range#each (which forwards its block with &blk) take it too; the else builds the heap RProc ' \
           'only when it runs',
           sum.include?('bc2cpp_blk_stack_') && sum.include?('.proc()') && sum.match?(/Hash_each_impl\(M, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/) &&
             sum.match?(/Range_each_impl\(M, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/) &&
             !sum.match?(/struct RProc\* bc2cpp_blk_proc_\d+ = bc2cpp_heap_proc/))
check.call('use_gen: a direct call to a compiled program method that only yields its block takes the frame-local block',
           code_of(code, 'use_gen').match?(/SbFx_gen_impl\(M, self, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/))
check.call('use_keep: a callee that stores its block keeps the heap RProc',
           code_of(code, 'use_keep').include?('SbFx_keep_impl(M') && !code_of(code, 'use_keep').include?('Bc2cppBlock'))
check.call('use_stash: a nested block that yields to the method block and is kept (no synchronous send) leaves the callee ' \
           'uncompiled, so the block stays on the heap',
           code.include?('BC2CPP_SKIPPED_SbFx_stash ') && !code_of(code, 'use_stash').include?('Bc2cppBlock'))
check.call('fwd: a block that yields to the frame block (needs_blk) is frame-local too; it holds the frame block as it is',
           code_of(code, 'fwd').match?(/\{ self, bc2cpp_blk, /) &&
             code_of(code, 'fwd').match?(/Array_each_impl\(M, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/) &&
             code_of(code, 'fwd').match?(/Range_each_impl\(M, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/))
check.call('use_repeat: the frame-local block reaches repeat, and the nested block that yields to it is frame-local too ' \
           '(its wrapper, made by .proc() for the by-name else, copies the frame-local block it holds)',
           code_of(code, 'use_repeat').match?(/SbFx_repeat_impl\(M, self, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/) &&
             code_of(code, 'repeat').match?(/Integer_times_impl\(M, r\d+, bc2cpp_blk_stack_\d+\.value\(\)\)/) &&
             !code_of(code, 'repeat').include?('bc2cpp_env_block(M, bc2cpp_blk)'))
check.call('use_guarded_keep: a yielder with a rescue keeps the heap RProc',
           !code_of(code, 'use_guarded_keep').include?('Bc2cppBlock'))
off, = generate_world('BC2CPP_STACK_BLOCKS' => '0')
check.call('BC2CPP_STACK_BLOCKS=0: every block is built on the heap',
           !off.include?('Bc2cppBlock bc2cpp_blk_stack_') && !off.include?('.proc()'))

DRIVER = <<~'RUBY'
  fx = SbFx.new
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  coll = SbColl.new(1, 2, 3)
  inputs = [[1, 2, 3], [], [5], (1..30).to_a, { a: 1, b: 2 }, 1..4, coll, nil]
  inputs.each_with_index do |a, i|
    %i[sum strs churn idx boom nested use_gen use_keep use_stash use_repeat use_guarded use_guarded_raise use_guarded_keep].each { |m| show.call("#{m}/#{i}") { fx.send(m, a) } }
    show.call("fwd/#{i}") { r = []; fx.fwd(a) { |x| r << x }; r }
  end
  GC.start
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    r = [fx.sum([1, 2, 3]), fx.strs(%w[x y]), fx.idx([:p, :q]), fx.boom([1, 2, 3]), fx.use_gen([4, 5]), fx.use_keep([6]), fx.use_stash([7]), fx.use_repeat([8, 9]), fx.use_guarded([1, 2]), fx.use_guarded_raise([1, 2])]
    GC.stress = false if GC.respond_to?(:stress=)
    r
  end
  f = Fiber.new do
    out = [fx.sum([4, 5]), fx.idx([7]), fx.nested([1, 2])]
    Fiber.yield out
    :done
  end
  show.call('fiber') { [f.resume, f.resume] }
  puts 'end'
RUBY

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"SBD(#{DRIVER})SBD";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, %w[SbFx SbColl], body, build: build, full: true)
    check.call('the fixtures build and run', built)
    # The two VMs need not lay their heaps out alike (bc2cpp_set_instance_tts may walk it), so `#<SbColl:0x...>`
    # is compared without its address.
    sections = Bc2cppFixtureRuntime.sections(output).transform_values { |lines| lines.map { |l| l.gsub(/:0x\h+>/, '>') } }
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
      check.call('a captured variable written by the block is seen after the call', interpreted.include?('sum/0: 6'))
      check.call('an exception raised in the block unwinds through the call', interpreted.include?('boom/0: ["at 2", 2]'))
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp stack block check: PASS'
else
  warn "bc2cpp stack block check: #{failures.size} failure(s)"
  exit 1
end
