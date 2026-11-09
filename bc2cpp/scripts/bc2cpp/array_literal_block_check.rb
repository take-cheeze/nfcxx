#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Array literal receivers of a block-taking send (tools/bc2cpp/escape_analysis.rb, literal_block_send?). The receiver
# `[1, 2].each { }` used to escape: Array#each returns to_enum(:each) without a block, which keeps self, and the analysis
# walked that arm. A SENDB whose block is the BLOCK made in this frame is judged with the block given, so the to_enum arm
# is not walked, and the literal array is confined. The shapes below must keep their verdicts:
#   - a no-block `each` (an Enumerator holding the array is returned): the receiver escapes;
#   - a block that stores its argument (an object element of the literal) in an outer array: the object escapes;
#   - a block that stores the receiver itself in an outer array: the receiver escapes;
#   - a block passed as &blk (not a literal block): the receiver escapes;
#   - the array passed to an unknown method alongside &blk: the array escapes.
#
# Verdict half (needs host mrbc): the escape report (BC2CPP_ESCAPE_REPORT) gives each creation site its verdict.
# Behaviour half (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build): the compiled and interpreted runs
# print the same, for the confined shapes and the no-block path.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/array_literal_block_check.rb

require 'tmpdir'
require 'fileutils'
require_relative 'fixture_runtime'

# The fixture is checked against no shipped signature files: they name engine classes it lacks.
ENV['BC2CPP_SIG_DIRS'] ||= ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the escape verdicts need it'
  exit 0
end

VERDICT_SRC = <<~'RUBY'
  class ABox
    def touch(x); x; end
  end

  class RLit
    def p_each_count
      o = ABox.new
      t = 0
      [1, 2].each { |x| t += o.touch(x) }
      t
    end

    def p_map
      o = ABox.new
      [1, 2].map { |x| o.touch(x) * 10 }
    end

    def n_each_noblock
      [1, 2].each
    end

    def n_store_arg
      keep = []
      o = ABox.new
      [o].each { |x| keep << x }
      keep
    end

    def n_store_receiver
      keep = []
      a = [1, 2]
      a.each { |x| keep << a }
      keep
    end

    def n_pass_amp(&b)
      a = [1, 2]
      a.each(&b)
      nil
    end

    def n_unknown_amp(k, &b)
      a = [1, 2]
      k.each_with(a, &b)
      nil
    end
  end
RUBY

# The program the behaviour half compiles and runs: the confined shapes, and the no-block path that returns the enumerator.
RUN_SRC = <<~'RUBY'
  class ABox
    def touch(x); x; end
  end

  class RRun
    def p_each_count; o = ABox.new; t = 0; [1, 2].each { |x| t += o.touch(x) }; t; end
    def p_map; o = ABox.new; [1, 2].map { |x| o.touch(x) * 10 }; end
    def n_each_noblock; [1, 2].each; end
    def n_store_receiver; keep = []; a = [1, 2]; a.each { |x| keep << a }; keep; end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = RRun.new
  [[:p_each_count], [:p_map], [:n_each_noblock, 'to_a'], [:n_store_receiver]].each do |name, after|
    out = begin
      res = fx.__send__(name)
      res = res.to_a if after == 'to_a'
      res.inspect
    rescue NoMethodError, ArgumentError, TypeError => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  puts 'end'
RUBY

# [kind, verdict, reason] of each creation site of method +name+ in the escape report (owner RLit).
def verdicts(rows, name)
  rows.select { |r| r[0] == 'site' && r[2] == "RLit##{name}" }.map { |r| [r[5], r[6], r[7]] }
end

def site?(rows, name, kind, verdict, reason = nil)
  verdicts(rows, name).any? { |k, v, why| k == kind && v == verdict && (reason.nil? || why == reason) }
end

puts '-- escape verdicts (generation)'
verdict_dir = Dir.mktmpdir('bc2cpp-array-literal-block')
begin
  tsv = File.join(verdict_dir, 'escape.tsv')
  saved = ENV.fetch('BC2CPP_ESCAPE_REPORT', nil)
  ENV['BC2CPP_ESCAPE_REPORT'] = tsv
  begin
    Bc2cppFixtureRuntime.generate(VERDICT_SRC, verdict_dir, core: true, only_owners: %w[RLit])
  ensure
    saved.nil? ? ENV.delete('BC2CPP_ESCAPE_REPORT') : ENV['BC2CPP_ESCAPE_REPORT'] = saved
  end
  rows = File.readlines(tsv, chomp: true).map { |line| line.split("\t", -1) }
  check.call('the report has the RLit creation sites', rows.count { |r| r[2].to_s.start_with?('RLit#') } >= 10)

  check.call('p_each_count: the literal array of a block each is confined',
             site?(rows, 'p_each_count', 'array', 'confined'))
  check.call('p_each_count: its block is confined', site?(rows, 'p_each_count', 'block:each', 'confined'))
  check.call('p_each_count: the object used only in the block is confined', site?(rows, 'p_each_count', 'object', 'confined'))
  check.call('p_map: the literal array of a block map is confined', site?(rows, 'p_map', 'array', 'confined'))
  check.call('p_map: its block is confined', site?(rows, 'p_map', 'block:map', 'confined'))

  check.call('n_each_noblock: the no-block each returns an Enumerator that holds the array, so it escapes (send_receiver)',
             site?(rows, 'n_each_noblock', 'array', 'escapes', 'send_receiver'))
  check.call('n_store_arg: a block that stores its argument (an element) in an outer array makes the element escape',
             site?(rows, 'n_store_arg', 'object', 'escapes'))
  check.call('n_store_receiver: a block that stores the receiver in an outer array makes the receiver escape',
             site?(rows, 'n_store_receiver', 'array', 'escapes'))
  check.call('n_pass_amp: a block passed as &blk is not a literal block, so the receiver escapes (send_receiver)',
             site?(rows, 'n_pass_amp', 'array', 'escapes', 'send_receiver'))
  check.call('n_unknown_amp: the array passed to an unknown method escapes (send_argument)',
             site?(rows, 'n_unknown_amp', 'array', 'escapes', 'send_argument'))
ensure
  FileUtils.remove_entry(verdict_dir)
end

puts '-- behaviour (needs a full-core libmruby)'
build = Bc2cppFixtureRuntime.full_or_build
if build.nil?
  puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
else
  run_dir = Dir.mktmpdir('bc2cpp-array-literal-block-run')
  begin
    _code, run_err = Bc2cppFixtureRuntime.generate(RUN_SRC, run_dir, core: true, only_owners: %w[RRun])
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
    built, output = Bc2cppFixtureRuntime.run(run_dir, run_err, %w[RRun], body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call('the driver finishes in both runs', interpreted&.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted
      check.call('p_each_count sums through the confined block', interpreted.include?('p_each_count: 3'))
      check.call('p_map maps through the confined block', interpreted.include?('p_map: [10, 20]'))
      check.call('n_each_noblock: the enumerator still iterates the array', interpreted.include?('n_each_noblock: [1, 2]'))
      check.call('n_store_receiver: the outer array holds the receiver once per element', interpreted.include?('n_store_receiver: [[1, 2], [1, 2]]'))
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  ensure
    FileUtils.remove_entry(run_dir)
  end
end

if failures.empty?
  puts 'bc2cpp array literal block check: PASS'
else
  warn "bc2cpp array literal block check: #{failures.size} failure(s)"
  exit 1
end
