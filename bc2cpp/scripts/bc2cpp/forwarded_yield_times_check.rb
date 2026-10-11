#!/usr/bin/env ruby

require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
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
  class ForwardYieldOwner
    def run(size)
      size.times { |i| yield i, i * 2 }
    end
  end
RUBY

CALLER_SOURCE = <<~'RUBY'
  class ForwardYieldCaller
    def owner
      @owner
    end

    def normal(owner)
      sum = 0
      result = owner.run(3) { |i, doubled| sum += i + doubled }
      [result, sum]
    end

    def break(owner)
      owner.run(4) { |i, _doubled| break i * 10 if i == 2 }
    end

    def return(owner)
      owner.run(4) { |i, _doubled| return i + 100 if i == 1 }
    end

    def raise_error(owner)
      owner.run(4) { |i, _doubled| raise 'forwarded yield failure' if i == 2 }
    end

    def missing(owner)
      owner.run(1)
    rescue LocalJumpError
      77
    end
  end
RUBY

def body_of(code, function)
  code[/^mrb_value #{function}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'forward_yield.rb')
  caller_source = File.join(dir, 'forward_yield_caller.rb')
  caller_mrb = File.join(dir, 'forward_yield_caller.mrb')
  File.write(source, SOURCE)
  File.write(caller_source, CALLER_SOURCE)
  abort 'mrbc failed for caller fixture' unless system(MRBC_ENV, '-o', caller_mrb, caller_source)

  env = { 'MRBC' => MRBC_ENV, 'OUT_SYMBOL' => 'forward_yield', 'OUT_DIR' => dir,
          'SKIP_UNSUPPORTED' => '1', 'BC2CPP_SELF_REGISTERING' => '1' }
  out, err, status = Open3.capture3(env, RbConfig.ruby, BC2CPP, source, chdir: ROOT)
  abort "bc2cpp.rb failed:\n#{err[-3000..] || err}" unless status.success?

  run = body_of(out, 'ForwardYieldOwner_run')
  check.call('the times body is inlined', run.include?('Lbc2cpp_times_iter_'))
  check.call('the forwarded block is passed to the body', run.include?('bc2cpp_yield_argv(M, r8,'))
  check.call('the existing no-block error is preserved', run.include?('unexpected yield'))

  core = [ENV['BC2CPP_MRUBY_CORE'], *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |candidate|
    File.exist?(File.join(candidate, 'lib/libmruby_core.a')) && File.directory?(File.join(candidate, 'include'))
  end
  if core.nil?
    puts '  SKIP runtime check: set BC2CPP_MRUBY_CORE to a host mruby core directory'
  else
    File.write(File.join(dir, 'forward_yield_gen.cpp'), out)
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      #include <mruby/array.h>
      #include <mruby/irep.h>
      #include <cstdio>
      #include <fstream>
      #include <iterator>
      #include <vector>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      #include "forward_yield_gen.cpp"

      static mrb_value call_caller(mrb_state* M, mrb_value caller, mrb_sym name) {
        mrb_value owner = mrb_iv_get(M, caller, mrb_intern_lit(M, "owner"));
        return mrb_funcall_id(M, caller, name, 1, owner);
      }

      static bool integer_result(mrb_state* M, mrb_value value, mrb_int expected) {
        return !M->exc && mrb_integer_p(value) && mrb_integer(value) == expected;
      }

      int main(int argc, char** argv) {
        mrb_state* M = mrb_open_core();
        for (int i = 1; i < argc; ++i) {
          std::ifstream in(argv[i], std::ios::binary);
          std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
          mrb_load_irep_buf(M, bin.data(), bin.size());
          if (M->exc) { mrb_print_error(M); return 2; }
        }
        bc2cpp_set_instance_tts(M);
        RClass* owner_class = mrb_class_get(M, "ForwardYieldOwner");
        mrb_define_method(M, owner_class, "run", ForwardYieldOwner_run,
                          MRB_ARGS_REQ(1) | MRB_ARGS_BLOCK());
        RClass* caller_class = mrb_class_get(M, "ForwardYieldCaller");
        mrb_value caller = mrb_obj_new(M, caller_class, 0, nullptr);
        mrb_value owner = mrb_obj_new(M, owner_class, 0, nullptr);
        mrb_iv_set(M, caller, mrb_intern_lit(M, "owner"), owner);

        mrb_value normal = call_caller(M, caller, mrb_intern_lit(M, "normal"));
        bool normal_ok = !M->exc && mrb_array_p(normal) && RARRAY_LEN(normal) == 2 &&
                         integer_result(M, mrb_ary_ref(M, normal, 0), 3) &&
                         integer_result(M, mrb_ary_ref(M, normal, 1), 9);
        std::printf("  normal forwarded yield -> %s (result=%d sum=%d)\\n", normal_ok ? "ok" : "WRONG",
                    mrb_integer_p(normal) ? mrb_integer(normal) : -1,
                    mrb_array_p(normal) && RARRAY_LEN(normal) > 1 && mrb_integer_p(mrb_ary_ref(M, normal, 1)) ? mrb_integer(mrb_ary_ref(M, normal, 1)) : -1);

        mrb_value break_value = call_caller(M, caller, mrb_intern_lit(M, "break"));
        bool break_ok = integer_result(M, break_value, 20);
        std::printf("  block break -> %s\\n", break_ok ? "ok" : "WRONG");

        mrb_value return_value = call_caller(M, caller, mrb_intern_lit(M, "return"));
        bool return_ok = integer_result(M, return_value, 101);
        std::printf("  method return -> %s\\n", return_ok ? "ok" : "WRONG");

        mrb_value raised = call_caller(M, caller, mrb_intern_lit(M, "raise_error"));
        bool raise_ok = M->exc != nullptr;
        M->exc = nullptr;
        std::printf("  exception propagation -> %s\\n", raise_ok ? "ok" : "WRONG");

        mrb_value recovered = call_caller(M, caller, mrb_intern_lit(M, "missing"));
        bool missing_ok = integer_result(M, recovered, 77);
        std::printf("  missing block recovery -> %s\\n", missing_ok ? "ok" : "WRONG");

        mrb_value again = call_caller(M, caller, mrb_intern_lit(M, "normal"));
        bool reusable_ok = !M->exc && mrb_array_p(again) && RARRAY_LEN(again) == 2 &&
                           integer_result(M, mrb_ary_ref(M, again, 0), 3) &&
                           integer_result(M, mrb_ary_ref(M, again, 1), 9);
        std::printf("  post-exception reuse -> %s\\n", reusable_ok ? "ok" : "WRONG");

        mrb_close(M);
        return normal_ok && break_ok && return_ok && raise_ok && missing_ok && reusable_ok ? 0 : 1;
      }
    CPP
    binary = File.join(dir, 'forward_yield')
    built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w',
                   "-I#{dir}", "-I#{core}/include", "-I#{ROOT}/3rd/mruby/include", File.join(dir, 'main.cpp'),
                   "#{core}/lib/libmruby_core.a", '-lm', '-o', binary)
    check.call('the forwarded-yield fixture compiles against real mruby', built)
    if built
      output = IO.popen([binary, File.join(dir, 'forward_yield.mrb'), caller_mrb], err: %i[child out], &:read)
      puts output
      check.call('the forwarded block preserves normal, break, return, exception, and recovery behavior', $?.success?)
    end
  end
end

if failures.empty?
  puts 'bc2cpp forwarded-yield times check: PASS'
else
  warn "bc2cpp forwarded-yield times check: #{failures.size} failure(s)"
  exit 1
end
