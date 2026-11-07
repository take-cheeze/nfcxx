#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# ENUMERATOR_FIBER: Enumerator#next over a compiled Array#each, a user `each` and a to_enum with arguments runs its
# Fiber body as a C++ Fiber step (on by default; BC2CPP_ENUMERATOR_FIBER=0 keeps bytecode; it compiles mruby-enumerator's next_values, #each and
# #__enumerator_block_call; they stay bytecode by default).
#
# DYN_CALL with keywords (tools/bc2cpp/codegen_resumable.rb resumable_dyn_site, runtime bc2cpp_dyn_call): a send in a
# step may carry a splat, keywords and a forwarded block, the shape of Enumerator#each's
# `@obj.__send__ @meth, *@args, **@kwd, &block`. A suspendable method takes no keywords, so an empty keyword Hash
# dispatches to the registered step and a non-empty one runs as an ordinary send that carries the keywords.
#
#   generated code (needs a host mrbc)
#     - the forwarding method compiles as a step with a dynamic call, and no #error is left;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/enumerator_next_check.rb

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

# KwClock forwards to a target chosen at run time: a suspendable method (no keywords) and a method with keywords.
SRC = <<~'RUBY'
  class KwTarget
    def kw_count(n)
      out = []
      i = 0
      while i < n
        out << yield(i)
        i += 1
      end
      out
    end

    def kw_scaled(n, scale: 1)
      out = []
      n.times { |i| out << yield(i * scale) }
      out
    end
  end

  class KwClock
    def initialize(target)
      @target = target
    end

    def start
      @fiber = Fiber.new { run }
    end

    def run
      yielded = forward(:kw_count, [3], {}) { |x| back = Fiber.yield x; back.to_i + 1 }
      scaled = forward(:kw_scaled, [2], { scale: 10 }) { |x| x + 1 }
      [yielded, scaled]
    end

    def forward(meth, args, kwd, &block)
      @target.__send__ meth, *args, **kwd, &block
    end

    def go
      @fiber.resume
    end

    def go_with(value)
      @fiber.resume(value)
    end

    def fiber_alive
      @fiber.alive?
    end
  end
RUBY

# EnColl: a collection with its own each, reached through to_enum with an argument.
SRC2 = <<~'RUBY'
  class EnColl
    def initialize(items)
      @items = items
    end

    def each_item(extra = 0)
      i = 0
      while i < @items.size
        yield @items[i] + extra
        i += 1
      end
      self
    end

    def enum
      to_enum(:each_item, 100)
    end
  end
RUBY

# EnSource: an Enumerable over its own each, walked externally (Enumerable's enumerator-returning forms) and lazily.
SRC3 = <<~'RUBY'
  class EnSource
    include Enumerable

    def each(start = 1)
      i = start
      while i <= 3
        yield i
        i += 1
      end
      self
    end
  end
RUBY

