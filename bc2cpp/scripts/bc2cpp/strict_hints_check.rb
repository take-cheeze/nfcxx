#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check STRICT_HINTS (docs/adr/0419): BC2CPP_STRICT_HINTS=1 turns the else arm of a guard on a
# whole-program class hint (TYPED, ELEMENT, IVAR_ACCESSOR, MONO_EMBED_GUARD) into bc2cpp_hint_violation.
#
# 1. Gate logic: family parsing, marker, listing, STRICT_HINTS_REVIEWED, the SymbolCache rewrite.
# 2. Generated code (needs MRBC): default output is byte-identical with the switch unset, empty and
#    `0`; the forced families carry the helper, the marker and the site and no by-name send; families
#    are selectable; the negatives keep their fallback (a class with a subclass, a name nil answers,
#    an exact core-type guard, a numeric arm); the reviewed gate fails an unlisted run.
# 3. Behaviour on real mruby (needs MRBC, a mruby build and g++): a program inside its hints answers
#    what the interpreter answers in both builds; with the hints deliberately violated (an
#    unexpected class where the annotation says ShWidget) the default build dispatches and answers
#    what the interpreter answers, the strict build logs `[RPG2k] hint violation: <Class>#<name> at
#    <Owner#method (FAMILY)>` and raises BC2cppHintViolation (a NoMethodError); -DBC2CPP_NOMETHOD_VERIFY
#    aborts naming class, name and site; -DBC2CPP_HINT_VIOLATION_DISPATCH dispatches again.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/strict_hints_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
# BC2CPP_TOOL names a mutant copy of the generator (strict_hints_mutation_check.rb); the gate logic is
# then the mutant's too.
tool_dir = File.dirname(ENV.fetch('BC2CPP_TOOL') { File.expand_path('../../tools/bc2cpp/bc2cpp.rb', __dir__) })
require File.join(tool_dir, 'strict_hints')
require File.join(tool_dir, 'symbol_cache')

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

# -- 1. the gate --------------------------------------------------------------------

puts '== switch, marker, listing, reviewed list'
# The gate only judges the families this run forces.
ENV['BC2CPP_STRICT_HINTS'] = '1'
check.call('0 selects no family; unset and empty select the default receiver-hint families',
           StrictHints.families('0').empty? && [nil, ''].all? { |v| StrictHints.families(v) == StrictHints::DEFAULT_FAMILIES })
check.call('1 selects the receiver-hint families, all every family',
           StrictHints.families('1') == StrictHints::DEFAULT_FAMILIES &&
             StrictHints.families('all') == StrictHints::FAMILIES &&
             (StrictHints::FAMILIES - StrictHints::DEFAULT_FAMILIES).sort ==
               %w[interface_table poly_small_n poly_table subtree])
check.call('a comma list selects those families', StrictHints.families('typed, ivar_accessor') == %w[typed ivar_accessor])
check.call('an unknown family is an error, not silently off',
           (begin
              StrictHints.families('typed,bogus')
              false
            rescue ArgumentError => e
              e.message.include?('bogus')
            end))
check.call('the exact-core-type and numeric families are not selectable',
           (%w[array hash string core fixnum float integer numeric native_exact core_exact] & StrictHints::FAMILIES).empty?)
marked = { owner: 'A', name: 'm', code: "r1 = x; #{StrictHints.marker('typed', 'foo')}\n" }
plain = { owner: 'B', name: 'n', code: "r1 = y;\n" }
compiled = [marked, plain]
sites = StrictHints.sites(compiled)
check.call('a marked site becomes its "Owner#method -> name (FAMILY)" key',
           sites.map { |s| s[:key] } == ['A#m -> foo (TYPED)'])
check.call('a listed site passes', StrictHints.violations(sites, compiled, reviewed: Set['A#m -> foo (TYPED)']).empty?)
check.call('an unlisted site fails',
           StrictHints.violations(sites, compiled, reviewed: Set[]) == ['unreviewed forced hint: A#m -> foo (TYPED)'])
check.call('a listed site gone from a compiled method fails as stale',
           StrictHints.violations(sites, compiled, reviewed: Set['A#m -> foo (TYPED)', 'B#n -> x (TYPED)']).first.to_s.start_with?('stale'))
