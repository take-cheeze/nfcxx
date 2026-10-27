#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# BRANCH_HINTS (tools/bc2cpp/branch_hints.rb, docs/bc2cpp-branch-hints.md): the compiler's own guards carry a static
# prediction, the program's own branches do not, and BC2CPP_BRANCH_HINTS=0 takes every hint out again.
#
#   generated code (needs a host mrbc)
#     - the Integer tag test of `+` and `<` is mrb_likely, the overflow tier mrb_unlikely;
#     - a TYPED / MONO_EMBED_GUARD class guard is mrb_likely, a POLY_SMALL_N chain's last else a cold arm;
#     - the ARY_WRITE_INLINE helpers' store test is mrb_likely, bc2cpp_ary_entry's bounds test mrb_unlikely;
#     - `==` (every type meets it) and the program's own `if` / `while` tests carry no hint;
#     - BC2CPP_BRANCH_HINTS=0 emits no hint and no cold arm, and differs from the hinted output only by them.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same, the fallback arms (Float, bigint, overflow, foreign
#       receivers, out-of-range indices) included.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/branch_hints_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/branch_hints'

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
  class BhCell
    def initialize(v); @v = v; end
    def get; @v; end
  end
  class BhA
    def tick; :a; end
  end
  class BhB
    def tick; :b; end
  end
  class BhC
    def tick; :c; end
  end
  class BhRun
    def add(a, b); a + b; end
    def less(a, b); a < b; end
    def same(a, b); a == b; end
    def pick(x)
      if x > 3
        :big
      else
        :small
      end
    end
    def count(n)
      i = 0
      i += 1 while i < n
      i
    end
    def cell(c); c.get; end
    def tick(o); o.tick; end
    def push(a, v); a.push(v); a.size; end
    def shl(a, v); a << v; end
    def at(a, i); a[i]; end
  end
RUBY

OWNERS = %w[BhCell BhA BhB BhC BhRun].freeze

def code_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

def generate_world(env = {}, dir: Dir.mktmpdir('bc2cpp-branch-hints'))
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS)
  [code, err, dir]
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

