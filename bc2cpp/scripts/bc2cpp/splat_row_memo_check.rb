#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# SPLAT_ROW_MEMO (tools/bc2cpp/codegen_computed_send.rb): a guarded `send(*recv[i])` remembers, per index, the arm
# of a list of immediates and takes it again while the list is bit-identical.
#
#   generated code (needs a host mrbc)
#     - `send(*TABLE[i])` and `send(*t[i])` on any receiver get the memo; `send(*list)` without an index does not;
#     - BC2CPP_SPLAT_ROW_MEMO=0 keeps the length and Symbol tables alone.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for frozen and unfrozen rows, rows written in place (name,
#       argument, length), outer slots replaced, two tables sharing an index, Hash tables, non-immediate and Float
#       elements, indices out of range, negative or beyond the memo, a non-Integer index, a subclass that redefines a
#       target, and an arm that refills its own entry before it returns.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/splat_row_memo_check.rb

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
  class RmCpu
    FROZEN = [[:op_a].freeze, [:op_b, 5].freeze, [:op_c, 2, 3].freeze, [:op_d, :x, nil, true].freeze].freeze
    LOOSE = [[:op_a], [:op_b, 1], [:op_c, 4, 5], [:op_d, false, 1.5, -0.0], [:op_s, 'abc'], [:op_q, 1]]
    MUT = []
    BIG = Array.new(300) { |i| [:op_b, i] }

    def self.fill
      MUT[0] = [:op_a]
      MUT[1] = [:op_b, 7]
      MUT[2] = [:op_r, 2]
    end
    fill

    attr_reader :log

    def initialize
      @log = []
    end

    def op_a
      @log << :a
      :a
    end

    def op_b(x) = [:b, x]
    def op_c(x, y) = x + y
    def op_d(a, b, c) = [a, b, c]
    def op_s(s) = s.size

    # Rewrites its own row, then re-enters the site through it: the entry is refilled before this arm returns.
    def op_r(n)
      return [:r, n] if n.zero?

      MUT[2] = [:op_r, n - 1]
      [:r, n, run_mut(2)]
    end

    def run_frozen(i) = send(*FROZEN[i])
    def run_loose(i) = send(*LOOSE[i])
    def run_mut(i) = send(*MUT[i])
    def run_big(i) = send(*BIG[i])
    def run_any(t, i) = send(*t[i])
    def run_list(list) = send(*list)
  end

  class RmSub < RmCpu
    def op_b(x) = [:sub_b, x]
  end
RUBY

OWNERS = %w[RmCpu RmSub].freeze

def code_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