check.call('a hot-only run (stale: false) checks unreviewed sites only',
           StrictHints.violations(sites, compiled, reviewed: Set['B#n -> gone (TYPED)'], stale: false) ==
             ['unreviewed forced hint: A#m -> foo (TYPED)'])
check.call('the stderr listing parses back',
           StrictHints.parse_listing("  STRICT_HINT_SITE A#m -> foo (TYPED)\n  STRICT_HINT TYPED: 1\n") == ['A#m -> foo (TYPED)'])
table = SymbolCache::Table.new
rewritten = SymbolCache.rewrite('r1 = bc2cpp_hint_violation_named(M, r1, "value", "A#m (TYPED)", 1, r2);', table)
check.call('SymbolCache turns the named call into an indexed one and flags the helper',
           rewritten == 'r1 = bc2cpp_hint_violation(M, r1, 0, "A#m (TYPED)", 1, r2);' && table.hint_violation_used)
check.call('the helper is emitted only when a site uses it',
           SymbolCache.emit(table).include?('bc2cpp_hint_violation_raise') &&
             !SymbolCache.emit(SymbolCache::Table.new).include?('bc2cpp_hint_violation_raise'))
check.call('an entry of a family this run does not force is not stale',
           StrictHints.violations(sites, compiled, reviewed: Set['A#m -> foo (TYPED)', 'B#n -> x (POLY_SMALL_N)']).empty?)
ENV.delete('BC2CPP_STRICT_HINTS')

# -- fixture ---------------------------------------------------------------------------

FIXTURE = <<~'RUBY'
  # nil answers this name, so a TYPED site on it has a legitimate non-hint receiver.
  class NilClass
    def sh_tag
      -1
    end
  end

  class ShWidget
    attr_reader :first
    attr_accessor :size

    def initialize
      @first = 'w'
      @size = 3
    end

    def length
      @size + 1
    end

    def push(k)
      @size * k
    end

    def to_s
      'widget'
    end

    def sh_tag
      [@size]
    end
  end

  class ShOther
    attr_accessor :size

    def length
      100
    end

    def push(k)
      k
    end

    def first
      'other'
    end

    def to_s
      'other'
    end

    def sh_tag
      []
    end

    def last
      2
    end
  end

  class ShBase
    def last
      1
    end
  end

  class ShSub < ShBase
  end

  class ShHolder
    # bc2cpp: (ShWidget)
    def initialize(w)
      @w = w
    end

    # bc2cpp: (ShWidget, fixnum)
    def take(w, k)
      w.push(k)
    end

    # bc2cpp: (Array<ShWidget>)
    def total(items)
      sum = 0
      items.each { |i| sum += i.length }
      sum
    end

    # CORE_BLOCK_ELEMENT_HINT: a map block (kept out of line by its rescue) whose element is typed by the
    # signature shape; that hint is soft, so its else arm keeps the by-name send.
    def soft_lengths
      [ShWidget.new].map do |i|
        n = i.length
        begin
          n / 0
        rescue ZeroDivisionError
          n
        end
      end
    end

    def read_value
      @w.length
    end

    def read_label
      @w.first
    end

    def read_size
      @w.size
    end

    def write_size(v)
      @w.size = v
    end

    def read_tag
      @w.sh_tag
    end

    def read_to_s
      @w.to_s
    end
  end

  class ShPair
    # bc2cpp: (ShBase)
    def initialize(b)
      @b = b
    end

    def run
      @b.last
    end
  end

  class ShNumeric
    # bc2cpp: (fixnum, fixnum)
    def add(a, b)
      a + b
    end
  end
RUBY
OWNERS = %w[ShHolder ShPair ShNumeric ShWidget ShOther ShBase ShSub].freeze
ENVS = [{ 'SH_SCENARIO' => 'ok' }, { 'SH_SCENARIO' => 'violate' }].freeze

chunk = lambda do |code, owner_method|
  code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
end
count = ->(text, needle) { text.scan(needle).size }

with_env = lambda do |overrides, &block|
  saved = overrides.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  block.call
ensure
  saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end
