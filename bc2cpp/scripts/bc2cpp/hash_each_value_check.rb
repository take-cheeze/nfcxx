#!/usr/bin/env ruby
# encoding: UTF-8

require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative 'cxx'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC_ENV = ENV['MRBC'] || 'mrbc'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~'RUBY'
  class HashValueInlineOwner
    def initialize
      @values = {}
      @values[:a] = 1
      @values[:b] = 2
      @values[:c] = 3
    end

    def sum
      total = 0
      @values.each_value { |value| total += value }
      total
    end

    def first_value
      @values.each_value { |value| break value if value == 2 }
    end

    def value_type(value)
      value.each_value { |item| item.to_s }
      value.class
    end
  end

  class ForeignHashLike
    def each_value
      yield 1
      self
    end
  end
RUBY

def body_of(code, function)
  code[/^mrb_value #{function}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'hash_each_value.rb')
  generated = File.join(dir, 'hash_each_value_gen.cpp')
  File.write(source, SOURCE)
  env = { 'MRBC' => MRBC_ENV, 'OUT_SYMBOL' => 'hash_each_value', 'OUT_DIR' => dir,
          'SKIP_UNSUPPORTED' => '1', 'BC2CPP_SELF_REGISTERING' => '1' }
  _out, err, status = Open3.capture3(env, "#{RbConfig.ruby.shellescape} #{BC2CPP.shellescape} " \
                                          "#{source.shellescape} > #{generated.shellescape}")
  abort "bc2cpp.rb failed:\n#{err[-3000..]}" unless status.success?

  code = File.read(generated)
  sum = body_of(code, 'HashValueInlineOwner_sum')
  first = body_of(code, 'HashValueInlineOwner_first_value')
  type = body_of(code, 'HashValueInlineOwner_value_type')

  check.call('a clean Hash#each_value becomes an inline loop', sum.include?('Hash receiver for inlined #each_value') &&
               sum.include?('bc2cpp_heval_values_') && !sum.include?('BLOCK_FALLBACK :each_value'))
  check.call('the inline loop snapshots values once before iteration',
             sum.scan('mrb_hash_values(M,').size == 1 &&
               sum.include?('RARRAY_LEN(bc2cpp_heval_values_'))
  check.call('the inline loop leaves the Hash as the method result', sum.include?('return r2;'))
  check.call('break keeps the break value as the result', first.include?('goto Lbc2cpp_heval_end_') &&
               first.include?('r2 = r') && !first.include?('BLOCK_FALLBACK :each_value'))
  check.call('a non-Hash argument is not inlined', type.include?('BLOCK_FALLBACK :each_value') &&
               !type.include?('Hash receiver for inlined #each_value'))
  check.call('the fallback marker remains for the non-Hash case', type.include?('mrb_funcall_with_block'))
end

core = [ENV['BC2CPP_MRUBY_CORE'], *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |dir|
  File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include'))
end
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP runtime check: set BC2CPP_MRUBY_CORE to a host mruby core directory'
else
  Dir.mktmpdir do |dir|
    source = File.join(dir, 'hash_each_value.rb')
    generated = File.join(dir, 'hash_each_value_gen.cpp')
    File.write(source, SOURCE)
    env = { 'MRBC' => MRBC_ENV, 'OUT_SYMBOL' => 'hash_each_value', 'OUT_DIR' => dir,
            'SKIP_UNSUPPORTED' => '1', 'BC2CPP_SELF_REGISTERING' => '1' }
    _out, err, status = Open3.capture3(env, "#{RbConfig.ruby.shellescape} #{BC2CPP.shellescape} " \
                                            "#{source.shellescape} > #{generated.shellescape}")
    abort "bc2cpp.rb failed:\n#{err[-3000..]}" unless status.success?
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      #include <mruby/irep.h>
      #include <cstdio>
      #include <fstream>
      #include <iterator>
      #include <vector>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      #include "hash_each_value_gen.cpp"
      static int failed = 0;
      static void expect_integer(mrb_state* M, mrb_value got, int want, const char* name) {
        bool ok = !M->exc && mrb_integer_p(got) && mrb_integer(got) == want;
        std::printf("  %s -> %s\\n", name, ok ? "ok" : "WRONG");
        failed += !ok;
        M->exc = nullptr;
      }
      int main(int, char** argv) {
        mrb_state* M = mrb_open_core();
        std::ifstream in(argv[1], std::ios::binary);
        std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        mrb_load_irep_buf(M, bin.data(), bin.size());
        if (M->exc) { mrb_print_error(M); return 2; }
        bc2cpp_set_instance_tts(M);
        RClass* owner = mrb_class_get(M, "HashValueInlineOwner");
        mrb_define_method(M, owner, "initialize", HashValueInlineOwner_initialize, MRB_ARGS_NONE());
        mrb_define_method(M, owner, "sum", HashValueInlineOwner_sum, MRB_ARGS_NONE());
        mrb_define_method(M, owner, "first_value", HashValueInlineOwner_first_value, MRB_ARGS_NONE());
        mrb_define_method(M, owner, "value_type", HashValueInlineOwner_value_type, MRB_ARGS_REQ(1));
        mrb_value instance = mrb_obj_new(M, owner, 0, nullptr);
        expect_integer(M, mrb_funcall(M, instance, "sum", 0), 6, "sum");
        expect_integer(M, mrb_funcall(M, instance, "first_value", 0), 2, "first_value");
        mrb_value foreign = mrb_obj_new(M, mrb_class_get(M, "ForeignHashLike"), 0, nullptr);
        mrb_value result = mrb_funcall(M, instance, "value_type", 1, foreign);
        bool fallback_ok = !M->exc && mrb_equal(M, result, mrb_obj_value(mrb_class_get(M, "ForeignHashLike")));
        std::printf("  foreign receiver -> %s\\n", fallback_ok ? "ok" : "WRONG");
        failed += !fallback_ok;
        mrb_close(M);
        return failed ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'hash_each_value')
    built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w',
                   "-I#{dir}", "-I#{core}/include", "-I#{ROOT}/3rd/mruby/include", File.join(dir, 'main.cpp'),
                   "#{core}/lib/libmruby_core.a", '-lm', '-o', binary)
    check.call('the inline fixture compiles against real mruby', built)
    if built
      output = IO.popen([binary, File.join(dir, 'hash_each_value.mrb')], err: %i[child out], &:read)
      puts output
      check.call('inline values and break behavior match mruby', $?.success?)
    end
  end
end

if failures.empty?
  puts 'bc2cpp Hash#each_value check: PASS'
else
  warn "bc2cpp Hash#each_value check: #{failures.size} failure(s)"
  exit 1
end
