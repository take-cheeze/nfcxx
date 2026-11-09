#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Receiver-class flow in the escape analysis (tools/bc2cpp/escape_analysis.rb). A block-taking send whose receiver is
# proven to be one exact class judges each callee on that class: its implicit-self and self-receiver sends resolve on
# that class's ancestry, so Enumerable's bodies stop seeing every `each` in the world. An object created in a method
# and used only in such a block is then confined, and so is the block. Shapes the analysis cannot prove keep their
# verdicts:
#   - a receiver that is a parameter, or a receiver whose class set has two classes;
#   - a user `map`, `each` or subclass `each` that keeps its block, or an Enumerable whose `each` keeps it;
#   - a block that stores the object in an ivar or a closure, or passes it to an unknown callee;
#   - a receiver whose method stores self (its receiver escapes).
#
# Verdict half (needs host mrbc): the escape report (BC2CPP_ESCAPE_REPORT) gives each creation site its verdict.
# Behaviour half (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build): the compiled and interpreted runs
# print the same. Its program has no user method that keeps its block: the by-name
# BLOCK_FALLBACK_UPVAR_SAFE_METHODS allowlist (irep_arity.rb) is a claim about every definition of that name.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/escape_receiver_flow_check.rb

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
  puts '  SKIP: no host mrbc (set MRBC); the escape verdicts need it'
  exit 0
end

VERDICT_SRC = <<~'RUBY'
  class RBox
    def touch(x); x; end
    def keep(x); @k = x; nil; end
  end

  class RKeep
    def map(&b); @b = b; self; end
  end

  class RBag
    include Enumerable
    def initialize; @items = [1, 2]; end
    def each(&b); @kept = b; @items.each(&b); self; end
  end

  class RSubA < Array
    def each(&b); RSubA.last = b; super; end
    class << self; attr_accessor :last; end
  end

  class RSelfKeep
    def each(&b); @me = self; b.call(1); self; end
  end

  class RFlow
    # Confined: the receiver is an exact class, its callees keep no block, the object is used only in the block.
    def p_each_count
      o = RBox.new
      t = 0
      [1, 2].each { |x| t += o.touch(x).to_i }
      t
    end

    def p_each_with_index
      o = RBox.new
      [1, 2].each_with_index { |x, i| o.touch(x) + i }
    end

    def p_any
      o = RBox.new
      [1, 2].any? { |x| o.touch(x) == 2 }
    end

    def p_map
      o = RBox.new
      [1, 2].map { |x| o.touch(x) * 10 }
    end

    def p_max_by
      o = RBox.new
      [1, 2].max_by { |x| o.touch(x) }
    end

    def p_sum
      o = RBox.new
      [1, 2].sum { |x| o.touch(x) }
    end

    def p_group_by
      o = RBox.new
      [1, 2].group_by { |x| o.touch(x) }
    end

    def p_max
      o = RBox.new
      [1, 2].max { |a, b| o.touch(a) <=> b }
    end

    def p_each_self_keep
      o = RBox.new
      RSelfKeep.new.each { |x| o.touch(x) }
      nil
    end

    # Escapes: each shape the analysis must not prove.
    def n_user_map
      o = RBox.new
      k = RKeep.new
      k.map { |x| o.touch(x) }
      k
    end

    def n_bag_map
      o = RBox.new
      RBag.new.map { |x| o.touch(x) }
    end

    def n_sub_each
      o = RBox.new
      RSubA.new([1]).each { |x| o.touch(x) }
      nil
    end

    def n_map_ivar
      o = RBox.new
      [1].map { |x| @h = o; x }
    end

    def n_map_closure
      o = RBox.new
      [1].map { |x| @p = proc { o }; x }
    end

    def n_unknown_receiver(a)
      o = RBox.new
      a.map { |x| o.touch(x) }
    end

    def n_mixed_receiver(c)
      o = RBox.new
      x = c ? [1] : RBag.new
      x.map { |v| o.touch(v) }
    end

    def n_argument_keeps(a)
      o = RBox.new
      [1].each { |x| a.keep(o) }
      nil
    end
  end
RUBY

# The program the behaviour half compiles and runs: confined shapes whose blocks run inside the call, an unknown
# receiver, and an object kept by an unknown callee.
RUN_SRC = <<~'RUBY'
  class RBox
    def touch(x); x; end
    def keep(x); @k = x; nil; end
  end

  class RRun
    def p_max_by; o = RBox.new; [1, 2].max_by { |x| o.touch(x) }; end
    def p_min_by; o = RBox.new; [3, 1, 2].min_by { |x| o.touch(x) }; end
    def p_sum; o = RBox.new; [1, 2].sum { |x| o.touch(x) * 10 }; end
    def p_group; o = RBox.new; [1, 2].group_by { |x| o.touch(x).odd? }.to_a; end
    def p_max_cmp; o = RBox.new; [1, 2].max { |a, b| o.touch(a) <=> b }; end
    def p_count_calls; t = 0; [1, 2, 3].max_by { |x| t += 1; x }; t; end
    def p_each_local; t = 0; o = RBox.new; [1, 2].each { |x| t += o.touch(x) }; t; end
    def p_map_local; o = RBox.new; [1, 2].map { |x| o.touch(x) * 3 }; end
    def p_any_local; o = RBox.new; [1, 2].any? { |x| o.touch(x) == 2 }; end
    def p_unknown(a); o = RBox.new; a.max_by { |x| o.touch(x) }; end
    def p_keeps(a); o = RBox.new; [1].each { |x| a.keep(o) }; nil; end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = RRun.new
  box = RBox.new
  [[:p_max_by], [:p_min_by], [:p_sum], [:p_group], [:p_max_cmp], [:p_count_calls], [:p_each_local],
   [:p_map_local], [:p_any_local], [:p_unknown, [[4, 9]]], [:p_keeps, [box]]].each do |name, args|
    out = begin
      fx.__send__(name, *(args || [])).inspect
    rescue NoMethodError, ArgumentError, TypeError => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  puts 'end'
