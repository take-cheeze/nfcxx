#!/usr/bin/env ruby
# encoding: UTF-8
# Check NILABLE_EMBED_SUPPORT (tools/bc2cpp/ivar_layout.rb): an Integer-or-nil
# ivar embeds as a tagged payload, and the tag is real storage behavior, not
# just a type the analyzer can name.
#
# 1. Join lattice: nil + Fixnum widens to :fixnum_nil in either order, is
#    absorbing, and every other disagreement still poisons (the order-
#    independence ADR 0139's sticky-UNKNOWN rule exists to guarantee).
# 2. Analysis: a fixture written only as Integer/nil embeds as :fixnum_nil; a
#    Symbol/object/bool writes and nil-only writes stay in generic mrb_value
#    storage instead of receiving the nullable Fixnum representation.
# 3. Generated code: the tagged struct and its helpers are emitted, the
#    reader boxes, writes route through the setter, and the field never
#    reaches iv_tbl.
# 4. Runtime: compiled against real mruby and run -- nil round trip, negative
#    and large values, survival across a full GC, a synthesized attr_writer
#    returning the assigned value, and a rejected write raising TypeError
#    while leaving the field unchanged.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=build/mruby/host/mrbc] \
#          ruby scripts/bc2cpp/fixnum_nil_ivar_check.rb

require 'open3'
require 'tmpdir'
require_relative '../../tools/bc2cpp/ivar_layout'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative 'cxx'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC = ENV['MRBC'] || 'mrbc'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def run_bc2cpp(env, srcs)
  out, err, status = Open3.capture3(env.merge('MRBC' => MRBC, 'SKIP_UNSUPPORTED' => '1'),
                                     RbConfig.ruby, BC2CPP, '--annotated', *srcs)
  abort "bc2cpp.rb failed:\n#{err[-2000..]}" unless status.success?

  [out, err]
end

