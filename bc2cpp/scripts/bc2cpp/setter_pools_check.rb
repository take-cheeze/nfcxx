#!/usr/bin/env ruby
# frozen_string_literal: true

# Check SETTER_POOLS and CHECKED_POOL_EXACT (docs/adr/0370): an ivar an attr_writer or an audited native writes,
# and the argument of a setter with several definitions, get a class pool from the arguments of every call of
# the setter; a receiver those pools prove nil-or-one-class is called directly behind a class test whose else is
# bc2cpp_guard_violation.
#
# 0. Audit (no MRBC): every native store of a scoped slot (NativeIvarScopes::STORES) is the one the table says.
# 1. Generated code (needs MRBC): the positive shapes get the checked arm; every withdrawal condition (a second
#    class, a parameter, send(:x=), an alias, a computed name, a native call, a super, a runtime installer,
#    reflection, a singleton, a foreign source, the open world, both kill switches) keeps the old guard or send,
#    and a setter a native only registers is still admitted.
# 2. Behaviour on real mruby: compiled answers equal interpreted ones; a setter call from outside the closed
#    world (the writer the scan cannot see) is a loud guard violation in the compiled run, never a silent
#    wrong answer, and the kill switch makes it match the interpreter again.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/setter_pools_check.rb

require 'digest'
require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/native_ivar_scopes'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime
root = File.expand_path('../..', __dir__)

# -- 0. the native audit ----------------------------------------------------------------------------------------------

puts '== native store audit'
lib = File.read(File.join(root, 'mruby-rgss/src/lib.cxx'))
check.call('lib.cxx is the audited file (a change must re-audit NativeIvarScopes::STORES)',
           Digest::SHA256.hexdigest(lib) == NativeIvarScopes::FILES.fetch('mruby-rgss/src/lib.cxx'))
stores = lib.scan(/mrb_iv_set\(M,\s*(\w+),\s*mrb_intern_lit\(M,\s*"@contents"\),\s*(\w+)\)/)
check.call('exactly two natives store @contents: window_init\'s own Bitmap and the setter argument',
           stores == [%w[self initial_contents], %w[self bmp]])
