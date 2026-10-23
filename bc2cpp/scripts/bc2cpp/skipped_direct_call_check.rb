#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# A direct call into a body SKIP_UNSUPPORTED drops must not be emitted. `Range#max`'s `super` reaches
# `Enumerable#max` (MODULE_SUPER_SUPPORT, codegen_receiver_facts.rb module_super_call): when that body carries a #error
# its `_impl` is not emitted, so the caller keeps its own `#error` (left interpreted), as an unsupported call does.
#
# The fixture reproduces the shape with an ensure-leaving `next` (a JMPUW, which has no compiled form): SkEnum#pick is
# skipped, and SkRange#pick reaches it through `super()` with its block.
#
# Codegen half (needs host mrbc): no `SkEnum_pick_impl` call survives, and SkRange#pick is not emitted either.
# Behaviour half (needs a full-core libmruby): the program runs, and the compiled and interpreted runs print the same.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/skipped_direct_call_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

# The fixture is checked against no shipped signature files: they name engine classes it lacks.
ENV['BC2CPP_SIG_DIRS'] ||= ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the codegen asserts need it'
  exit 0
end

PROGRAM = <<~'RUBY'
  module SkEnum
    # The `next` leaves the ensure region (a JMPUW): this body has a #error, so SKIP_UNSUPPORTED drops its _impl.
    def pick(&b)
      r = []
      i = 0
      while i < 3
        i += 1
        begin
          next if i == 2
          r << b.call(i)
        ensure
          r << :e
        end
      end
      r
    end
  end

  class SkRange
    include SkEnum

    # Reaches SkEnum#pick through an included module, forwarding this frame's block (Range#max's shape).
    def pick(&b)
      super()
    end
  end

  class SkDrive
    def drive
      SkRange.new.pick { |x| x * 2 }
    end
  end
RUBY

DRIVER = <<~'RUBY'
  puts "drive: #{SkDrive.new.drive.inspect}"
  puts "direct: #{SkRange.new.pick { |x| x * 3 }.inspect}"
  puts 'end'
RUBY

puts '-- codegen (generation)'
gen_dir = Dir.mktmpdir('bc2cpp-skipped-direct')
begin
  code, = Bc2cppFixtureRuntime.generate(PROGRAM, gen_dir, only_owners: %w[SkEnum SkRange SkDrive])

  check.call('SkEnum#pick is skipped (its body has a #error, so no _impl is emitted)',
             !code.match?(/^mrb_value SkEnum_pick_impl\(/))
  check.call('no emitted call names the skipped SkEnum_pick_impl',
             !code.include?('SkEnum_pick_impl('))
  check.call('SkRange#pick is not emitted either (its super reaches the skipped body, so it keeps its #error)',
             !code.match?(/^mrb_value SkRange_pick_impl\(/))
  check.call('SkDrive#drive is emitted without a direct call into the skipped body',
             code.match?(/^mrb_value SkDrive_drive_impl\(/) && !code.include?('SkRange_pick_impl('))
rescue RuntimeError => e
  warn e.message
  check.call('the fixture generates', false)
ensure
  FileUtils.remove_entry(gen_dir)
end

puts '-- behaviour (needs a full-core libmruby)'
build = Bc2cppFixtureRuntime.full_or_build
if build.nil?
  puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
else
  run_dir = Dir.mktmpdir('bc2cpp-skipped-direct-run')
  begin
    _code, run_err = Bc2cppFixtureRuntime.generate(PROGRAM, run_dir, only_owners: %w[SkEnum SkRange SkDrive])
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"BID(#{DRIVER})BID";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(run_dir, run_err, %w[SkEnum SkRange SkDrive], body, build: build, full: true)
    check.call('the fixtures build and link (no undefined reference to a skipped _impl)', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call('the driver finishes in both runs', interpreted&.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', !interpreted.nil? && interpreted == compiled)
    if interpreted
      check.call('the block reaches the module body through super (interpreted: [2, :e, :e, 6, :e])',
                 interpreted.include?('drive: [2, :e, :e, 6, :e]'))
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  ensure
    FileUtils.remove_entry(run_dir)
  end
end

if failures.empty?
  puts 'bc2cpp skipped direct call check: PASS'
else
  warn "bc2cpp skipped direct call check: #{failures.size} failure(s)"
  exit 1
end
