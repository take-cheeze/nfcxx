#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# STEP_CLOSURES (tools/bc2cpp/codegen_resumable.rb, codegen_block_fallback.rb): a closure may outlive the step that
# made it. A variable of a step that a block may keep (store, return, yield, hand to an unknown callee) lives in a heap
# cell shared by the step and every block, so the step's frame and the C stack can be gone while the block still reads
# and writes it. A Fiber body takes its captured locals (written ones, optional and rest parameters, outer upvars) the
# same way. The cheap pointer form stays where the block provably does not outlive the call.
#
#   generated code (needs a host mrbc)
#     - the probe class compiles with no #error;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - every scenario prints the same compiled as interpreted. The fiber bodies are compiled (a probe class), not
#       eval'd, so the C++ Fiber runs them.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/step_closures_check.rb

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

WIDE = (0...250).map { |i| "      l#{i} = #{i}\n" }.join
WIDE_LIST = (0...250).map { |i| "l#{i}" }.join(', ')

# Each ScClosures method is one scenario; the driver prints what it returns.
SRC = <<~RUBY
  class ScClosures
    # A block kept past the fiber: it writes a variable of the (finished) body.
    def sc_escape
      f = Fiber.new do
        x = 1
        capture = proc { x += 1 }
        Fiber.yield capture
        capture.call
      end
      capture = f.resume
      GC.start
      [capture.call, f.resume, capture.call, f.alive?]
    end

    # Two blocks over one variable see each other's writes.
    def sc_shared
      f = Fiber.new do
        n = 10
        inc = proc { n += 1 }
        get = proc { n }
        Fiber.yield [inc, get]
        inc.call
        n
      end
      inc, get = f.resume
      GC.start
      [inc.call, get.call, f.resume, get.call]
    end

    # A body that writes captured parameters, optional and rest included.
    def sc_params(a, b = 2, *rest)
      f = Fiber.new do
        a += 1
        Fiber.yield a
        b += 1
        rest << :x
        [a, b, rest]
      end
      [f.resume, f.resume, a, b]
    end

    # A body inside a block: the outer block's parameter is an upvar of the body.
    def sc_outer
      out = []
      [1, 2].each do |i|
        f = Fiber.new do
          Fiber.yield i
          i * 2
        end
        out << f.resume << f.resume
      end
      out
    end

    # A step's variable captured by a block that is yielded out and called later, from the resumer.
    def sc_step_local
      f = Fiber.new do
        count = 0
        step = proc { count += 1 }
        2.times { |i| Fiber.yield step; step.call }
        count
      end
      s = f.resume
      GC.start
      [s.call, f.resume.class, f.resume, s.call, f.alive?]
    end

    # A method with 250 locals yielding an Array of them.
    def sc_wide
      f = Fiber.new do
  #{WIDE}      Fiber.yield [#{WIDE_LIST}]
        [l0, l249]
      end
      a = f.resume
      [a.size, a.first, a.last, f.resume]
    end

    # The classic closure: two procs over one local, both outliving the method.
    def sc_counter
      count = 0
      inc = proc { count += 1 }
      [inc, proc { count }]
    end

    # One proc per element of a loop: each captures its own element (the loop's block is not inlined).
    def sc_adders
      [1, 2, 3].map { |n| proc { |x| x + n } }
    end

    # A default proc keeps its block; the local is written after the Hash exists.
    def sc_hash_default
      base = 100
      h = Hash.new { |hash, k| hash[k] = base + k }
      base = 200
      h
    end

    # Arity and parameters of compiled blocks: mandatory, rest, lambda.
    def sc_arity
      g = proc { |x, y| }
      r = proc { |*rest| rest }
      l = lambda { |x, y| x }
      [g.arity, g.parameters, g.lambda?, r.arity, r.parameters, r.call(5, 6), l.arity, l.parameters, l.lambda?, l.call(1, 2)]
    end

    # A kept block nested in a block that is only called during the call reads and writes the method's local.
    def sc_nested
      total = 0
      procs = []
      [1, 2].each { |i| procs << proc { total += i } }
      [procs, proc { total }]
    end

    # The same inside a Fiber body, and two blocks deep.
    def sc_nested_fiber
      f = Fiber.new do
        x = 100
        procs = []
        [1, 2].each { |i| [10, 20].each { |j| procs << proc { x += i * j } } }
        Fiber.yield [procs, proc { x }]
        x
      end
      procs, get = f.resume
      GC.start
      [procs.map(&:call), get.call, f.resume, get.call]
    end

    # The middle block suspends (it is a step of its own).
    def sc_nested_step
      f = Fiber.new do
        x = 100
        procs = []
        [1, 2].each { |i| Fiber.yield i; procs << proc { x += i } }
        Fiber.yield [procs, proc { x }]
        x
      end
      f.resume
      f.resume
      procs, get = f.resume
      GC.start
      [procs.map(&:call), get.call, f.resume, get.call]
    end

    # Many kept blocks writing their cells: no root is kept per cell (the stores gray the Array).
    def sc_roots
      before = ($__bc2cpp_upvar_roots || {}).size
      kept = []
      12.times { |n| x = n.to_s; blk = proc { x += 'a' }; blk.call; kept << blk }
      GC.start
      [kept.map(&:call).size, kept.last.call, ($__bc2cpp_upvar_roots || {}).size - before < 4]
    end

    # A block with optional or keyword parameters is not compiled yet (its method stays interpreted): the scenario only
    # pins the interpreted answers, which the compiled blocks above must give too.
    def sc_arity_optional
      f = proc { |a, b = 1, *rest, key: 2, &block| }
      h = proc { |a, b = 1| [a, b] }
      [f.arity, f.parameters, h.arity, h.parameters, h.call(5), h.call(5, 6)]
    end
  end
