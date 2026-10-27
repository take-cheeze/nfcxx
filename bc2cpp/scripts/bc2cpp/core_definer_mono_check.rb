#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# CORE_UNSEEN_DEFINERS (tools/bc2cpp/core_defs.rb add_unseen_placeholders!): a name the program defines only on an
# Array/Hash subclass (or a module the subclass includes) is still answered by mruby's own Ruby on every plain
# Array/Hash, so MONO must not bind it to the program's definition.
#
#   generated code (needs a host mrbc)
#     - with and without the core mrblib compiled, no call site binds `map`, `collect`, `reject`, `each_with_index`,
#       `sort_by` or `each_pair` MONO to the subclass body, and the registry log flips each of them to POLY;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - with the core mrblib compiled, as every build does, interpreted and compiled runs print the same for a plain
#       Array/Hash and for the subclass receiver. The world without it lists no outside owner for a core gem's
#       mrblib (BC2CPP_PROGRAM_CORE_MRBLIB_GEMS counts as program Ruby), so its owner-checked call would raise.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/core_definer_mono_check.rb

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
  module CmMix
    def select; [:mixin_select]; end
  end
  class CmList < Array
    include CmMix
    def map; r = []; each { |x| r << [:sub, x] }; r; end
    def collect; [:sub_collect]; end
    def reject; [:sub_reject]; end
    def each_with_index; [:sub_ewi]; end
    def sort_by; [:sub_sort_by]; end
  end
  class CmHash < Hash
    def each_pair; [:sub_each_pair]; end
  end
  class CmUse
    def map_(a); a.map { |x| x * 2 }; end
    def collect_(a); a.collect { |x| x + 1 }; end
    def select_(a); a.select { |x| x > 1 }; end
    def reject_(a); a.reject { |x| x > 1 }; end
    def ewi(a); r = []; a.each_with_index { |x, i| r << [x, i] }; r; end
    def sort_by_(a); a.sort_by { |x| -x }; end
    def each_pair_(h); r = []; h.each_pair { |k, _v| r << k }; r; end
  end
RUBY

OWNERS = %w[CmMix CmList CmHash CmUse].freeze
SUBCLASS_ONLY = { 'map' => 'CmList', 'collect' => 'CmList', 'reject' => 'CmList', 'each_with_index' => 'CmList',
                  'sort_by' => 'CmList', 'each_pair' => 'CmHash' }.freeze

dirs = { core: Dir.mktmpdir('bc2cpp-core-definer'), plain: Dir.mktmpdir('bc2cpp-core-definer-plain') }
at_exit { dirs.each_value { |dir| FileUtils.remove_entry(dir) } }
generated = {}
dirs.each do |world, dir|
  puts "-- generated code (#{world == :core ? 'core mrblib compiled' : 'core mrblib outside'})"
  code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: world == :core, only_owners: OWNERS)
  generated[world] = [code, err]
  check.call('no #error in the generated code', !code.include?('#error'))
  SUBCLASS_ONLY.each do |name, owner|
    check.call("no call site binds :#{name} MONO to #{owner}##{name}", !code.include?("MONO :#{name} -> #{owner}#"))
    check.call(":#{name} is POLY in the registry (#{owner} and the core definer)",
               err.match?(/^  POLY  :#{Regexp.escape(name)}  \(\d+ defs: [^)]*#{owner}/) &&
                 err.match?(/^  FLIP :#{Regexp.escape(name)}$/))
  end
end

DRIVER = <<~'RUBY'
  u = CmUse.new
  a = [1, 2, 3]
  l = CmList.new
  l << 1 << 2
  show = lambda do |m, x|
    out = begin
      u.send(m, x).inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{m}(#{x.class}): #{out}"
  end
  %i[map_ collect_ select_ reject_ ewi sort_by_].each do |m|
    show.call(m, a)
    show.call(m, l)
  end
  show.call(:each_pair_, { 1 => 2 })
  show.call(:each_pair_, CmHash.new)
  puts 'end'
RUBY

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"CDF(#{DRIVER})CDF";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    dirs.slice(:core).each do |world, dir|
      puts "-- fixtures on real mruby, interpreted and compiled (#{world})"
      built, output = Bc2cppFixtureRuntime.run(dir, generated[world][1], OWNERS, body, build: build, full: true)
      check.call('the fixtures build and run', built)
      sections = Bc2cppFixtureRuntime.sections(output)
      interpreted = sections['interpreted']
      compiled = sections['compiled']
      check.call("the driver prints #{interpreted&.size} lines in both runs",
                 interpreted && interpreted.last == 'end' && compiled&.last == 'end')
      check.call('interpreted and compiled runs print the same', interpreted == compiled)
      if interpreted && compiled
        interpreted.zip(compiled).reject { |x, y| x == y }.first(10).each do |x, y|
          puts "    interpreted: #{x}\n    compiled:    #{y}"
        end
      end
      puts output.lines.last(30).join unless built && interpreted && compiled
    end
  end
end

if failures.empty?
  puts 'bc2cpp core definer mono check: PASS'
else
  warn "bc2cpp core definer mono check: #{failures.size} failure(s)"
  exit 1
end
