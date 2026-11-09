#!/usr/bin/env ruby
# frozen_string_literal: true

# KEYWORD_SPLAT_STATIC: `recv.m(a, **h)` resolves its callee at compile time and calls it directly, reading each
# keyword the callee declares from `h`. A key the callee does not declare, or a missing required keyword, raises
# ArgumentError as the interpreter does. The interpreted and compiled runs must print the same lines.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/keyword_splat_static_check.rb
require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('keyword_splat_static_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Target
    def go(a, b: 1, c:)
      [a, b, c]
    end
  end

  class Caller
    def call_with(h)
      Target.new.go(1, **h)
    end
  end
RUBY

DRIVER = <<~RUBY
  [{ c: 3 }, { c: 3, b: 5 }, { b: 2 }, { c: 1, z: 9 }].each do |h|
    begin
      puts Caller.new.call_with(h).inspect
    rescue ArgumentError => e
      puts "ArgumentError"
    end
  end
  puts 'end'
RUBY

OWNERS = %w[Target Caller].freeze

build = Bc2cppFixtureRuntime.full_or_build
check.call('a full-core libmruby builds for the parity runs', !build.nil?)
if build
  Dir.mktmpdir('keyword_splat_static') do |dir|
    sig = File.join(dir, 'sig')
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, 'kw.rbs'), "# fixture: no declarations\n")
    ENV['BC2CPP_SIG_DIRS'] = sig
    _code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: OWNERS)
    emitted = Dir.glob(File.join(dir, '**', '*.{cpp,cxx,c}')).map { |f| File.read(f) }.join("\n")
    check.call('the splat call is a direct call to Target#go (no #error, no by-name dispatch)',
               emitted.include?('Target_go_impl(') && !emitted.match?(/#error SEND\/SSEND :go/))
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
    sections = built ? Bc2cppFixtureRuntime.sections(output) : {}
    check.call('the driver runs to its end (interpreted)', sections['interpreted']&.last == 'end')
    ENV.delete('BC2CPP_SIG_DIRS')
    check.call('interpreted and compiled runs print the same',
               sections['interpreted'] && sections['interpreted'] == sections['compiled'])
    if sections['interpreted'] && sections['compiled'] && sections['interpreted'] != sections['compiled']
      sections['interpreted'].zip(sections['compiled']).reject { |a, b| a == b }.first(10).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
    end
  end
end

suite.finish!