check.call('the first is a 1x1 RGSS::Bitmap built by DataType<Bitmap>::make',
           lib.include?('mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Bitmap")') &&
             lib.match?(/const mrb_value initial_contents = DataType<Bitmap>::make\(\s*M, initial_contents_bmp_class, 1, 1,/))
check.call('the second is window_contents_set_direct, reached by the registered `contents=` and nothing else stores it',
           lib.match?(/mrb_define_method\(M, window, "contents=", window_set_contents,/) &&
             lib.match?(/mrb_value window_set_contents\(mrb_state\* M, mrb_value self\) \{\s*mrb_value bmp;\s*mrb_get_args\(M, "o", &bmp\);\s*return rgss::window_contents_set_direct\(M, self, bmp\);/) &&
             lib.match?(/mrb_value window_contents_set_direct\(mrb_state\* M,\s*mrb_value self,\s*mrb_value bmp\) \{\s*mrb_iv_set\(M, self, mrb_intern_lit\(M, "@contents"\), bmp\);/))
others = (Dir[File.join(root, 'mruby-rgss/src/*.cxx')] + Dir[File.join(root, 'include/*.hxx')] + Dir[File.join(root, 'mruby-rgss/mrblib/*.rb')])
         .reject { |path| path.end_with?('mruby-rgss/src/lib.cxx') }
check.call('no other native or rgss Ruby source stores @contents',
           others.none? { |path| File.read(path).match?(/@contents\b(?!_)\s*(?:=[^=]|\|\|=)|"@contents"/) })
check.call('STORES names exactly that setter and that class',
           NativeIvarScopes::STORES == { 'contents' => { setters: ['contents='], classes: ['RGSS::Bitmap'] } })

# -- fixtures ---------------------------------------------------------------------------------------------------------

CLASSES = <<~RUBY
  class SpBox
    def initialize; @n = 0; end
    def tag; :box; end
    # `size` is also an Array/Hash/String method, so only a proven receiver removes the by-name else.
    def size; 1; end
  end

  class SpOther
    def tag; :other; end
    def size; 2; end
  end
RUBY

HOST = <<~RUBY
  class SpHost
    attr_accessor :spwin, :spmix, :spprm, :spsend, :spnat, :spreg, :spalias, :spbad, :spstr, :spkw
    attr_writer :spwr

    def initialize
      @spwin = nil; @spmix = nil; @spprm = nil; @spnat = nil; @spreg = nil; @spbad = nil; @spwr = nil
      # A SpBox here makes the pool of a refused setter non-empty, so an admission mutant has something to type.
      @spsend = SpBox.new; @spalias = SpBox.new; @spstr = SpBox.new; @spkw = SpBox.new
    end

    def read_win; @spwin.size; end
    def read_wr; @spwr.size; end
    def read_mix; @spmix.size; end
    def read_prm; @spprm.size; end
    def read_send; @spsend.size; end
    def read_nat; @spnat.size; end
    def read_reg; @spreg.size; end
    def read_alias; @spalias.size; end
    def via_win(h); h.spwin.size; end
    def read_bad; @spbad.size; end
    def read_str; @spstr.size; end
    def read_kw; @spkw.size; end
  end

  class SpHost
    alias_method :spalias_other=, :spalias=
    # The keyword form names the old setter without a Symbol literal.
    alias spkw_other= spkw=
  end

  # An attr_accessor and an unrelated alias_method share a class body: only the names the alias spells are withdrawn.
  class SpAl
    attr_accessor :spal_keep, :spal_old
    attr_reader :spal_plain
    def spal_orig; 1; end
    alias_method :spal_new, :spal_orig
    alias_method :spal_old_copy, :spal_old
    def initialize; @spal_keep = nil; @spal_old = nil; @spal_plain = SpBox.new; end
    def read_keep; @spal_keep.size; end
    def read_old; @spal_old.size; end
  end

  # One name, two definitions: the single-definition rule of the argument pools refuses it.
  class SpDefA
    def initialize; @spda = nil; end
    def spdv=(v); @spda = v; end
    def read_a; @spda.size; end
  end

  class SpDefB
    def initialize; @spdb = nil; end
    def spdv=(v); @spdb = v; end
  end

  class SpDrv
    def fill(h, o)
      h.spwin = SpBox.new
      h.spwr = SpBox.new
      h.spmix = SpBox.new
      h.spmix = SpOther.new
      h.spprm = o
      h.spsend = SpBox.new
      h.send(:spsend=, SpOther.new)
      h.spnat = SpBox.new
      h.spreg = SpBox.new
      h.spalias = SpBox.new
      h.spalias_other = SpOther.new
      h.spbad = SpBox.new
      h.spstr = SpBox.new
      h.send("spstr=", SpOther.new)
      h.spkw = SpBox.new
      h.spkw_other = SpOther.new
      al = SpAl.new
      al.spal_keep = SpBox.new
      al.spal_old = SpBox.new
      h
    end

    # A name composed at run time: no site spells `spwin=`.
    def wild(h, stem, v)
      h.send("\#{stem}=", v)
    end

    def via_keep(al); al.spal_keep.size; end
    def via_old(al); al.spal_old.size; end
    def via_plain(al); al.spal_plain.size; end

    def fill_defs
      a = SpDefA.new
      a.spdv = SpBox.new
      b = SpDefB.new
      b.spdv = SpBox.new
      a
    end
  end
RUBY

OWNERS = %w[SpBox SpOther SpHost SpAl SpDefA SpDefB SpDrv].freeze
# A native source that calls `spnat=` by name and only registers `spreg=`.
NATIVE = [['sp_native.cxx', <<~CPP]].freeze
  static void sp_call(mrb_state* M, mrb_value o) { mrb_funcall(M, o, "spnat=", 1, mrb_nil_value()); }
  static void sp_reg(mrb_state* M, RClass* c) { mrb_define_method(M, c, "spreg=", sp_fn, MRB_ARGS_REQ(1)); }
CPP

body_of = lambda do |code, owner, fn|
  code[/^mrb_value #{owner}_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
checked = ->(code, owner, fn) { body_of.call(code, owner, fn).include?('CHECKED_POOL_EXACT :size') }
by_name = ->(code, owner, fn) { body_of.call(code, owner, fn).include?('bc2cpp_send(') }

# The closed world's own outside sources are the build's gems' src/ and mrblib/, so the fixture's native and foreign
# sources also live in a gem the build lists (the NATIVE_SRCS list alone feeds the older, blunter scans).
generate = lambda do |source, dir, closed: true, env: {}, native: NATIVE, foreign: [], **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    gem_dir = File.join(dir, 'sp_gem')
    FileUtils.mkdir_p([File.join(gem_dir, 'src'), File.join(gem_dir, 'mrblib')])
    native.each { |name, text| File.write(File.join(gem_dir, 'src', name), text) }
    foreign.each { |name, text| File.write(File.join(gem_dir, 'mrblib', name), text) }
    runtime.generate(source, dir, closed: closed, only_owners: OWNERS, native: native, foreign: foreign,
                                  build_gems: [['sp-fake', gem_dir]], **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

# -- 1. generated code ------------------------------------------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, err = generate.call(CLASSES + HOST, dir)

    { 'read_win' => 'attr_accessor, every call passes a SpBox', 'read_wr' => 'attr_writer, every call passes a SpBox',
      'read_reg' => 'a native that only REGISTERS the setter is not a call', 'read_bad' => 'a plain accessor, control' }.each do |fn, why|
      body = body_of.call(code, 'SpHost', fn)
      check.call("SpHost##{fn}: #{why} -> nil-or-SpBox behind a class test", checked.call(code, 'SpHost', fn) &&
                   body.include?('mrb_nil_p(') && body.include?('mrb_obj_class(M, r') && !by_name.call(code, 'SpHost', fn))
    end
    win = body_of.call(code, 'SpHost', 'read_win')
    check.call('the class miss is a guard violation naming the family, not a dispatch',
               win.include?('bc2cpp_guard_violation(M, r2, ') && win.include?('(CHECKED_POOL_EXACT)') && !win.include?('bc2cpp_send('))
    check.call('the nil arm is the NoMethodError helper, not a send', win.include?('bc2cpp_nil_receiver(M, r2'))
    check.call('an accessor call result is typed too', checked.call(code, 'SpHost', 'via_win'))
    check.call('an attr_accessor next to an unrelated alias_method keeps its checked pool (the alias spells other names)',
               checked.call(code, 'SpAl', 'read_keep'))
    check.call('an accessor call result of a name the alias does not spell is typed', checked.call(code, 'SpDrv', 'via_keep'))
    check.call('NEG a name no pool checks (an exact attr_reader) stays withdrawn by the coarse alias rule: only a checked accessor name uses the operands',
               !checked.call(code, 'SpDrv', 'via_plain') && by_name.call(code, 'SpDrv', 'via_plain'))
    check.call('NEG a name an alias_method spells keeps the by-name call (its table may be wrong), though its ivar pool is checked',
               checked.call(code, 'SpAl', 'read_old') && !checked.call(code, 'SpDrv', 'via_old') && by_name.call(code, 'SpDrv', 'via_old'))
    check.call('a setter with two definitions: the Ruby definition\'s parameter pool types its ivar',
               checked.call(code, 'SpDefA', 'read_a'))
    check.call('the diagnostic marks the checked pools',
               err.include?('CLASSIVAR SpHost#@spwin (CHECKED|NIL|SpBox)') && err.include?('CLASSIVAR SpHost#@spwr (CHECKED|NIL|SpBox)') &&
                 err.include?('CLASSARG SpDefA#spdv= arg1 (CHECKED|SpBox)'))

    # NEG: each keeps its by-name send (the old output).
    { 'read_mix' => 'a call passes a SpOther: two classes', 'read_prm' => 'a call passes a parameter',
      'read_send' => 'send(:spsend=, ..) reaches the writer', 'read_nat' => 'a native funcalls `spnat=`',
      'read_alias' => 'alias_method names `spalias=`', 'read_kw' => 'the `alias` keyword names `spkw=`', 'read_str' => 'the program spells "spstr=" as a String' }.each do |fn, why|
      check.call("NEG SpHost##{fn}: #{why}", !checked.call(code, 'SpHost', fn) && by_name.call(code, 'SpHost', fn))
    end

    # Withdrawal worlds: each must stop the always-checked control read_win.
    variants = {
      'a runtime installer of the setter' => "class SpHost\n  define_method(:spwin=) { |v| @spwin = v }\nend\n",
      'a reopened class whose setter forwards with super' =>
        "class SpHostSub < SpHost\n  def spwin=(v); super(v.to_s); end\nend\n",
      'instance_variable_set(:@spwin)' => "class SpHost\n  def poke(v); instance_variable_set(:@spwin, v); end\nend\n",
      'a singleton definition' => "class SpHost\n  def maker; a = [1]; def a.other(*); 1; end; a; end\nend\n",
      'a Symbol of the setter' => "class SpHost\n  def meth; method(:spwin=); end\nend\n",
      'a setter taking two arguments' => "class SpHost\n  def spwin=(a, b = 1); @spwin = a; end\nend\n"
    }
    variants.each do |what, extra|
      d = File.join(dir, what.gsub(/\W+/, '_'))
      Dir.mkdir(d)
      vcode, = generate.call(CLASSES + HOST + extra, d)
      check.call("NEG #{what}: read_win keeps its by-name send", !checked.call(vcode, 'SpHost', 'read_win'))
    end
    d = File.join(dir, 'method_missing')
    Dir.mkdir(d)
    mm_code, = generate.call(CLASSES + HOST + "class SpHost\n  def method_missing(n, *a); 1; end\nend\n", d)
    check.call('a computed-name send in the world (SpDrv#wild) does not withdraw: its failure mode is the reader\'s guard violation',
               checked.call(code, 'SpHost', 'read_win'))
    check.call('a method_missing class changes nothing: it answers no call that has a definition', checked.call(mm_code, 'SpHost', 'read_win'))

    d = File.join(dir, 'native_call')
    Dir.mkdir(d)
    n_code, = generate.call(CLASSES + HOST, d,
                            native: [['sp_native.cxx', "#{NATIVE.first.last}static void sp_c2(mrb_state* M, mrb_value o) { mrb_funcall(M, o, \"spreg=\", 1, o); }\n"]])
    check.call('NEG a native that calls `spreg=` as well as registering it', !checked.call(n_code, 'SpHost', 'read_reg'))
    d = File.join(dir, 'native_sym')
    Dir.mkdir(d)
    s_code, = generate.call(CLASSES + HOST, d,
                            native: [['sp_native.cxx', "#{NATIVE.first.last}static void sp_c3(mrb_state* M, mrb_value o) { mrb_funcall_id(M, o, MRB_SYM_E(spreg), 1, o); }\n"]])
    check.call('NEG a native that calls it through MRB_SYM_E(spreg)', !checked.call(s_code, 'SpHost', 'read_reg'))
    d = File.join(dir, 'foreign')
    Dir.mkdir(d)
    f_code, = generate.call(CLASSES + HOST, d, foreign: [['sp_foreign.rb', "class SpOutside\n  def x(o); o.spwin = 1; end\nend\n"]])
    check.call('NEG a foreign Ruby source that spells spwin', !checked.call(f_code, 'SpHost', 'read_win'))

    { 'BC2CPP_SETTER_POOLS' => '0', 'BC2CPP_GUARD_VIOLATION' => '0', 'BC2CPP_CLASS_POOLS' => '0' }.each do |switch, value|
      d = File.join(dir, switch)
      Dir.mkdir(d)
      off_code, off_err = generate.call(CLASSES + HOST, d, env: { switch => value })
      check.call("#{switch}=#{value}: no checked pool and no checked arm",
                 !off_code.include?('CHECKED_POOL_EXACT') && !off_err.include?('CHECKED|'))
    end

    d = File.join(dir, 'open')
    Dir.mkdir(d)
    open_code, = generate.call(CLASSES + HOST, d, closed: false)
    check.call('the open world proves nothing', !open_code.include?('CHECKED_POOL_EXACT'))
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 2. behaviour -----------------------------------------------------------------------------------------------------

# The fixture needs Kernel#send, alias_method and interpolation: a full-core build, never the bare core.
build = runtime.full || runtime.full_or_build
if ENV['MRBC'] && build && runtime.compiler? && !ENV['SP_GENERATED_ONLY']
  puts '== fixture on real mruby, interpreted and compiled'
  body = <<~'CPP'
    static void sp_call(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc = 0,
                        const mrb_value* argv = nullptr) {
      mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
      if (M->exc) {
        mrb_value e = mrb_obj_value(M->exc);
        M->exc = nullptr;
        mrb_value msg = (mrb_funcall)(M, e, "message", 0);
        std::printf("%s => raised %s: %.*s\n", label, mrb_obj_classname(M, e), (int)RSTRING_LEN(msg), RSTRING_PTR(msg));
      } else {
        show(M, label, r);
      }
    }
    static void sp_quiet(mrb_state* M, mrb_value obj, const char* meth, int argc = 0, const mrb_value* argv = nullptr) {
      (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
      M->exc = nullptr;
    }
    static int scenario(mrb_state* M) {
      const char* mode = std::getenv("SP_SCENARIO");
      bool outside = mode && !std::strcmp(mode, "outside");
      bool computed = mode && !std::strcmp(mode, "computed");
      mrb_value host = mrb_obj_new(M, mrb_class_get(M, "SpHost"), 0, nullptr);
      mrb_value drv = mrb_obj_new(M, mrb_class_get(M, "SpDrv"), 0, nullptr);
      mrb_value box = mrb_obj_new(M, mrb_class_get(M, "SpBox"), 0, nullptr);
      mrb_value other = mrb_obj_new(M, mrb_class_get(M, "SpOther"), 0, nullptr);
      const char* reads[] = { "read_win", "read_wr", "read_mix", "read_prm", "read_send", "read_nat", "read_reg",
                              "read_alias", "read_bad", "read_str", "read_kw" };
      for (const char* name : reads) sp_call(M, (std::string(name) + " before fill").c_str(), host, name);
      mrb_value fill_args[] = { host, box };
      sp_quiet(M, drv, "fill", 2, fill_args);
      if (outside) {
        // A call of the setter from outside the closed world: the writer no scan of the build sees.
        sp_quiet(M, host, "spwin=", 1, &other);
        sp_quiet(M, host, "spwr=", 1, &other);
      }
      if (computed) {
        // A composed name: `send("#{stem}=", v)` from the driver, which no site of the world spells.
        mrb_value wild_args[] = { host, mrb_str_new_lit(M, "spwin"), other };
        sp_quiet(M, drv, "wild", 3, wild_args);
      }
      for (const char* name : reads) sp_call(M, name, host, name);
      mrb_value via[] = { host };
      sp_call(M, "via_win", host, "via_win", 1, via);
      mrb_value defs = (mrb_funcall)(M, drv, "fill_defs", 0);
      sp_call(M, "read_a", defs, "read_a");
      if (outside) {
        sp_quiet(M, defs, "spdv=", 1, &other);
        sp_call(M, "read_a after outside write", defs, "read_a");
      }
      return 0;
    }
  CPP
  Dir.mktmpdir do |dir|
    _code, err = generate.call(CLASSES + HOST, dir)
    full = File.exist?("#{build}/lib/libmruby.a")
    source = "#include <cstdlib>\n#include <cstring>\n#include <string>\n#include <mruby/string.h>\n#{body}"
    values = lambda do |output|
      sections = runtime.sections(output)
      [sections.fetch('interpreted', []).reject { |l| l.start_with?('  dispatches') },
       sections.fetch('compiled', []).reject { |l| l.start_with?('  dispatches') }]
    end
    built, results = runtime.run(dir, err, OWNERS, source, build: build, full: full,
                                                           envs: [{ 'SP_SCENARIO' => 'inside' }, { 'SP_SCENARIO' => 'outside' }, { 'SP_SCENARIO' => 'computed' }])
    check.call('the fixture compiles and runs against real mruby', built)
    if built
      (in_out, in_ok), (out_out, out_ok), (comp_out, comp_ok) = results
      interpreted, compiled = values.call(in_out)
      puts in_out if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
      check.call("every read answers what the interpreter answers (#{interpreted.size} lines), values and exceptions alike",
                 in_ok && !interpreted.empty? && interpreted == compiled)
      check.call('a nil receiver raises the interpreter\'s NoMethodError before any setter ran',
                 compiled.grep(/read_win before fill => raised NoMethodError: undefined method 'size' for NilClass/).size == 1)
      check.call('the mixed pool reached both classes (a wrong proof would answer 1 for the SpOther)',
                 compiled.include?('read_mix => 2') && compiled.include?('read_win => 1'))
      check.call('send(:spsend=, ..) and alias writes are seen (their reads answer the SpOther)',
                 compiled.include?('read_send => 2') && compiled.include?('read_alias => 2'))

      puts out_out if ENV['BC2CPP_CHECK_VERBOSE']
      interpreted, compiled = values.call(out_out)
      check.call('the interpreter answers the outside setter call (read_win => 2)', interpreted.include?('read_win => 2'))
      check.call('LOUD: the outside setter call is a guard violation in the compiled run, not a silent answer',
                 out_ok && compiled.any? { |l| l.start_with?('read_win => raised BC2cppGuardViolation: closed-world guard violation: SpOther#size at SpHost#read_win') } &&
                   compiled.none? { |l| l == 'read_win => 1' } &&
                   compiled.any? { |l| l.start_with?('read_a after outside write => raised BC2cppGuardViolation') })
    end

    if built
      interpreted, compiled = values.call(comp_out)
      check.call('the interpreter answers the composed-name call (read_win => 2)', interpreted.include?('read_win => 2'))
      check.call('LOUD: a composed name that stores a SpOther is a guard violation at the reader, not a silent answer',
                 comp_ok && compiled.any? { |l| l.start_with?('read_win => raised BC2cppGuardViolation: closed-world guard violation: SpOther#size at SpHost#read_win') } &&
                   compiled.none? { |l| l == 'read_win => 1' })
      check.call('the String-spelled setter is withdrawn, so its read answers the SpOther', compiled.include?('read_str => 2'))
    end

    Dir.mktmpdir do |off_dir|
      _off_code, off_err = generate.call(CLASSES + HOST, off_dir, env: { 'BC2CPP_SETTER_POOLS' => '0' })
      off_built, off_results = runtime.run(off_dir, off_err, OWNERS, source, build: build, full: full,
                                                                          envs: [{ 'SP_SCENARIO' => 'outside' }])
      if off_built
        interpreted, compiled = values.call(off_results.first.first)
        check.call('BC2CPP_SETTER_POOLS=0: the outside setter call answers what the interpreter answers',
                   !interpreted.empty? && interpreted == compiled)
      else
        check.call('BC2CPP_SETTER_POOLS=0 build', false)
      end
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
end

if failures.empty?
  puts 'bc2cpp setter pools check: PASS'
else
  warn "bc2cpp setter pools check: #{failures.size} failure(s)"
  exit 1
end
