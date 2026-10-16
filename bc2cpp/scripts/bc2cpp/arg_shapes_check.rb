#!/usr/bin/env ruby
# encoding: UTF-8
# ARG_SHAPES (docs/adr/0265): the argument shapes bc2cpp resolves to direct
# calls -- a rest or block-parameter callee, a literal block on a resolved
# callee (yield, `&blk`, yield inside a rescue body), and literal- or
# runtime-sized splats -- must (1) really be direct in the generated code where
# the proof holds, and (2) answer exactly what the interpreter answers. The
# same fixture runs twice on a real mruby core, interpreted and with the
# compiled entry points registered, and the two transcripts are compared; every
# line is a value or the error class and message, so arity errors, LocalJumpError
# and break/next/return behavior are part of the comparison.

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative 'cxx'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC_BIN = ENV['MRBC'] || 'mrbc'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# Only core natives and no mrblib exist in the harness VM, so the fixture
# iterates with `while` and formats with `to_s`/`inspect`.
FIXTURE = <<~'RUBY'
  class AsBox
    def initialize; end

    # bc2cpp: (fixnum, float, bool)
    def boxed_registers(a, b, c)
      [a, b, c]
    end

    def register_slots(a)
      if a
        local = "live"
      end
      result = section(a, local) { |x, y| [x, y, local] }
      [local, result]
    end

    def as_yield2(a, b)
      yield a, b
    end

    def as_yield_twice(a)
      r = yield a
      r + (yield r)
    end

    # Allowlisted iterator names (BLOCK_FALLBACK_UPVAR_SAFE_METHODS) admit blocks that capture locals.
    def section(a, b)
      yield a, b
    end

    def cached_bitmap(cache, key)
      r = yield cache
      r + (yield key)
    end

    def as_guarded(name, default)
      yield
    rescue StandardError => e
      "guard:#{name}:#{e.message}:#{default}"
    end

    def as_amp(a, &blk)
      [a, blk ? :blk : :noblk]
    end

    def as_yield1(a)
      yield a
    end

    def as_amp_forward(a, &blk)
      as_yield1(a, &blk)
    end

    def as_ignore(a)
      a + 1
    end

    def as_bg(a)
      block_given? ? yield(a) : 0 - a
    end

    def as_rest(a, *r)
      [a, r]
    end

    def as_rest_only(*r)
      r
    end

    def as_rest_blk(a, *r, &b)
      [a, r, b ? :blk : nil]
    end

    def as_rest_push(*r)
      r << 99
      r
    end

    def as_two(a, b)
      [a, b]
    end

    def as_opt(a, b = 5)
      [a, b]
    end

    def as_kw(a, k: 7)
      [a, k]
    end

    # --- literal blocks on a self call (LEXICAL_SELF) ---
    def blk_normal
      sum = 0
      r = section(3, 4) { |a, b| sum += a * b }
      [r, sum]
    end

    def blk_break
      as_yield2(3, 4) { |a, b| break a + b + 100 }
    end

    def blk_next
      as_yield2(3, 4) { |a, b| next a * b if a == 3; 0 }
    end

    def blk_return
      as_yield2(3, 4) { |a, b| return [:early, a, b] }
      :not_reached
    end

    def blk_raise
      as_yield2(3, 4) { |_a, _b| raise ArgumentError, 'from block' }
    end

    def blk_twice
      as_yield_twice(5) { |v| v * 2 }
    end

    def blk_more_params
      as_yield2(3, 4) { |a, b, c| [a, b, c] }
    end

    def blk_ignored
      as_ignore(4) { |x| x + 1000 }
    end

    def blk_upvar
      total = 0
      cached_bitmap(1, 2) { |v| total += v; total }
      total
    end

    def blk_nested
      as_yield2(1, 2) { |a, b| as_yield2(a + b, 10) { |c, d| c * d } }
    end

    def blk_guarded_ok
      as_guarded(:f, 0) { 41 + 1 }
    end

    def blk_guarded_raise
      as_guarded(:f, 0) { raise 'boom' }
    end

    def blk_guarded_break
      as_guarded(:f, 0) { break :broke }
    end

    def blk_amp
      as_amp(3) { |x| x * 5 }
    end

    def blk_amp_none
      as_amp(3)
    end

    def blk_amp_forward
      as_amp_forward(4) { |x| x + 1 }
    end

    def blk_bg
      [as_bg(6) { |x| x * 2 }, as_bg(6)]
    end

    def blk_rest_blk
      as_rest_blk(1, 2, 3) { :called }
    end

    # --- rest and splat ---
    def rest_none
      as_rest(1)
    end

    def rest_many
      as_rest(1, 2, 3, 4)
    end

    def rest_nil_and_array
      as_rest(1, nil, [2, 3])
    end

    def rest_hash
      as_rest(1, { a: 1 })
    end

    def rest_kwargs
      as_rest(1, k: 2)
    end

    def rest_fresh
      a = as_rest_push(1, 2)
      b = as_rest_push(1, 2)
      [a, b, a.equal?(b)]
    end

    def rest_only_empty
      as_rest_only
    end

    def rest_too_few
      as_rest
    end

    def splat_literal
      as_two(*[1, 2])
    end

    def splat_runtime(arr)
      as_two(*arr)
    end

    def splat_runtime_rest(arr)
      as_rest(*arr)
    end

    def splat_runtime_opt(arr)
      as_opt(*arr)
    end

    def splat_mixed(arr)
      [as_two(1, *arr), as_two(*arr, 3)]
    end

    def splat_two(a1, a2)
      as_two(*a1, *a2)
    end

    def splat_nil
      as_two(*nil)
    end

    def splat_obj(obj)
      as_two(*obj)
    end

    def splat_kw(arr)
      as_kw(*arr)
    end

    # --- explicit receiver, typed by `.new` (guarded direct call) ---
    def typed_block
      box = AsBox.new
      box.as_yield2(2, 3) { |a, b| a - b }
    end

    def typed_rest
      box = AsBox.new
      box.as_rest(1, 2)
    end

    def typed_splat(arr)
      box = AsBox.new
      box.as_two(*arr)
    end

    # --- explicit block argument (kept dynamic) ---
    def amp_symbol
      as_amp(:upcase_me, &:no_such_proc_source)
    end

    def amp_proc
      pr = ->(x) { x.to_s + '!' }
      as_amp(9, &pr)
    end

    def amp_nil
      as_amp(9, &nil)
    end
  end

  class AsToA
    def to_a
      [8, 9]
    end
  end

  class AsRunner
    def line(label)
      v = yield
      "#{label}: #{v.inspect}"
    rescue Exception => e
      "#{label}: !#{e.class}: #{e.message}"
    end

    def all
      b = AsBox.new
      out = []
      plain = %i[blk_normal blk_break blk_next blk_return blk_raise blk_twice blk_more_params
         blk_ignored blk_upvar blk_nested blk_guarded_ok blk_guarded_raise blk_guarded_break blk_amp
         blk_amp_none blk_amp_forward blk_rest_blk rest_none rest_many rest_nil_and_array rest_hash
         rest_kwargs rest_fresh rest_only_empty rest_too_few splat_literal splat_nil typed_block typed_rest
         amp_symbol amp_proc amp_nil]
      j = 0
      while j < plain.size
        m = plain[j]
        out << line(m) { b.__send__(m) }
        j += 1
      end
      arrays = [[], [1], [1, 2], [1, 2, 3], [1, [2, 3]], [nil, nil]]
      i = 0
      while i < arrays.size
        arr = arrays[i]
        shaped = %i[splat_runtime splat_runtime_rest splat_runtime_opt splat_mixed splat_kw typed_splat]
        k = 0
        while k < shaped.size
          m = shaped[k]
          out << line("#{m}#{arr.inspect}") { b.__send__(m, arr) }
          k += 1
        end
        i += 1
      end
      out << line('boxed_registers') { b.boxed_registers(-3, 1.25, false) }
      out << line('register_slots_true') { b.register_slots(true) }
      out << line('register_slots_false') { b.register_slots(false) }
      out << line('splat_two') { b.splat_two([1], [2]) }
      out << line('splat_two_empty') { b.splat_two([], []) }
      out << line('splat_obj_to_a') { b.splat_obj(AsToA.new) }
      out << line('splat_obj_int') { b.splat_obj(5) }
      out << line('splat_obj_nil') { b.splat_obj(nil) }
      out << line('splat_obj_hash') { b.splat_obj({ a: 1 }) }
      out.join("\n")
    end
  end
