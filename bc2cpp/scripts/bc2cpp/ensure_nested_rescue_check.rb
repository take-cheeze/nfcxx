#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# ENSURE_NESTED_RESCUE (tools/bc2cpp/codegen_rescue.rb): a `begin X rescue C ... end` inside an ensure body, the shape
# mruby-io's IO.open closes its io with, compiles inside the ensure guard's lambda.
#
#   generated code (needs a host mrbc)
#     - the fixture's IO.open-shaped method compiles (no `#error`), with the protected range under mrb_protect_error
#       inside the ensure lambda; mruby-io's own IO.open compiles too;
#     - a rescue around the ensure (not inside it) and two rescues inside it keep `#error`.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for: the block's value, a close that succeeds, a close that
#       raises a StandardError (rescued), a close that raises a non-StandardError (it supersedes, also over an
#       exception raised by the block), the block's own exception, `$!` after the call, File.open writing and reading
#       a file, GC.stress and the same calls inside a Fiber.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/ensure_nested_rescue_check.rb

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
  class EnRes
    attr_reader :log
    def initialize(mode); @mode = mode; @closed = false; @log = []; end
    def closed?; @closed == true; end
    def close
      @log << :close
      raise ArgumentError, 'close failed' if @mode == :std
      raise NotImplementedError, 'hard close' if @mode == :hard
      @closed = true
    end
  end

  class EnFx
    def self.with(mode)
      io = EnRes.new(mode)
      begin
        yield io
      ensure
        begin
          io.close unless io.closed?
        rescue StandardError
        end
      end
    end

    # Not this shape: a rescue around the ensure, and two rescues inside it.
    def self.around(mode)
      io = EnRes.new(mode)
      begin
        begin
          yield io
        ensure
          io.close
        end
      rescue StandardError
        :rescued
      end
    end

    def self.two(mode)
      io = EnRes.new(mode)
      begin
        yield io
      ensure
        begin
          io.close
        rescue StandardError
        end
        begin
          io.close
        rescue StandardError
        end
      end
    end
  end
RUBY

OWNERS = %w[EnRes EnFx EnFx.singleton].freeze

def body_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

baseline_dir = Dir.mktmpdir('bc2cpp-ensure-nested-rescue')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS, skip_unsupported: false)
with = body_of(code, 'EnFx_singleton_with_impl')
check.call('with: the IO.open-shaped method compiles, the nested rescue under mrb_protect_error in the ensure lambda',
           !with.empty? && !with.include?('#error') && with.include?('ENSURE_NESTED_RESCUE') &&
             with.match?(/auto bc2cpp_ensure_fn = \[&\]\(\) \{\n\s+\{ \/\/ ENSURE_NESTED_RESCUE/))
io_open = body_of(code, 'IO_singleton_open_impl')
check.call("mruby-io's IO.open compiles", !io_open.empty? && !io_open.include?('#error'))
check.call('around, two: other mixes of rescue and ensure keep #error',
           body_of(code, 'EnFx_singleton_around_impl').include?('#error') &&
             body_of(code, 'EnFx_singleton_two_impl').include?('#error'))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  %i[ok std hard].each do |mode|
    show.call("value/#{mode}") { res = nil; v = EnFx.with(mode) { |io| res = io; :val }; [v, res.log, res.closed?] }
    show.call("raise/#{mode}") { EnFx.with(mode) { |io| raise IndexError, 'from block' } }
    show.call("errinfo/#{mode}") { begin; EnFx.with(mode) { |io| 1 }; rescue Exception; end; $!.inspect }
    show.call("nested/#{mode}") { EnFx.with(:ok) { |a| EnFx.with(mode) { |b| [a.log, b.log] } } }
  end
  show.call('file') do
    File.open('bc2cpp_enr.txt', 'w') { |f| f.write('abc') }
    r = File.open('bc2cpp_enr.txt', 'r') { |f| f.read }
    File.delete('bc2cpp_enr.txt')
    r
  end
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    r = [EnFx.with(:std) { |io| io.log.size }, (EnFx.with(:hard) { 1 } rescue $!.class)]
    GC.stress = false if GC.respond_to?(:stress=)
    r
  end
  # A Fiber.yield inside the block would cross the compiled method's C frame (FiberError), as for any compiled
  # method that yields; the engine creates no Fibers. The calls run inside one, yielding between them.
  f = Fiber.new do
    a = EnFx.with(:std) { |io| io.log.size }
    Fiber.yield a
    [EnFx.with(:ok) { :after }, (EnFx.with(:hard) { 2 } rescue $!.class)]
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
    run_dir = Dir.mktmpdir('bc2cpp-ensure-nested-rescue-run')
    at_exit { FileUtils.remove_entry(run_dir) }
    run_code, run_err = Bc2cppFixtureRuntime.generate(SRC, run_dir, core: true, only_owners: OWNERS)
    check.call('the run world compiles with', !run_code.empty?)
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"ENR(#{DRIVER})ENR";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(run_dir, run_err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
      check.call('a StandardError from close is rescued', interpreted.include?('value/std: [:val, [:close], false]'))
      check.call('a non-StandardError from close supersedes the block\'s exception',
                 interpreted.include?('raise/hard: NotImplementedError: hard close'))
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp ensure nested rescue check: PASS'
else
  warn "bc2cpp ensure nested rescue check: #{failures.size} failure(s)"
  exit 1
end
