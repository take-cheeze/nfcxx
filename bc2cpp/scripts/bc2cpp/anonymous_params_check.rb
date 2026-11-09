#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# ANONYMOUS_PARAM (tools/bc2cpp/codegen_method.rb c_param_name): mrbc names an anonymous parameter by its sigil, so
# `def inject(*)` used to come out as `mrb_value r1 = *;`, C++ that does not compile. The parameter now gets a
# generated name.
#
#   generated code (needs a host mrbc)
#     - anonymous `*` (alone, after a required parameter, forwarded) and `&` (alone, forwarded) compile, with no `*`
#       or `&` left where a parameter name goes, and `def f(arg2, *)` keeps its two parameters apart;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same, `**` and `...` (which stay interpreted) included.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/anonymous_params_check.rb

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
  class ApBox
    def g(*a, **k, &b); [a, k, b ? b.call : :noblk]; end
    def rest(*); :rest; end
    def rest1(x, *); x; end
    def rest_fwd(*); g(*); end
    def clash(arg2, *); arg2; end
    def kw(**); :kw; end
    def kw_fwd(**); g(**); end
    def blk(&); :blk; end
    def blk_fwd(&); g(&); end
    def all(a, *, **, &); [a, g(*, **, &)]; end
    def dots(...); g(...); end
    def inject(*); [:inject, block_given?]; end
  end
RUBY

OWNERS = %w[ApBox].freeze
COMPILED = %w[rest rest1 rest_fwd clash blk blk_fwd].freeze

def method_code(code, name)
  code[/^mrb_value #{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

dir = Dir.mktmpdir('bc2cpp-anonymous-params')
at_exit { FileUtils.remove_entry(dir) }
puts '-- generated code'
code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS)
check.call('no #error in the generated code', !code.include?('#error'))
COMPILED.each do |name|
  body = method_code(code, "ApBox_#{name}")
  check.call("ApBox##{name}: compiled, no sigil where a parameter name goes",
             !body.empty? && !body.match?(/mrb_value [*&]+[ ,;)=]|= [*&]+;|, [*&]+\)/))
end
check.call('ApBox#rest: the anonymous rest gets a generated name',
           method_code(code, 'ApBox_rest').include?('mrb_value bc2cpp_anon_arg1'))
check.call('ApBox#clash: `arg2` and the anonymous rest stay two parameters',
           method_code(code, 'ApBox_clash').include?('mrb_value arg2, mrb_value bc2cpp_anon_arg2'))

DRIVER = <<~'RUBY'
  o = ApBox.new
  blk = proc { :yes }
  rows = [
    -> { o.rest }, -> { o.rest(1, 2) }, -> { o.rest1(5, 6, 7) }, -> { o.rest1 }, -> { o.rest_fwd(1, 2) },
    -> { o.rest_fwd }, -> { o.clash(:a, :b, :c) }, -> { o.kw }, -> { o.kw(a: 1) }, -> { o.kw_fwd(a: 1, b: 2) },
    -> { o.kw_fwd }, -> { o.blk }, -> { o.blk(&blk) }, -> { o.blk_fwd(&blk) }, -> { o.blk_fwd },
    -> { o.all(0, 1, 2, z: 3, &blk) }, -> { o.all(0) }, -> { o.dots(1, q: 2, &blk) }, -> { o.dots },
    -> { o.inject(1, 2) }, -> { o.inject { 1 } }
  ]
  rows.each_with_index do |row, i|
    begin
      puts "#{i}: #{row.call.inspect}"
    rescue StandardError => e
      puts "#{i}: #{e.class}: #{e.message}"
    end
  end
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
        const char* src = R"APD(#{DRIVER})APD";
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
  puts 'bc2cpp anonymous params check: PASS'
else
  warn "bc2cpp anonymous params check: #{failures.size} failure(s)"
  exit 1
end
