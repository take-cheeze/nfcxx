#!/usr/bin/env ruby
# frozen_string_literal: true

# DIRECT_NEW_ARGS: a construction with more than 16 arguments (an unrolled literal splat) is built directly, with no
# mrb_obj_new. The interpreted and compiled runs must print the same line.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/direct_new_args_check.rb
require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('direct_new_args_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Many
    def initialize(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18)
      @s = a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15 + a16 + a17 + a18
    end

    def s; @s; end
  end

  class User
    def go
      Many.new(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18).s
    end
  end
RUBY

DRIVER = <<~RUBY
  puts User.new.go
  puts 'end'
RUBY

OWNERS = %w[Many User].freeze

build = Bc2cppFixtureRuntime.full_or_build
check.call('a full-core libmruby builds for the parity runs', !build.nil?)
if build
  Dir.mktmpdir('direct_new_args') do |dir|
    sig = File.join(dir, 'sig')
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, 'empty.rbs'), "# fixture: no declarations\n")
    ENV['BC2CPP_SIG_DIRS'] = sig
    _code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: OWNERS)
    emitted = Dir.glob(File.join(dir, '**', '*.{cpp,cxx,c}')).map { |f| File.read(f) }.join("\n")
    check.call('the 18-argument construction is direct: no mrb_obj_new, bc2cpp_direct_alloc and the compiled initialize',
               !emitted.match?(/mrb_obj_new\(M, mrb_class_ptr/) && emitted.include?('bc2cpp_direct_alloc(') &&
               emitted.include?('Many_initialize_impl('))
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
  end
end

suite.finish!