RUBY

OWNERS = %w[ScClosures].freeze

DRIVER = <<~RUBY
  def show(label)
    puts "\#{label}: \#{yield.inspect}"
  rescue StandardError => e
    puts "\#{label}: raised \#{e.class}: \#{e.message}"
  end
  s = ScClosures.new
  show('escape') { s.sc_escape }
  show('shared') { s.sc_shared }
  show('params') { s.sc_params(1) }
  show('params with optional and rest') { s.sc_params(1, 5, 7, 8) }
  show('outer') { s.sc_outer }
  show('step local') { s.sc_step_local }
  show('wide') { s.sc_wide }
  show('counter') { inc, get = s.sc_counter; GC.start; [inc.call, inc.call, get.call, inc.call] }
  show('adders') { adders = s.sc_adders; GC.start; adders.map { |a| a.call(10) } }
  show('hash default') { h = s.sc_hash_default; GC.start; [h[1], h[2], h.size] }
  show('arity') { s.sc_arity }
  show('nested') { ps, g = s.sc_nested; GC.start; [ps.map(&:call), g.call, ps.map(&:call), g.call] }
  show('nested fiber') { s.sc_nested_fiber }
  show('nested step') { s.sc_nested_step }
  show('roots') { s.sc_roots }
  show('arity optional') { s.sc_arity_optional }
  puts 'end'
RUBY

baseline_dir = Dir.mktmpdir('bc2cpp-step-closures')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
File.write(ENV['STEP_CLOSURES_DUMP'], code) if ENV['STEP_CLOSURES_DUMP']
File.write(ENV['STEP_CLOSURES_ERR'], baseline_err.to_s) if ENV['STEP_CLOSURES_ERR']
check.call('no #error in the generated code', !code.include?('#error'))
# A method the compiler could not translate is left to the interpreter, where it trivially matches: every scenario must be
# compiled, not skipped.
%w[sc_escape sc_shared sc_params sc_outer sc_step_local sc_wide sc_counter sc_adders sc_hash_default sc_arity sc_nested sc_nested_fiber sc_nested_step sc_roots].each do |name|
  check.call("ScClosures##{name} is compiled", code.include?("mrb_value ScClosures_#{name}_impl(mrb_state* M") &&
                                               !code.include?("BC2CPP_SKIPPED_ScClosures_#{name} "))
end

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
        const char* src = R"RBC(#{DRIVER})RBC";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call('both runs reach the end', interpreted&.last == 'end' && compiled&.last == 'end')
    if interpreted && compiled
      interpreted.zip(compiled).each do |a, b|
        label = a.to_s[/\A[^:]+/]
        check.call("#{label}: interpreted and compiled runs print the same", a == b)
        puts "    interpreted: #{a}\n    compiled:    #{b}" unless a == b
      end
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp step closures check: PASS'
else
  warn "bc2cpp step closures check: #{failures.size} failure(s)"
  exit 1
end