# The pinned vendored mruby has no mrb_state::errinfo, which the generator's
# VM_UNWIND_RESTORE helper references. The fixture below never unwinds through
# a real VM frame, so drop only that one statement for the runtime leg.
def drop_errinfo_line(code)
  code.sub(/  if \(M->errinfo.*?\n/, '')
end

U = IvarLayout::UNKNOWN
N = IvarLayout::NIL
F = IvarLayout::FIXNUM_NIL

puts '-- join lattice'
widen = [[:fixnum, N], [N, :fixnum], [F, :fixnum], [:fixnum, F], [F, N], [N, F]]
check.call('Integer and nil widen to :fixnum_nil in either order', widen.all? { |a, b| IvarLayout.join(a, b) == F })
check.call('an already-widened field stays widened',
           [[:fixnum, N], [F, :symbol], [F, U]].all? do |a, b|
             IvarLayout.join(IvarLayout.join(a, b), N) == IvarLayout.join(IvarLayout.join(a, b), :fixnum)
           end)
check.call('every other disagreement still poisons',
           [[:fixnum, :symbol], [N, :symbol], [F, :symbol], [F, U], [:fixnum, U], [U, N], [N, :bool],
            [F, :bool], [U, :fixnum]].all? { |a, b| IvarLayout.join(a, b) == U })
check.call('a nil-only fact is kept but is not embeddable',
           IvarLayout.join(nil, N) == N && !IvarLayout::EMBEDDABLE.include?(N))
check.call('a missing fact still poisons on the right', IvarLayout.join(:fixnum, nil) == U)

NULLABLE_FIXTURE = <<~'RUBY'
  class Cursor
    attr_accessor :pos

    # bc2cpp: (fixnum)
    def initialize(start)
      @pos = start
    end

    def reset
      @pos = nil
    end

    # bc2cpp: (fixnum)
    def advance(n)
      @pos = n
    end

    def current
      @pos
    end
  end
RUBY

SYMBOL_FIXTURE = <<~'RUBY'
  class Cursor
    # bc2cpp: (fixnum)
    def initialize(start)
      @pos = start
    end

    def reset
      @pos = nil
    end

    def retag
      @pos = :done
    end
  end
RUBY

NIL_ONLY_FIXTURE = <<~'RUBY'
  class Cursor
    def initialize(_ignored)
      @pos = nil
    end

    def clear
      @pos = nil
    end
  end
RUBY

# The Optcarrot CPU#@opcode shape: a nil write and one write whose source is an
# ordinary send, which trace_type cannot read. Only FIXNUM_NIL_DECLARATION can
# admit this one.
OPAQUE_FIXTURE = <<~'RUBY'
  class Cursor
    def initialize(_ignored)
      @pos = nil
    end

    def step
      @pos = fetch
    end

    def fetch
      7
    end
  end
RUBY

# The historical RPG2k::Scene::EquipMenu#@candidates shape: nil plus Array#+,
# which is an Array field. The sound ADD arm in trace_type is what keeps this
# one out of the fixnum_nil lattice.
ARRAY_FIXTURE = <<~'RUBY'
  class Cursor
    def initialize(_ignored)
      @pos = nil
    end

    def build
      real = [[1, 2]]
      @pos = real + [[0, 0]]
    end
  end
RUBY

def embedded_types(diagnostics, owner, ivar)
  section = diagnostics.split('== ivar embedding ==', 2)[1].to_s.split("\n== ", 2)[0]
  # Line-wise, not one regex over the whole section: Ruby's `split` treats the
  # `#@` in `EMBED  Owner#@ivar` as a comment marker and truncates the line.
  line = section.lines.find { |l| l.start_with?("  EMBED  #{owner}#@#{ivar} ") }
  line && line[/\((\w+)\)/, 1]
end

puts '-- analysis'
# The type is INFERRED by default: a field written only Integers and nil widens
# by the ordinary join and needs no declaration. FIXNUM_NIL_DECLARATION is only
# an allowance for a field the sweep cannot read at all (its Fixnum write is an
# opaque send), so the legs below cover both.
DECLARED_POS = 'Cursor#@pos'

def declared?(decl) # written out so no shell/quoting layer can eat the '#@'
  !decl.nil?
end
Dir.mktmpdir do |dir|
  [[NULLABLE_FIXTURE, 'declared_fix', DECLARED_POS, 'fixnum_nil'],
   [NULLABLE_FIXTURE, 'inferred_fix', nil, 'fixnum_nil'],
   [SYMBOL_FIXTURE, 'symbol_fix', DECLARED_POS, 'value'],
   [NIL_ONLY_FIXTURE, 'nil_only_fix', DECLARED_POS, 'value'],
   [OPAQUE_FIXTURE, 'opaque_declared', DECLARED_POS, 'fixnum_nil'],
   [OPAQUE_FIXTURE, 'opaque_undeclared', nil, 'value'],
   [ARRAY_FIXTURE, 'array_field', DECLARED_POS, 'value']].each do |body, symbol, decl, expected|
    src = File.join(dir, "#{symbol}.rb")
    File.write(src, body)
    env = { 'OUT_SYMBOL' => symbol, 'OUT_DIR' => dir, 'BC2CPP_SELF_REGISTERING' => '1' }
    env['FIXNUM_NIL_IVARS'] = decl if declared?(decl)
    _code, err = run_bc2cpp(env, [src])
    got = embedded_types(err, 'Cursor', 'pos')
    if expected
      check.call("#{symbol}: @pos embeds as #{expected}", got == expected)
    else
      check.call("#{symbol}: @pos does not embed", got.nil?)
    end
  end
end

RUNTIME_MAIN = <<~'CPP'
  #include "nullable_fix_gen.cpp"
  #include <mruby/irep.h>
  #include <cstdio>
  #include <fstream>
  #include <iterator>
  #include <vector>
  extern "C" void mrb_init_mrblib(mrb_state*) {}

  static int failed = 0;

  static void expect(mrb_state* M, mrb_value got, mrb_bool want_nil, mrb_int want, const char* what) {
    bool ok = want_nil ? mrb_nil_p(got) : (mrb_fixnum_p(got) && mrb_fixnum(got) == want);
    std::printf("  %s %s\n", ok ? "ok  " : "FAIL", what);
    failed += !ok;
  }

  static void expect_raises(mrb_state* M, mrb_value obj, const char* name, mrb_value arg, const char* what) {
    mrb_funcall(M, obj, name, 1, arg);
    bool raised = M->exc != nullptr;
    std::printf("  %s %s\n", raised ? "ok  " : "FAIL", what);
    failed += !raised;
    if (raised) M->exc = nullptr;
  }

  int main(int, char** argv) {
    mrb_state* M = mrb_open_core();
    std::ifstream in(argv[1], std::ios::binary);
    std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    mrb_load_irep_buf(M, bin.data(), bin.size());
    if (M->exc) { mrb_print_error(M); return 2; }
    bc2cpp_set_instance_tts(M);
    { // The fixture is a single file with no call sites, so bc2cpp's
      // never-called pruning leaves these unregistered; install them directly.
      struct RClass* c = mrb_class_get(M, "Cursor");
      mrb_define_private_method(M, c, "initialize", Cursor_initialize, MRB_ARGS_ANY());
      mrb_define_method(M, c, "reset", Cursor_reset, MRB_ARGS_ANY());
      mrb_define_method(M, c, "advance", Cursor_advance, MRB_ARGS_ANY());
      mrb_define_method(M, c, "current", Cursor_current, MRB_ARGS_ANY());
      mrb_define_method(M, c, "pos", Cursor_pos, MRB_ARGS_ANY());
      mrb_define_method(M, c, "pos=", Cursor_pos_eq, MRB_ARGS_ANY());
    }

    mrb_value c = mrb_obj_new(M, mrb_class_get(M, "Cursor"), 0, nullptr);
    mrb_funcall(M, c, "initialize", 1, mrb_fixnum_value(5));
    expect(M, mrb_funcall(M, c, "current", 0), false, 5, "a fresh object reads its start value");
    mrb_funcall(M, c, "reset", 0);
    expect(M, mrb_funcall(M, c, "current", 0), true, 0, "reset stores nil");
    expect(M, mrb_funcall(M, c, "pos", 0), true, 0, "the synthesized reader sees nil");

    mrb_funcall(M, c, "advance", 1, mrb_fixnum_value(-7));
    expect(M, mrb_funcall(M, c, "current", 0), false, -7, "a negative value round trips");
    mrb_funcall(M, c, "advance", 1, mrb_fixnum_value(0x7fffffff));
    expect(M, mrb_funcall(M, c, "current", 0), false, 0x7fffffff, "a large fixnum round trips");
    mrb_funcall(M, c, "reset", 0);

    mrb_full_gc(M);
    mrb_funcall(M, c, "advance", 1, mrb_fixnum_value(3));
    mrb_full_gc(M);
    expect(M, mrb_funcall(M, c, "current", 0), false, 3, "the value survives a full GC");

    mrb_value assigned = mrb_funcall(M, c, "pos=", 1, mrb_fixnum_value(11));
    expect(M, assigned, false, 11, "attr_writer returns the assigned value");

    expect_raises(M, c, "pos=", mrb_str_new_lit(M, "nope"), "attr_writer(String) raises TypeError");
    expect(M, mrb_funcall(M, c, "current", 0), false, 11, "a rejected write left the field unchanged");
    expect_raises(M, c, "advance", mrb_true_value(), "advance(true) raises TypeError");
    expect(M, mrb_funcall(M, c, "current", 0), false, 11, "a rejected compiled write left the field unchanged");

    mrb_close(M);
    return failed ? 1 : 0;
  }
CPP

puts '-- generated code and runtime'
# This repo's mruby lives at 3rd/mruby; the other checks' `build*/mruby/host/mrbc`
# glob is for the project build tree and finds nothing here.
core = [ENV['BC2CPP_MRUBY_CORE'],
        File.join(ROOT, '3rd/mruby/build/host/mrbc'),
        File.join(ROOT, '3rd/mruby/build/host'),
        *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |dir|
  File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include'))
end
Dir.mktmpdir do |dir|
  src = File.join(dir, 'nullable_fix.rb')
  File.write(src, NULLABLE_FIXTURE)
  env = { 'OUT_SYMBOL' => 'nullable_fix', 'OUT_DIR' => dir, 'BC2CPP_SELF_REGISTERING' => '1',
          'FIXNUM_NIL_IVARS' => DECLARED_POS }
  code, err = run_bc2cpp(env, [src])
  check.call('the tagged payload struct is emitted', code.include?('struct Bc2cppFixnumOrNil'))
  check.call('a nil check and a setter are emitted',
             code.include?('bc2cpp_fixnum_or_nil_p') && code.include?('bc2cpp_fixnum_or_nil_set'))
  check.call('reads box the tagged field', code.match?(/bc2cpp_fixnum_or_nil_box\(\(\(Cursor_ivars\*\)DATA_PTR\(self\)\)->ivar_pos\)/))
  check.call('compiled writes route through the setter',
             code.match?(/bc2cpp_fixnum_or_nil_set\(&\(\(Cursor_ivars\*\)DATA_PTR\(self\)\)->ivar_pos, r\d+\);/))
  check.call('the field never reaches iv_tbl',
             !code.match?(/mrb_iv_(?:get|set)\(M, self, [^)]*"@pos"/))
  check.call('the heap-Bignum-safe check is used, not mrb_integer_p',
             !code.match?(/if \(!mrb_integer_p\([^)]*\)\)[^\n]*@pos/))

  if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
    puts '  SKIP runtime: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
  else
    gen = File.join(dir, 'nullable_fix_gen.cpp')
    File.write(gen, drop_errinfo_line(code))
    File.write(File.join(dir, 'nullable_main.cpp'), RUNTIME_MAIN)
    binary = File.join(dir, 'nullable_check')
    built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w',
                   "-I#{dir}", "-I#{core}/include", "-I#{File.join(ROOT, '3rd/mruby/include')}",
                   File.join(dir, 'nullable_main.cpp'), "#{core}/lib/libmruby_core.a", '-lm', '-o', binary)
    check.call('the fixture compiles against real mruby', built)
    if built
      irep = err[/(\S+\.mrb)/, 1] || File.join(dir, 'nullable_fix.mrb')
      output = IO.popen([binary, irep], err: %i[child out], &:read)
      puts output
      check.call('the tagged field behaves correctly on real mruby', $?.success?)
    end
  end
end

if failures.empty?
  puts 'bc2cpp fixnum-or-nil ivar check: PASS'
else
  warn "bc2cpp fixnum-or-nil ivar check: #{failures.size} failure(s)"
  exit 1
end