RUBY

# The block kind of each confined method's block send, in the escape report's `kind` column.
CONFINED_BLOCKS = { 'p_each_count' => 'block:each', 'p_each_with_index' => 'block:each_with_index',
                    'p_any' => 'block:any?', 'p_map' => 'block:map', 'p_max_by' => 'block:max_by',
                    'p_sum' => 'block:sum', 'p_group_by' => 'block:group_by', 'p_max' => 'block:max' }.freeze

# [kind, verdict, reason] of each creation site of method +name+ in the escape report.
def verdicts(rows, name)
  rows.select { |r| r[0] == 'site' && r[2] == "RFlow##{name}" }.map { |r| [r[5], r[6], r[7]] }
end

def site?(rows, name, kind, verdict, reason = nil)
  verdicts(rows, name).any? { |k, v, why| k == kind && v == verdict && (reason.nil? || why == reason) }
end

puts '-- escape verdicts (generation)'
verdict_dir = Dir.mktmpdir('bc2cpp-escape-flow')
begin
  tsv = File.join(verdict_dir, 'escape.tsv')
  saved = ENV.fetch('BC2CPP_ESCAPE_REPORT', nil)
  ENV['BC2CPP_ESCAPE_REPORT'] = tsv
  begin
    Bc2cppFixtureRuntime.generate(VERDICT_SRC, verdict_dir, core: true, only_owners: %w[RFlow])
  ensure
    saved.nil? ? ENV.delete('BC2CPP_ESCAPE_REPORT') : ENV['BC2CPP_ESCAPE_REPORT'] = saved
  end
  rows = File.readlines(tsv, chomp: true).map { |line| line.split("\t", -1) }
  check.call('the report has the RFlow creation sites', rows.count { |r| r[2].to_s.start_with?('RFlow#') } >= 20)

  CONFINED_BLOCKS.each do |name, kind|
    check.call("#{name}: its block is confined", site?(rows, name, kind, 'confined'))
    check.call("#{name}: its object is confined", site?(rows, name, 'object', 'confined'))
  end
  check.call('p_each_self_keep: its object is confined', site?(rows, 'p_each_self_keep', 'object', 'confined'))
  check.call('p_each_self_keep: the receiver that stores self still escapes (send_receiver)',
             site?(rows, 'p_each_self_keep', 'object', 'escapes', 'send_receiver'))

  check.call('n_user_map: the user map keeps its block, so the object escapes',
             site?(rows, 'n_user_map', 'object', 'escapes', 'captured_by_escaping_closure'))
  check.call('n_bag_map: an Enumerable whose each keeps its block escapes',
             site?(rows, 'n_bag_map', 'block:map', 'escapes') && site?(rows, 'n_bag_map', 'object', 'escapes'))
  check.call('n_sub_each: a subclass each that keeps its block escapes', site?(rows, 'n_sub_each', 'object', 'escapes'))
  check.call('n_map_ivar: a block that stores the object in an ivar escapes',
             site?(rows, 'n_map_ivar', 'object', 'escapes'))
  check.call('n_map_closure: a block that stores a closure over the object escapes',
             site?(rows, 'n_map_closure', 'object', 'escapes'))
  check.call('n_unknown_receiver: a parameter receiver keeps the block escaping',
             site?(rows, 'n_unknown_receiver', 'block:map', 'escapes') && site?(rows, 'n_unknown_receiver', 'object', 'escapes'))
  check.call('n_mixed_receiver: a receiver of two classes keeps the block escaping',
             site?(rows, 'n_mixed_receiver', 'block:map', 'escapes'))
  check.call('n_argument_keeps: an object passed to an unknown callee escapes',
             site?(rows, 'n_argument_keeps', 'object', 'escapes', 'send_argument'))
ensure
  FileUtils.remove_entry(verdict_dir)
end

puts '-- behaviour (needs a full-core libmruby)'
build = Bc2cppFixtureRuntime.full_or_build
if build.nil?
  puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
else
  run_dir = Dir.mktmpdir('bc2cpp-escape-flow-run')
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
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
      check.call('p_max_by picks the largest element through the confined block', interpreted.include?('p_max_by: 2'))
      check.call('p_min_by picks the smallest element', interpreted.include?('p_min_by: 1'))
      check.call('p_sum sums the block values', interpreted.include?('p_sum: 30'))
      check.call('p_count_calls: the block mutates the caller local once per element', interpreted.include?('p_count_calls: 3'))
      check.call('p_each_local sums through the block', interpreted.include?('p_each_local: 3'))
      check.call('p_map_local maps through the block', interpreted.include?('p_map_local: [3, 6]'))
      check.call('p_unknown: an unknown receiver still runs its block', interpreted.include?('p_unknown: 9'))
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  ensure
    FileUtils.remove_entry(run_dir)
  end
end

if failures.empty?
  puts 'bc2cpp escape receiver flow check: PASS'
else
  warn "bc2cpp escape receiver flow check: #{failures.size} failure(s)"
  exit 1
end