generate = lambda do |dir, strict, closed: true, proven: nil|
  with_env.call('BC2CPP_STRICT_HINTS' => strict, 'BC2CPP_STRICT_HINTS_PROVEN' => proven, StrictHints::ALLOW_ENV => 'allow') do
    runtime.generate(FIXTURE, dir, closed: closed, only_owners: OWNERS)
  end
end

VIOLATION = /\bbc2cpp_hint_violation\(M,/
DISPATCH = /\bbc2cpp_send\(M,|\bmrb_funcall\w*\(M,/

# -- 2. generated code -----------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    Dir.mktmpdir do |off_dir|
      Dir.mktmpdir do |zero_dir|
        base_code, base_err = generate.call(off_dir, '0')
        empty_code, = generate.call(zero_dir, '')
        unset_code, = generate.call(Dir.mktmpdir, nil)
        check.call('0 output has no hint violation, marker, helper or listing',
                   !base_code.match?(VIOLATION) && !base_code.include?('STRICT_HINT') &&
                     !base_code.include?('bc2cpp_hint_violation') && !base_err.include?('STRICT_HINT'))
        check.call('unset and empty are the same default output', unset_code == empty_code)
        check.call('the default output forces hints (it differs from the 0 baseline)',
                   empty_code.match?(VIOLATION) && empty_code != base_code)
        code, err = generate.call(dir, '1')
        check.call('the default output is the 1 output', empty_code == code)
        hint_sites = base_code.scan(DISPATCH).size - code.scan(DISPATCH).size
        %w[read_value read_label read_size].each do |m|
          text = chunk.call(code, "ShHolder##{m}")
          check.call("ShHolder##{m}: the guard's else arm is bc2cpp_hint_violation with its marker and site",
                     text.match?(VIOLATION) && text.include?('STRICT_HINT ') && text.include?("\"ShHolder##{m} (") &&
                       !text.include?('bc2cpp_send(') && !text.match?(/\bmrb_funcall\w*\(M,/))
        end
        check.call('NEG: an exact core-type guard chain (length on an untraced element) keeps its dispatch',
                   !chunk.call(code, 'ShHolder#total').match?(VIOLATION) &&
                     chunk.call(code, 'ShHolder#total').include?('bc2cpp_send(M, r10,'))
        check.call('the families are counted and listed on stderr',
                   err.include?('STRICT_HINT TYPED:') && err.include?('STRICT_HINT IVAR_ACCESSOR:') &&
                     err.include?('  STRICT_HINT_SITE ShHolder#read_value -> length (TYPED)') &&
                     err.include?('  STRICT_HINT_SITE ShHolder#read_size -> size (IVAR_ACCESSOR)'))
        check.call('every forced site removed a by-name dispatch',
                   hint_sites.positive? && count.call(code, VIOLATION) >= 5 &&
                     code.scan(DISPATCH).size < base_code.scan(DISPATCH).size)
        check.call('the helper is emitted, with its verify and dispatch defines',
                   code.include?('static mrb_value bc2cpp_hint_violation(mrb_state* M') &&
                     code.include?('BC2CPP_HINT_VIOLATION_DISPATCH') && code.include?('BC2cppHintViolation'))
        pcode, = generate.call(Dir.mktmpdir, '1', proven: '1')
        check.call('policy: without PROVEN a hint class with a subclass and a name nil answers are forced too',
                   chunk.call(code, 'ShPair#run').match?(VIOLATION) && chunk.call(code, 'ShHolder#read_tag').match?(VIOLATION))
        pair = chunk.call(pcode, 'ShPair#run')
        check.call('NEG: with BC2CPP_STRICT_HINTS_PROVEN=1 a hint class with a subclass keeps its dispatch (ShSub is legitimate)',
                   !pair.match?(VIOLATION) && !pair.include?('STRICT_HINT') && pair.match?(/mrb_funcall|bc2cpp_send|bc2cpp_nomethod/))
        to_a = chunk.call(pcode, 'ShHolder#read_tag')
        check.call('NEG: with BC2CPP_STRICT_HINTS_PROVEN=1 a name nil answers (sh_tag) keeps its dispatch',
                   !to_a.match?(VIOLATION) && to_a.match?(/mrb_funcall|bc2cpp_send|bc2cpp_nomethod/))
        # The block's out-of-line body is emitted ahead of its method's chunk.
        soft = code[/^static mrb_value ShHolder_soft_lengths_block_fallback_\d+_impl\(mrb_state.*?(?=^\/\/ \S+#\S+ \(compiled from)/m].to_s
        check.call('NEG: a core-iterator block element hint (CORE_BLOCK_ELEMENT_HINT) is typed but never forced',
                   soft.include?('ELEMENT :length -> ShWidget#length') && !soft.match?(VIOLATION) &&
                     !soft.include?('STRICT_HINT') && soft.match?(DISPATCH))
        add = chunk.call(code, 'ShNumeric#add')
        check.call('NEG: a numeric arm keeps its dispatch (Float/Bignum/overflow are valid)',
                   !add.match?(VIOLATION) && chunk.call(base_code, 'ShNumeric#add') == add)
        check.call('NEG: methods with no hinted send are byte-identical (ShNumeric, ShWidget, ShOther)',
                   %w[ShNumeric#add ShWidget#length ShOther#length].all? { |m| chunk.call(base_code, m) == chunk.call(code, m) })
      end
    end

    Dir.mktmpdir do |only_dir|
      only_code, only_err = generate.call(only_dir, 'typed')
      check.call('BC2CPP_STRICT_HINTS=typed forces TYPED sites only',
                 only_err.include?('STRICT_HINT TYPED:') && !only_err.include?('STRICT_HINT IVAR_ACCESSOR') &&
                   chunk.call(only_code, 'ShHolder#read_value').match?(VIOLATION) &&
                   !chunk.call(only_code, 'ShHolder#read_size').match?(VIOLATION))
    end

    Dir.mktmpdir do |open_dir|
      open_code, = generate.call(open_dir, '1', closed: false)
      check.call('the open world forces nothing (no closed-world facts to rely on)',
                 !open_code.match?(VIOLATION) && !open_code.include?('STRICT_HINT'))
    end

    Dir.mktmpdir do |gate_dir|
      env = { 'BC2CPP_STRICT_HINTS' => '1', StrictHints::ALLOW_ENV => nil, NomethodReviewed::ALLOW_ENV => nil }
      with_env.call(env) do
        begin
          runtime.generate(FIXTURE, gate_dir, closed: true, only_owners: OWNERS)
          check.call('the reviewed gate fails a run with unlisted forced sites', false)
        rescue RuntimeError => e
          check.call('the reviewed gate fails a run with unlisted forced sites',
                     e.message.include?('STRICT_HINTS_REVIEWED violation') && e.message.include?('unreviewed forced hint: ShHolder#'))
        end
      end
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 3. behaviour ----------------------------------------------------------------------

# The fixture's total() iterates with Array#each, which a core-only libmruby (no mrblib) does not have: the
# interpreted side needs the full-core build (BC2CPP_MRUBY_FULL, else one built once into BC2CPP_FULL_BUILD_DIR).
build = runtime.full_or_build
if ENV['MRBC'] && build && runtime.compiler? && !ENV['SH_GENERATED_ONLY']
  puts '== fixture on real mruby, interpreted and compiled'
  body = <<~'CPP'
    #include <cstdlib>
    #include <cstring>
    #include <mruby/string.h>
    static mrb_value sh_log_puts(mrb_state* M, mrb_value) {
      mrb_value line;
      mrb_get_args(M, "S", &line);
      std::printf("  LOG %.*s\n", (int)RSTRING_LEN(line), RSTRING_PTR(line));
      return mrb_nil_value();
    }
    static void sh_call(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc = 0,
                        const mrb_value* argv = nullptr) {
      mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
      if (M->exc) {
        mrb_value e = mrb_obj_value(M->exc);
        M->exc = nullptr;
        mrb_value msg = (mrb_funcall)(M, e, "message", 0);
        mrb_value is_nm = (mrb_funcall)(M, e, "is_a?", 1, mrb_obj_value(mrb_class_get(M, "NoMethodError")));
        std::printf("%s => raised %s%s: %.*s\n", label, mrb_obj_classname(M, e), mrb_test(is_nm) ? " (NoMethodError)" : "",
                    (int)RSTRING_LEN(msg), RSTRING_PTR(msg));
      } else {
        show(M, label, r);
      }
    }
    static int scenario(mrb_state* M) {
      const char* mode = std::getenv("SH_SCENARIO");
      bool violate = mode && !std::strcmp(mode, "violate");
      if (!mrb_class_defined(M, "NameError")) mrb_define_class(M, "NameError", M->eStandardError_class);
      if (!mrb_class_defined(M, "NoMethodError")) mrb_define_class(M, "NoMethodError", mrb_class_get(M, "NameError"));
      struct RClass* log = mrb_define_class(M, "ShLog", M->object_class);
      mrb_define_method(M, log, "puts", sh_log_puts, MRB_ARGS_REQ(1));
      mrb_gv_set(M, mrb_intern_lit(M, "$stderr"), mrb_obj_new(M, log, 0, nullptr));
      // The annotations promise ShWidget; the driver, outside the analysed world, hands over ShOther.
      mrb_value widget = mrb_obj_new(M, mrb_class_get(M, "ShWidget"), 0, nullptr);
      mrb_value other = mrb_obj_new(M, mrb_class_get(M, "ShOther"), 0, nullptr);
      mrb_value given = violate ? other : widget;
      mrb_value holder = mrb_obj_new(M, mrb_class_get(M, "ShHolder"), 1, &given);
      mrb_value three = mrb_fixnum_value(3), a2[] = { given, three };
      sh_call(M, "read_value", holder, "read_value");
      sh_call(M, "read_label", holder, "read_label");
      sh_call(M, "read_size", holder, "read_size");
      mrb_value ten = mrb_fixnum_value(10);
      sh_call(M, "write_size", holder, "write_size", 1, &ten);
      sh_call(M, "take", holder, "take", 2, a2);
      mrb_value items = mrb_ary_new(M);
      mrb_ary_push(M, items, given);
      sh_call(M, "total", holder, "total", 1, &items);
      mrb_value pair_arg = mrb_obj_new(M, mrb_class_get(M, "ShSub"), 0, nullptr);
      mrb_value pair = mrb_obj_new(M, mrb_class_get(M, "ShPair"), 1, &pair_arg);
      sh_call(M, "run_subclass", pair, "run");
      mrb_value n = mrb_obj_new(M, mrb_class_get(M, "ShNumeric"), 0, nullptr);
      mrb_value f[] = { mrb_float_value(M, 1.5), mrb_fixnum_value(2) };
      sh_call(M, "add_float", n, "add", 2, f);
      return 0;
    }
  CPP
  values = lambda do |output|
    sections = runtime.sections(output)
    [sections.fetch('interpreted', []).reject { |l| l.start_with?('  dispatches') },
     sections.fetch('compiled', []).reject { |l| l.start_with?('  dispatches') }]
  end
  outputs = lambda do |dir, err, flags = ''|
    saved = ENV.fetch('BC2CPP_CXXFLAGS', nil)
    ENV['BC2CPP_CXXFLAGS'] = [saved, flags].compact.reject(&:empty?).join(' ')
    begin
      full = File.exist?("#{build}/lib/libmruby.a")
      runtime.run(dir, err, OWNERS, body, build: build, full: full, envs: ENVS)
    ensure
      saved ? ENV['BC2CPP_CXXFLAGS'] = saved : ENV.delete('BC2CPP_CXXFLAGS')
    end
  end

  Dir.mktmpdir do |default_dir|
    _code, err = generate.call(default_dir, '0')
    built, results = outputs.call(default_dir, err)
    check.call('the off build (BC2CPP_STRICT_HINTS=0) compiles and runs against real mruby', built)
    if built
      (ok_out, ok_status), (bad_out, bad_status) = results
      interpreted, compiled = values.call(ok_out)
      puts ok_out if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
      check.call('off build, hints honoured: compiled answers what the interpreter answers',
                 ok_status && !interpreted.empty? && interpreted == compiled)
      check.call('  ... with the answers the fixture is written for',
                 interpreted.include?('read_value => 4') && interpreted.include?('take => 30'))
      interpreted, compiled = values.call(bad_out)
      puts bad_out if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
      check.call('off build, hints violated: the by-name dispatch answers what the interpreter answers',
                 bad_status && interpreted.include?('read_value => 100') && interpreted == compiled)
      check.call('  ... and logs no hint violation', !bad_out.include?('hint violation'))
    end
  end

  Dir.mktmpdir do |dir|
    _code, err = generate.call(dir, '1', proven: '1')
    built, results = outputs.call(dir, err)
    check.call('the strict build compiles and runs against real mruby', built)
    if built
      (ok_out, ok_status), (bad_out, bad_status) = results
      interpreted, compiled = values.call(ok_out)
      puts ok_out if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
      check.call('strict build, hints honoured: compiled answers what the interpreter answers',
                 ok_status && !interpreted.empty? && interpreted == compiled)
      check.call('  ... and logs no violation', !ok_out.include?('hint violation'))
      check.call('  ... including a subclass receiver, a Float argument and the nil-answering to_s',
                 compiled.include?('run_subclass => 1') && compiled.any? { |l| l.start_with?('add_float =>') })

      puts bad_out if ENV['BC2CPP_CHECK_VERBOSE']
      interpreted, compiled = values.call(bad_out)
      check.call('NEG: violated hints -- the interpreter dispatches and answers',
                 bad_status && interpreted.include?('read_value => 100') && interpreted.include?('take => 3'))
      %w[read_value read_label read_size].each do |label|
        line = compiled.find { |l| l.start_with?("#{label} =>") }.to_s
        check.call("NEG: strict #{label} raises BC2cppHintViolation (a NoMethodError), it does not dispatch",
                   line.include?('raised BC2cppHintViolation (NoMethodError): hint violation: ShOther#') &&
                     line.include?("at ShHolder##{label} ("))
      end
      compiled_log = bad_out.split('== compiled').last.to_s.lines.grep(/^  LOG /)
      check.call('NEG: each violation logs `[RPG2k] hint violation: <Class>#<name> at <Owner#method (FAMILY)>` to $stderr',
                 compiled_log.size == 3 && compiled_log.all? { |l| l.include?('[RPG2k] hint violation: ShOther#') } &&
                   compiled_log.any? { |l| l.include?('ShOther#length at ShHolder#read_value (TYPED)') } &&
                   compiled_log.any? { |l| l.include?('ShOther#size at ShHolder#read_size (IVAR_ACCESSOR)') })
      check.call('the interpreter run logs nothing', !bad_out.split('== compiled').first.include?('LOG '))
      check.call('NEG: the sites outside the forced families (subclass receiver, numeric) still answer the interpreter',
                 compiled.include?(interpreted.find { |l| l.start_with?('run_subclass =>') }) &&
                   compiled.include?(interpreted.find { |l| l.start_with?('add_float =>') }))
    end

    dispatch_built, dispatch_results = outputs.call(dir, err, '-DBC2CPP_HINT_VIOLATION_DISPATCH')
    check.call('-DBC2CPP_HINT_VIOLATION_DISPATCH builds', dispatch_built)
    if dispatch_built
      interpreted, compiled = values.call(dispatch_results.last.first)
      check.call('-DBC2CPP_HINT_VIOLATION_DISPATCH: the violated program answers what the interpreter answers',
                 !interpreted.empty? && interpreted == compiled && !dispatch_results.last.first.include?('hint violation'))
    end

    verify_built, verify_results = outputs.call(dir, err, '-DBC2CPP_NOMETHOD_VERIFY')
    check.call('-DBC2CPP_NOMETHOD_VERIFY builds', verify_built)
    if verify_built
      (ok_out, ok_status), (bad_out, bad_status) = verify_results
      check.call('verify mode: a program inside its hints reaches no forced site',
                 ok_status && !ok_out.include?('NOMETHOD_VERIFY'))
      check.call('verify mode: a reached forced site aborts naming the class, name and site',
                 !bad_status && bad_out.include?('NOMETHOD_VERIFY: hint violation reached: ShOther#') &&
                   bad_out.include?(' at ShHolder#'))
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or BC2CPP_FULL_BUILD_DIR) and have g++'
end

if failures.empty?
  puts 'bc2cpp strict hints check: PASS'
else
  warn "bc2cpp strict hints check: #{failures.size} failure(s)"
  exit 1
end
