#!/usr/bin/env ruby
# frozen_string_literal: true

# Check ADR 0394 (INTEGER_TAG_ELSE) on real mruby: an exact Array receiver's non-fixnum index runs the native Array
# body directly (mrb_ary_aget1_impl / mrb_ary_aset2_impl), and every answer is the interpreter's: the value, the
# exception class and message, and the receiver's contents after `[]=`.
#
# Needs a full-core libmruby built from this tree's 3rd/mruby (the exposed bodies come from patches/mruby-expose-index-
# bodies.patch): BC2CPP_MRUBY_FULL, or one built here with rake (BC2CPP_FULL_BUILD_DIR keeps it). Skips without g++ / rake.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/integer_tag_else_run_check.rb

require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']
abort 'SKIP: no g++' unless runtime.compiler?
# Keys: fixnums on both sides of the index range, out-of-range counts, Floats, nil, Strings, Ranges (including reversed
# and out-of-bounds ones), and NaN. Receivers are literal Arrays, so each call site's receiver is exactly Array.
SOURCE = <<~RUBY
  $keys = [0, 1, -1, 2, 3, -3, 4, 9, 2 ** 40, -(2 ** 40), 1.5, nil, "s", 0..1, 1..2, -2..-1, 5...2, 0..9, 0.0 / 0.0,
           1073741823, 1073741824, -1073741824, 2147483647, 2147483648, 4294967296, 3.0e9]
  class Probe
    def get(i)
      a = [1, 2, 3]
      a[i]
    end

    def put(i, v)
      a = [1, 2, 3]
      a[i] = v
      a
    end
  end
RUBY

SCENARIO = <<~'CPP'
  #include <cstring>
  #include <string>
  struct Call { mrb_value obj; mrb_sym mid; mrb_int argc; mrb_value argv[2]; };
  static mrb_value call_body(mrb_state* M, void* ud) {
    Call* c = (Call*)ud;
    return mrb_funcall_argv(M, c->obj, c->mid, c->argc, c->argv);
  }
  static std::string describe(mrb_state* M, mrb_value v, bool raised) {
    if (raised) {
      mrb_value msg = mrb_funcall(M, v, "message", 0);
      return std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
    }
    mrb_value s = mrb_inspect(M, v);
    return std::string(RSTRING_PTR(s), RSTRING_LEN(s)) + " (" + mrb_obj_classname(M, v) + ")";
  }
  static void row(mrb_state* M, const char* meth, mrb_value key, mrb_int argc) {
    mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
    Call c = { probe, mrb_intern_cstr(M, meth), argc, {} };
    c.argv[0] = key;
    c.argv[1] = mrb_fixnum_value(9);
    int ai = mrb_gc_arena_save(M);
    mrb_bool raised = FALSE;
    mrb_value got = mrb_protect_error(M, call_body, &c, &raised);
    std::string text = describe(M, got, raised);
    std::printf("%s %s => %s\n", meth, mrb_obj_classname(M, key), text.c_str());
    mrb_gc_arena_restore(M, ai);
  }
  static int scenario(mrb_state* M) {
    mrb_value keys = mrb_gv_get(M, mrb_intern_lit(M, "$keys"));
    for (mrb_int j = 0; j < RARRAY_LEN(keys); ++j) row(M, "get", RARRAY_PTR(keys)[j], 1);
    for (mrb_int j = 0; j < RARRAY_LEN(keys); ++j) row(M, "put", RARRAY_PTR(keys)[j], 2);
    std::puts("end");
    return 0;
  }
CPP

# 64-bit: this tree's full-core build. 32-bit (when given): the int32 full-core of scripts/bc2cpp/width_build.rb, with
# its own mrbc (BC2CPP_MRBC32) and the flags the width shard uses. Each width is its own fixture and run.
widths = [['mrb_int 64', nil, nil, nil]]
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
  widths << ['mrb_int 32 (31-bit Fixnums)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie']
end

widths.each do |label, prebuilt, mrbc, flags|
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc || ENV['MRBC']
  ENV['BC2CPP_CXXFLAGS'] = flags.to_s
  begin
    build = prebuilt || runtime.full_or_build
    abort "SKIP: no full-core build for #{label}" unless build
    check.call("#{label}: the fixture-runtime core is built", build.is_a?(String))
    puts "-- #{label}"
    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(SOURCE, dir, closed: true, only_owners: %w[Probe])
      check.call('the positive fixture emits the direct calls',
                 err[/integer-tag else.*?direct (\d+)/, 1].to_i.positive?)
      built, output = runtime.run(dir, err, %w[Probe], SCENARIO, build: build, full: true)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output.to_s.lines.last(25).join unless built
      next unless built

      sections = runtime.sections(output)
      strip = ->(lines) { lines.to_a.reject { |l| l.start_with?('  ') } }
      interpreted = strip.call(sections['interpreted'])
      compiled = strip.call(sections['compiled'])
      check.call('both runs finish', interpreted.last == 'end' && compiled.last == 'end')
      check.call("the grid is large (#{interpreted.size} answers)", interpreted.size > 30)
      same = interpreted == compiled
      check.call('every answer is the interpreter\'s: value, class, exception class and message', same)
      interpreted.zip(compiled).reject { |a, b| a == b }.first(8).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
      check.call('the grid reaches exceptions', interpreted.count { |l| l.include?('raised') } > 5)
      check.call('a Range key is sliced (get 0..1 => [1, 2])',
                 interpreted.any? { |l| l.start_with?('get Range => [1, 2]') } &&
                 compiled.any? { |l| l.start_with?('get Range => [1, 2]') })
    end


  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

puts failures.empty? ? 'PASS' : "FAILED: #{failures.size}"
exit(failures.empty? ? 0 : 1)