RUBY

# The generated code of one method, cut at the next function.
def body_of(code, function)
  code[/^mrb_value #{Regexp.escape(function)}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

DISPATCH = /\bmrb_funcall(?:_with_block|_argv|_id)?\(|\bbc2cpp_send\(/

core = [ENV['BC2CPP_MRUBY_CORE'], *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |dir|
  File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include'))
end

Dir.mktmpdir do |dir|
  src = File.join(dir, 'arg_shapes.rb')
  gen = File.join(dir, 'arg_shapes_gen.cpp')
  File.write(src, FIXTURE)
  # A closed world with the core natives registered, so `AsBox.new` resolves
  # to a class the typed and exact-class paths can name.
  env = { 'MRBC' => MRBC_BIN, 'SKIP_UNSUPPORTED' => '1', 'OUT_SYMBOL' => 'arg_shapes', 'OUT_DIR' => dir,
          'BC2CPP_SELF_REGISTERING' => '1',
          'NATIVE_SRCS' => Shellwords.join(core_native_srcs("#{ROOT}/3rd/mruby")),
          'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
          'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.wio_gems(ROOT).map { |n, d| "#{n}=#{d}" }),
          NomethodReviewed::ALLOW_ENV => 'allow' }
  _out, err, status = Open3.capture3(env, "#{RbConfig.ruby.shellescape} #{BC2CPP.shellescape} --annotated " \
                                          "#{src.shellescape} > #{gen.shellescape}")
  abort "bc2cpp.rb failed:\n#{err[-3000..]}" unless status.success?
  code = File.read(gen)

  puts '-- generated code'
  block_sites = %w[blk_normal blk_break blk_next blk_return blk_raise blk_twice blk_more_params
                   blk_upvar blk_nested blk_guarded_ok blk_guarded_raise blk_guarded_break blk_amp
                   blk_amp_forward blk_rest_blk]
  block_sites.each do |m|
    body = body_of(code, "AsBox_#{m}")
    check.call("#{m}: the literal block reaches the compiled callee directly",
               body.include?('direct call with the block') && !body.match?(DISPATCH))
  end
  typed = body_of(code, 'AsBox_typed_block')
  check.call('a fresh-receiver literal block is a direct call once the class is proven',
             typed.include?('CLOSED_WORLD_EXACT_CLASS :as_yield2') && typed.include?('AsBox_as_yield2_impl(M, r') &&
               !typed.match?(DISPATCH))
  check.call('a callee that reads block_given? is a direct call: it answers from its own block parameter (ADR 0266)',
             body_of(code, 'AsBox_blk_bg').include?('direct call with the block') &&
               !body_of(code, 'AsBox_blk_bg').match?(DISPATCH) && body_of(code, 'AsBox_as_bg').include?('bc2cpp_blk'))
  check.call('an explicit &block argument keeps the dispatch',
             body_of(code, 'AsBox_amp_symbol').match?(DISPATCH))
  check.call('a rest callee gets a fresh Array built at the call',
             body_of(code, 'AsBox_rest_many').include?('mrb_ary_new_from_values(M, 3,') &&
               !body_of(code, 'AsBox_rest_many').match?(DISPATCH))
  check.call('a rest callee with no extra arguments gets an empty Array',
             body_of(code, 'AsBox_rest_none').include?('mrb_ary_new(M)'))
  check.call('a too-short call to a rest callee raises its ArgumentError (dispatched or static, ADR 0259)',
             body_of(code, 'AsBox_rest_too_few').match?(DISPATCH) ||
               body_of(code, 'AsBox_rest_too_few').include?('STATIC_ARGC_ERROR :as_rest'))
  check.call('a literal-sized splat is a direct call',
             !body_of(code, 'AsBox_splat_literal').match?(DISPATCH) &&
               body_of(code, 'AsBox_splat_literal').include?('AsBox_as_two_impl'))
  runtime = body_of(code, 'AsBox_splat_runtime')
  check.call('a runtime-sized splat switches on the Array length',
             runtime.include?('switch (RARRAY_LEN(') && runtime.include?('case 2:') &&
               runtime.include?('AsBox_as_two_impl') && runtime.include?('bc2cpp_funcall_argv'))

  if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
    puts '  SKIP run: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
  else
    puts '-- differential run on real mruby'
    entries = err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
                 .scan(%r{^\s+(\w+) / \w+\s+\(([^#]+)#([^,]+), arity \d+\)(.*)$})
    registrations = entries.map do |entry, owner, name, extra|
      klass = "mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, #{owner.delete_suffix('.singleton').dump})))"
      fn = if owner.end_with?('.singleton') then 'mrb_define_class_method'
           elsif extra.include?('[private') then 'mrb_define_private_method'
           else 'mrb_define_method'
           end
      "    #{fn}(M, #{klass}, #{name.dump}, #{entry}, MRB_ARGS_ANY());"
    end
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      #include "arg_shapes_gen.cpp"
      #include <mruby/irep.h>
      #include <mruby/string.h>
      #include <cstdio>
      #include <cstring>
      #include <fstream>
      #include <iterator>
      #include <vector>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      int main(int, char** argv) {
        mrb_state* M = mrb_open_core();
        std::ifstream in(argv[1], std::ios::binary);
        std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        mrb_load_irep_buf(M, bin.data(), bin.size());
        if (M->exc) { mrb_print_error(M); return 2; }
        if (std::strcmp(argv[2], "compiled") == 0) {
          bc2cpp_set_instance_tts(M);
      #{registrations.join("\n")}
        }
        mrb_value runner = mrb_obj_new(M, mrb_class_get(M, "AsRunner"), 0, nullptr);
        mrb_value text = mrb_funcall(M, runner, "all", 0);
        if (M->exc) { mrb_print_error(M); return 3; }
        std::fwrite(RSTRING_PTR(text), 1, RSTRING_LEN(text), stdout);
        std::fputc('\\n', stdout);
        mrb_close(M);
        return 0;
      }
    CPP
    binary = File.join(dir, 'arg_shapes')
    built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w',
                   "-I#{dir}", "-I#{core}/include", "-I#{ROOT}/3rd/mruby/include", "-I#{ROOT}/mruby-rgss/src",
                   File.join(dir, 'main.cpp'), "#{core}/lib/libmruby_core.a", '-lm', '-o', binary)
    check.call('the fixture compiles against real mruby', built)
    FileUtils.cp_r(dir, ENV['ARG_SHAPES_KEEP']) if ENV['ARG_SHAPES_KEEP']
    if built
      interpreted = IO.popen([binary, File.join(dir, 'arg_shapes.mrb'), 'interpreted'], err: %i[child out], &:read)
      compiled = IO.popen([binary, File.join(dir, 'arg_shapes.mrb'), 'compiled'], err: %i[child out], &:read)
      puts interpreted if interpreted.lines.size < 10
      check.call('the interpreted run produced a transcript', interpreted.lines.size > 60)
      lines = interpreted.lines.zip(compiled.lines)
      lines.each do |want, got|
        puts "  #{want == got ? 'ok  ' : 'DIFF'} #{want.to_s.strip}#{"   compiled: #{got.to_s.strip}" unless want == got}" unless want == got
      end
      check.call("all #{interpreted.lines.size} transcript lines agree", interpreted == compiled)
      File.write(File.join(ENV['ARG_SHAPES_TRANSCRIPT'], 'interpreted.txt'), interpreted) if ENV['ARG_SHAPES_TRANSCRIPT']
    end
  end
end

if failures.empty?
  puts 'bc2cpp arg shapes check: PASS'
else
  warn "bc2cpp arg shapes check: #{failures.size} failure(s)"
  exit 1
end