OWNERS = %w[KwTarget KwClock EnColl EnSource Enumerator Enumerator::Lazy Enumerator::Generator Enumerator::Yielder Array Enumerable Range Integer Kernel].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-enumerator-next')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC + SRC2 + SRC3, baseline_dir, core: true, only_owners: OWNERS)
check.call('run compiles as a resumable step function', code.include?('static mrb_value KwClock_run_step(mrb_state* M'))
check.call('forward compiles as a resumable step function', code.include?('static mrb_value KwClock_forward_step(mrb_state* M'))
check.call('the splat-and-keywords send is a dynamic call', code.include?('// RESUMABLE_DYN_CALL'))
check.call('kw_count registers a dispatcher', code.include?('KwTarget_kw_count_impl_dyn'))
check.call('Enumerator#next_values builds its Fiber from a step', code.match?(/static mrb_value Enumerator_next_values__blk\d+_step\(mrb_state\* M/))
check.call('the iteration block of next_values is a step', code.scan(/static mrb_value Enumerator_next_values__blk\d+_step\(mrb_state\* M/).size >= 2)
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  c = KwClock.new(KwTarget.new)
  c.start
  out = []
  out << c.go
  GC.start
  out << c.go_with(10)
  out << c.go_with(20)
  out << c.go_with(30)
  out << c.fiber_alive
  p out

  en = [10, 20, 30].each
  r = []
  r << en.next
  GC.start
  r << en.next
  r << en.peek
  r << en.next
  begin
    en.next
  rescue StopIteration => e
    r << e.class
  end
  p r

  eu = EnColl.new([1, 2, 3]).enum
  u = []
  u << eu.next
  u << eu.next
  u << eu.next
  begin
    eu.next
  rescue StopIteration => e
    u << e.class
  end
  eu.rewind
  u << eu.next
  p u

  es = [5, 6].each_with_index
  s = []
  s << es.next
  s << es.next
  eh = { a: 1, b: 2 }.each
  s << eh.next
  et = 3.times
  s << et.next
  s << et.next
  p s

  def shown(label)
    puts "#{label}: #{yield.inspect}"
  rescue StandardError => e
    puts "#{label}: raised #{e.class}: #{e.message}"
  end

  src = EnSource.new
  shown('to_enum') { e = src.to_enum; [e.next, e.next, e.next, (e.next rescue :stop)] }
  shown('to_enum size') { src.to_enum.size }
  shown('map enum') { e = src.map; [e.next, e.next] }
  shown('select enum') { e = src.select; [e.next, e.peek, e.next] }
  shown('each_with_index enum') { e = src.each_with_index; [e.next, e.next] }
  shown('each_slice enum') { e = src.each_slice(2); [e.next, e.next, (e.next rescue :stop)] }
  shown('each_cons enum') { e = src.each_cons(2); [e.next, e.next] }
  shown('each_with_object enum') { e = src.each_with_object([]); [e.next, e.next] }
  shown('with_index') { e = src.each.with_index(1); [e.next, e.next] }
  shown('rewind') { e = src.to_enum; a = e.next; e.rewind; [a, e.next] }
  shown('lazy next') { e = src.lazy.map { |x| x * 2 }.select { |x| x > 2 }.to_enum; [e.next, e.next] }
  shown('lazy first') { src.lazy.map { |x| x * 3 }.first(2) }
  shown('two enumerators') { a = src.to_enum; b = src.to_enum; [a.next, b.next, a.next, b.next] }
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
    # Known gaps: the compiled run does not match yet, and must keep failing until the gap is closed (then remove it).
    #   lazy next -- mruby-enum-lazy is not among the core gems bc2cpp compiles (compiled_gems.rb), and its generator block
    #                wraps the iteration in begin/rescue StopIteration, which a step cannot contain yet.
    gap = ->(line) { line.to_s.start_with?('lazy next:') }
    check.call('interpreted and compiled runs print the same outside the known gaps',
               interpreted && compiled && interpreted.zip(compiled).all? { |a, b| a == b || gap.call(a) })
    check.call('every known gap still fails', interpreted && compiled &&
               interpreted.zip(compiled).select { |a, _| gap.call(a) }.all? { |a, b| a != b })
    check.call('the suspendable target yields through the CALL and the keyword target gets its keyword',
               interpreted&.first == '[0, 1, 2, [[11, 21, 31], [1, 11]], false]')
    check.call('Enumerator#next walks Array#each, a user each with an argument, each_with_index, Hash#each and Integer#times',
               interpreted&.[](1) == '[10, 20, 30, 30, StopIteration]' &&
               interpreted&.[](2) == '[101, 102, 103, StopIteration, 101]' &&
               interpreted&.[](3) == '[[5, 0], [6, 1], [:a, 1], 0, 1]')
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b || gap.call(a) }.first(20).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp enumerator next check: PASS'
else
  warn "bc2cpp enumerator next check: #{failures.size} failure(s)"
  exit 1
end