def generate_world(env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

baseline_dir = Dir.mktmpdir('bc2cpp-splat-row-memo')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('no #error in the generated code', !code.include?('#error'))
%w[run_frozen run_loose run_mut run_big run_any].each do |name|
  body = code_of(code, "RmCpu_#{name}")
  check.call("#{name}: the guarded splat keyed by its index takes the memo",
             body.include?('// COMPUTED_SEND_GUARDED :send n=*') && body.include?('// SPLAT_ROW_MEMO') &&
               body.include?('// SPLAT_SHARED'))
end
memo = code_of(code, 'RmCpu_run_loose')
check.call('the memo compares the list bit for bit and reads the arguments from its copy',
           memo.include?('return a.w == b.w;') && memo.include?('case 1: hit = same(p[0], e.v[0]);') && memo.match?(/_argv = e\.v \+ 1;/) &&
             memo.match?(/if \(\w+_arm != 0 && \w+_shared && \w+_keyed\)/))
check.call('the original send keeps its copy of the list', memo.scan('mrb_ary_splat(').size == 2)
list = code_of(code, 'RmCpu_run_list')
check.call('run_list: a list without an index keeps the tables alone',
           list.include?('// COMPUTED_SEND_GUARDED :send n=*') && !list.include?('SPLAT_ROW_MEMO'))
off, = generate_world({ 'BC2CPP_SPLAT_ROW_MEMO' => '0' })
check.call('BC2CPP_SPLAT_ROW_MEMO=0 emits no memo and keeps the guarded splat',
           !off.include?('SPLAT_ROW_MEMO') && code_of(off, 'RmCpu_run_loose').include?('// COMPUTED_SEND_GUARDED :send n=*'))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  c = RmCpu.new
  s = RmSub.new
  show.call('frozen') { 3.times.map { (0..3).map { |i| c.run_frozen(i) } } }
  show.call('frozen out of range') { [c.run_frozen(4), c.run_frozen(300)] }
  show.call('frozen negative') { 2.times.map { [c.run_frozen(-1), c.run_frozen(-4)] } }
  show.call('frozen float index') { c.run_frozen(1.0) }
  show.call('frozen string index') { c.run_frozen('1') }
  show.call('loose') { 3.times.map { (0..5).map { |i| c.run_loose(i) } } }
  show.call('loose sign of zero') { 1.0 / c.run_loose(3)[2] }
  show.call('mut') { 2.times.map { [c.run_mut(0), c.run_mut(1)] } }
  show.call('mut argument') { RmCpu::MUT[1][1] = 9; [c.run_mut(1), c.run_mut(1)] }
  show.call('mut name') { RmCpu::MUT[1][0] = :op_s; RmCpu::MUT[1][1] = 'hello'; [c.run_mut(1), c.run_mut(1)] }
  show.call('mut length') { RmCpu::MUT[1].replace([:op_c, 3, 4]); [c.run_mut(1), c.run_mut(1)] }
  show.call('mut shrink') { RmCpu::MUT[1].pop; RmCpu::MUT[1].pop; c.run_mut(1) }
  show.call('mut outer') { RmCpu::MUT[1] = [:op_d, 1, 2, 3]; [c.run_mut(1), c.run_mut(1)] }
  show.call('mut unknown name') { RmCpu::MUT[1] = [:nope, 1]; c.run_mut(1) }
  show.call('mut non-symbol') { RmCpu::MUT[1] = ['op_b', 1]; c.run_mut(1) }
  show.call('mut empty') { RmCpu::MUT[1] = []; c.run_mut(1) }
  show.call('mut nil row') { RmCpu::MUT[1] = nil; c.run_mut(1) }
  show.call('mut back') { RmCpu::MUT[1] = [:op_b, 7]; [c.run_mut(1), c.run_mut(1)] }
  show.call('reentrant') { RmCpu.fill; [c.run_mut(2), c.run_mut(2), RmCpu::MUT[2]] }
  show.call('big') { [c.run_big(3), c.run_big(255), c.run_big(256), c.run_big(299), c.run_big(255), c.run_big(256)] }
  t1 = [[:op_a], [:op_b, 1]]
  t2 = [[:op_b, 2], [:op_c, 1, 2]]
  show.call('shared index') { 3.times.map { [c.run_any(t1, 0), c.run_any(t2, 0), c.run_any(t1, 1), c.run_any(t2, 1)] } }
  h = { 0 => [:op_b, :h], 1 => [:op_a] }
  show.call('hash') { 2.times.map { [c.run_any(h, 0), c.run_any(h, 1), c.run_any(h, 2)] } }
  show.call('objects') do
    GC.stress = true if GC.respond_to?(:stress=)
    r = 3.times.map { |k| c.run_any([[:op_d, "s#{k}", [k], { k => k }]], 0) }
    GC.stress = false if GC.respond_to?(:stress=)
    r
  end
  # No over-long row: the runner registers every compiled method MRB_ARGS_ANY, so the original send's wrapper would
  # accept it whichever way the send went (computed_send_check.rb).
  show.call('private') { c.run_any([[:initialize]], 0) }
  show.call('subclass') { 2.times.map { [s.run_loose(1), s.run_frozen(1), c.run_loose(1), s.run_loose(2)] } }
  show.call('list') { [c.run_list([:op_b, 3]), c.run_list([:op_a])] }
  show.call('log') { c.log.size }
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
        const char* src = R"SRM(#{DRIVER})SRM";
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
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp splat row memo check: PASS'
else
  warn "bc2cpp splat row memo check: #{failures.size} failure(s)"
  exit 1
end
