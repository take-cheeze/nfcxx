#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# ATTR_READER_INLINE (tools/bc2cpp/codegen_ivar_poly.rb): a devirtualized call to a synthesized attr_reader of an
# embedded ivar reads the struct field in place instead of calling the reader, behind the shared inline class read
# (CLASS_READ_INLINE, bc2cpp_class_is).
#
#   generated code (needs a host mrbc)
#     - `@conf.level` (IVAR_ACCESSOR and POLY_SMALL_N arms) is the field read behind the class-pointer test, no
#       call to the reader;
#     - a subclass override keeps its own arm calling its def; a reader reopened as a def is a def, never inlined;
#     - BC2CPP_ATTR_READER_INLINE=0 calls the reader again.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for the fast path, the subclass override, the reopened reader,
#       a nil receiver, another class answering the name, a class that does not, an unset ivar, an ivar set by
#       reflection and a non-Integer value. (A singleton `level` defined outside the closed world is not covered:
#       the guard this inherits already lets it through, see docs/bc2cpp-attr-reader-inline.md.)
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/attr_reader_inline_check.rb

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
  class ArConf
    attr_reader :level, :tag, :late
    def initialize(level)
      @level = level
      @tag = :conf
    end
    def set_late(v); @late = v; self; end
  end
  class ArLoud < ArConf
    def level; 9; end
  end
  class ArOther
    def level; :other; end
  end
  class ArDeep
    attr_reader :depth
    def initialize(d); @depth = d; end
  end
  class ArDeep
    def depth; @depth * 2; end
  end
  class ArCpu
    def initialize(conf, deep)
      @conf = conf
      @deep = deep
      @hits = 0
    end
    def run(k)
      i = 0
      while i < k
        @hits += 1 if @conf.level >= 3
        i += 1
      end
      @hits
    end
    def tag_of(c); c.tag; end
    def late_of(c); c.late; end
    def deep_of; @deep.depth; end
  end
RUBY

OWNERS = %w[ArConf ArLoud ArOther ArDeep ArCpu].freeze

def code_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

def inline_read?(code, ivar)
  code.match?(/ArConf_ivars\*\)DATA_PTR\(r\d+\)\)->ivar_#{ivar}\)?[^;]*; \/\* ATTR_READER_INLINE \*\//)
end

def generate_world(env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

baseline_dir = Dir.mktmpdir('bc2cpp-attr-reader-inline')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
run = code_of(code, 'ArCpu_run')
check.call('@conf.level reads the field in place (no reader call)',
           inline_read?(run, 'level') && !run.include?('ArConf_level_impl(M'))
check.call('its guard tests the class inline (bc2cpp_class_is)',
           run.match?(/bc2cpp_class_is\(M, r\d+, bc2cpp_owner_class_\d+\(M\)\)/) && !run.include?('mrb_obj_class(M'))
check.call('the subclass override keeps its own arm calling its def', run.include?('ArLoud_level_impl(M'))
check.call('the other class answering the name keeps its arm', run.include?('ArOther_level_impl(M'))
tag = code_of(code, 'ArCpu_tag_of')
check.call('a single-definition reader on an argument is inlined too', inline_read?(tag, 'tag'))
deep = code_of(code, 'ArCpu_deep_of')
check.call('a reader reopened as a def is never inlined',
           !deep.include?('ATTR_READER_INLINE') && !deep.include?('->ivar_depth'))
check.call('the reader itself is still emitted and registered', code.include?('mrb_value ArConf_level_impl(mrb_state* M'))
check.call('no #error in the generated code', !code.include?('#error'))
off, = generate_world({ 'BC2CPP_ATTR_READER_INLINE' => '0' })
off_run = code_of(off, 'ArCpu_run')
check.call('BC2CPP_ATTR_READER_INLINE=0 calls the reader',
           off_run.include?('ArConf_level_impl(M') && !off.include?('ATTR_READER_INLINE'))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  deep = ArDeep.new(4)
  show.call('fast') { [ArCpu.new(ArConf.new(3), deep).run(5), ArCpu.new(ArConf.new(1), deep).run(5)] }
  show.call('subclass override') { ArCpu.new(ArLoud.new(0), deep).run(4) }
  show.call('other class') { ArCpu.new(ArOther.new, deep).run(2) }
  show.call('nil receiver') { ArCpu.new(nil, deep).run(2) }
  show.call('class without the name') { ArCpu.new(Object.new, deep).run(2) }
  show.call('reopened reader') { ArCpu.new(nil, deep).deep_of }
  show.call('tag') { c = ArConf.new(2); x = ArCpu.new(c, deep); [x.tag_of(c), x.tag_of(ArLoud.new(1))] }
  show.call('tag of nil') { ArCpu.new(nil, deep).tag_of(nil) }
  show.call('unset ivar') { c = ArConf.new(2); x = ArCpu.new(c, deep); [x.late_of(c), x.late_of(c.set_late(:l))] }
  show.call('reassigned ivar') do
    c = ArConf.new(5)
    c.instance_variable_set(:@level, 1)
    ArCpu.new(c, deep).run(3)
  end
  show.call('non-integer level') { ArCpu.new(ArConf.new('x'), deep).run(1) }
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
        const char* src = R"ARI(#{DRIVER})ARI";
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
  puts 'bc2cpp attr reader inline check: PASS'
else
  warn "bc2cpp attr reader inline check: #{failures.size} failure(s)"
  exit 1
end