puts '-- generated code'
code, err, dir = generate_world
at_exit { FileUtils.remove_entry(dir) }
check.call('no #error in the generated code', !code.include?('#error'))
check.call('the prelude defines BC2CPP_COLD_ARM as a cold label', code.include?('__attribute__((cold, unused))'))
add = code_of(code, 'BhRun_add')
check.call('`a + b` predicts the Integer pair and not the overflow tier',
           add.match?(/if \(mrb_likely\(BC2CPP_FIXNUM_PAIR_P\(r\d+, r\d+\)\)\) \{/) &&
             add.include?('if (mrb_unlikely(bc2cpp_fixnum_add('))
check.call('`a < b` predicts the Integer pair',
           code_of(code, 'BhRun_less').match?(/if \(mrb_likely\(BC2CPP_FIXNUM_PAIR_P\(r\d+, r\d+\)\)\)/))
same = code_of(code, 'BhRun_same')
check.call('`a == b` keeps a bare Integer pair test: every type meets ==',
           same.match?(/if \(mrb_integer_p\(r\d+\) && mrb_integer_p\(r\d+\)\) \{/) && !same.include?('mrb_likely('))
user = code_of(code, 'BhRun_pick') + code_of(code, 'BhRun_count')
check.call('the program\'s own `if` and `while` tests carry no hint',
           user.include?('mrb_test(') && !user.match?(/mrb_(?:un)?likely\(!?mrb_test/))
check.call('a class-guarded direct call predicts its guard',
           code_of(code, 'BhRun_cell').match?(/if \(mrb_likely\(bc2cpp_owner_class_\d+\(M\) == mrb_obj_class\(M, r\d+\)\)\)/))
tick = code_of(code, 'BhRun_tick')
check.call('a POLY_SMALL_N chain\'s last else is a cold arm, its arms unhinted',
           tick.include?('POLY_SMALL_N :tick') && tick.match?(/\} else \{\n\s*BC2CPP_COLD_ARM /) &&
             !tick.match?(/mrb_likely\(bc2cpp_owner_class/))
check.call('`a.push(v)` predicts the exact-Array arm', code_of(code, 'BhRun_push').include?(
  'if (mrb_likely(mrb_array_p(r') && code.include?('if (mrb_likely(!ARY_EMBED_P(a) && !ARY_SHARED_P(a)'))
shl = code_of(code, 'BhRun_shl')
check.call('`a << v`, whose Array and Integer arms are both live, carries no hint',
           shl.include?('ARRAY_PUSH :<<') && shl.include?('INTEGER_LSHIFT :<<') && !shl.include?('mrb_likely('))
check.call('bc2cpp_ary_entry predicts the index in range',
           code.include?('if (mrb_likely((mrb_uint)n < len)) return p[n];'))

# The same directory, so the fixture paths the output spells match.
off_dir = Dir.mktmpdir('bc2cpp-branch-hints-off')
at_exit { FileUtils.remove_entry(off_dir) }
on_same, = generate_world({}, dir: off_dir)
off, = generate_world({ 'BC2CPP_BRANCH_HINTS' => '0' }, dir: off_dir)
check.call('BC2CPP_BRANCH_HINTS=0 emits no likely hint and no cold arm',
           !off.include?('mrb_likely(') && !off.include?('BC2CPP_COLD_ARM'))
# BranchHints.text with hints off unwraps every mrb_(un)likely, the guards that predate the hints included.
unhinted = lambda do |text|
  saved = ENV.fetch('BC2CPP_BRANCH_HINTS', nil)
  ENV['BC2CPP_BRANCH_HINTS'] = '0'
  BranchHints.text(text.sub(BranchHints::PRELUDE, ''))
ensure
  saved.nil? ? ENV.delete('BC2CPP_BRANCH_HINTS') : ENV['BC2CPP_BRANCH_HINTS'] = saved
end
check.call('BC2CPP_BRANCH_HINTS=0 differs from the hinted output only by the hints',
           on_same != off && unhinted.call(on_same) == unhinted.call(off))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  r = BhRun.new
  show.call('add') { [r.add(1, 2), r.add(1.5, 2), r.add(2, 0.5), r.add('a', 'b'), r.add(1 << 62, 1 << 62), r.add([1], [2])] }
  show.call('add overflow') { r.add(0x3fff_ffff_ffff_ffff, 1) }
  show.call('add nil') { r.add(nil, 1) }
  show.call('less') { [r.less(1, 2), r.less(2, 1), r.less(1.5, 2), r.less(2, 1.5), r.less('a', 'b'), r.less(1 << 70, 1)] }
  show.call('less nil') { r.less(1, nil) }
  show.call('same') { [r.same(1, 1), r.same(1, 1.0), r.same(:a, :a), r.same('a', 'a'), r.same(nil, false)] }
  show.call('pick') { [r.pick(5), r.pick(1), r.pick(3.5)] }
  show.call('count') { [r.count(0), r.count(5), r.count(2.5)] }
  show.call('cell') { r.cell(BhCell.new(7)) }
  show.call('cell other') { r.cell(BhA.new) }
  show.call('tick') { [r.tick(BhA.new), r.tick(BhB.new), r.tick(BhC.new)] }
  show.call('tick other') { r.tick(1) }
  show.call('push') { a = []; [r.push(a, 1), r.push(a, :x), r.push(a, nil), a] }
  show.call('push frozen') { r.push([1].freeze, 2) }
  show.call('push other') { r.push(BhA.new, 'c') }
  show.call('shl') { a = []; [r.shl(a, 1), r.shl(1, 3), r.shl(+'ab', 'c'), r.shl(1, -70)] }
  show.call('at') { [r.at([1, 2, 3], 1), r.at([1, 2, 3], -1), r.at([1, 2, 3], 9), r.at([1, 2, 3], -9), r.at({ 1 => 2 }, 1), r.at('abc', 1)] }
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
        const char* src = R"BHC(#{DRIVER})BHC";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: build, full: true)
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
  puts 'bc2cpp branch hints check: PASS'
else
  warn "bc2cpp branch hints check: #{failures.size} failure(s)"
  exit 1
end
