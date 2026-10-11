#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check COMPUTED_SEND_EXPANSION (docs/adr/0303): a computed-name `send` whose name is provably one of a
# finite set of Symbols (a frozen constant Array/Hash of Symbol literals indexed at run time, or a
# register every reaching definition of which is a Symbol literal -- `case`/`when`, `?:`) becomes a
# chain of direct calls, one per name, and the by-name send survives only as the proof-violation arm.
#
# 1. Generated code (needs MRBC): the expanded sites, the arms, the violation arms, and ~20 negative
#    worlds in which the send must stay one computed send (parameter, unfrozen table, a subclass,
#    an installer, a singleton, method_missing, an overridden `send`, a private target for
#    public_send, a wrong arity, a rebound constant, a redefined Array#[]/Hash#[] ...).
# 2. Behaviour on real mruby (needs MRBC, a mruby build and g++): interpreted and compiled answer alike
#    -- values, side effects, exception classes and messages (`send(nil)`'s TypeError) -- and the
#    expanded sites make no dynamic dispatch. Builds: BC2CPP_MRUBY_FULL (full-core, `send`),
#    BC2CPP_MRUBY_CORE (core only, `__send__`), BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32 (32-bit mrb_int).
# 3. CSEND_MUTANTS=1 (needs 1): the generator with one proof removed at a time must fail a check.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=dir] [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/computed_send_check.rb

require 'fileutils'
require 'tmpdir'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless ENV['MRBC']
  puts '  SKIP: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  exit 0
end

require_relative 'fixture_runtime'
runtime = Bc2cppFixtureRuntime

# `ComputedSendBase` with the table shapes under test; %SEND% is `send` (full-core) or `__send__` (core).
def world(send_name, extra: '')
  <<~RUBY.gsub('%SEND%', send_name) + extra
    class CsCpu
      MODES = %i[imm zpg abs].freeze
      OPS = { 0 => :inc, 1 => :dec }.freeze
      UNFROZEN = %i[imm zpg]
      DUPED = %i[imm zpg].dup
      MIXED = [:imm, 'zpg'].freeze
      BAD = %i[imm one_arg].freeze
      OPNAME = [:imm, :+].freeze
      WIDE = [#{(0...30).map { |i| ":w#{i}" }.join(', ')}].freeze
      PRIVS = %i[hidden].freeze
      attr_reader :a

      def initialize
        @a = 0
      end

      def imm(_r, _w); @a += 1; :imm; end
      def zpg(_r, _w); @a += 2; :zpg; end
      def abs(_r, _w); @a += 3; :abs; end
      def one_arg(_x); :one; end
      def +(_r, _w); :plus; end
      def inc; @a += 10; :inc; end
      def dec; @a -= 10; :dec; end
      #{(0...30).map { |i| "def w#{i}(_r, _w); @a += #{i}; :w#{i}; end" }.join("\n  ")}

      def by_index(i)
        %SEND%(MODES[i], true, false)
      end

      def by_hash(k)
        %SEND%(OPS[k])
      end

      def by_case(k)
        n = case k
            when 0 then :imm
            when 1 then :zpg
            else :abs
            end
        %SEND%(n, true, false)
      end

      def by_ternary(k)
        %SEND%(k ? :inc : :dec)
      end

      def by_param(n)
        %SEND%(n, true, false)
      end

      def by_unfrozen(i)
        %SEND%(UNFROZEN[i], true, false)
      end

      def by_duped(i)
        %SEND%(DUPED[i], true, false)
      end

      def by_mixed(i)
        %SEND%(MIXED[i], true, false)
      end

      def by_bad(i)
        %SEND%(BAD[i], true, false)
      end

      def by_opname(i)
        %SEND%(OPNAME[i], true, false)
      end

      def by_wide(i)
        %SEND%(WIDE[i], true, false)
      end

      def fresh(i)
        c = CsCpu.new
        c.%SEND%(MODES[i], true, false)
        c.a
      end

      def by_priv(i)
        %SEND%(PRIVS[i])
      end

      private

      def hidden
        :hidden
      end
    end
  RUBY
end
PUBLIC_SEND = <<~RUBY
  class CsCpu
    def pub(k)
      public_send(OPS[k])
    end

    def pub_hidden(i)
      public_send(PRIVS[i])
    end
  end
RUBY

OWNERS = %w[CsCpu CsKid CsGhost].freeze

sym_names = ->(code) { code[/bc2cpp_sym_names\[\d+\] = \{(.*?)\};/m, 1].to_s.scan(/"((?:[^"\\]|\\.)*)"/).flatten }
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
# By-name sends of `name` in one body (a checked slot spells the name too).
sends_of = lambda do |code, body, name|
  names = sym_names.call(code)
  names.each_index.select { |i| names[i] == name }.sum { |i| body.scan(/bc2cpp_send\(M, [^,]+, #{i},/).size }
end
expanded = ->(body) { body.include?('// COMPUTED_SEND :') }
# A computed send's arms are the `r = <Class>_<name>_impl(M, ...)` lines. The frozen table's own index (`MODES[i]`, ADR
# 0394) calls the exposed Array body in its else, which is not an arm of the expansion.
arms_of = ->(body) { body.scan(/^\s*r\d+ = (?!mrb_ary_aget1_impl\(|mrb_ary_aset2_impl\()\w+_impl\(M, /).size }

generate = lambda do |source, closed: true, env: {}, **options|
  saved = env.map { |k, _| [k, ENV[k]] }
  env.each { |k, v| ENV[k] = v }
  begin
    Dir.mktmpdir { |dir| runtime.generate(source, dir, closed: closed, only_owners: OWNERS, **options).first }
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end

# -- 1. generated code -----------------------------------------------------------------------

puts '== generated code'
SITES = %w[by_index by_hash by_case by_ternary].freeze
# fresh: an explicit receiver whose arms would keep a guard fallback (ADR 0303).
NOT_EXPANDED = %w[by_param by_unfrozen by_duped by_mixed by_bad by_wide by_opname fresh].freeze
# The original computed call is still there: a by-name send, or the direct call of a user-defined `send`.
original_call = ->(code, body, name) { sends_of.call(code, body, name) == 1 || body.include?("_#{name}_impl(M") }

[%w[send closed], %w[__send__ closed], %w[__send__ open]].each do |send_name, kind|
  closed = kind == 'closed'
  if send_name == 'send'
    code = generate.call(world('send') + PUBLIC_SEND)
    check.call("NEG: send and public_send (mruby-metaprog) are never expanded: a harness or build without the gem answers NoMethodError", !code.include?('// COMPUTED_SEND :'))
    next
  end
  label = "#{send_name}, #{kind} world"
  code = generate.call(world(send_name) + (send_name == 'send' ? PUBLIC_SEND : ''), closed: closed)
  # An open world proves no arm direct (every guard chain keeps its by-name else), so nothing expands.
  SITES.each do |fn|
    body = body_of.call(code, "CsCpu_#{fn}")
    check.call("#{label}: #{fn} #{closed ? 'is expanded into direct arms' : 'keeps its computed send'}", expanded.call(body) == closed)
    next unless closed

    check.call("#{label}: #{fn} has no by-name #{send_name}, only the two violation arms",
               sends_of.call(code, body, send_name).zero? && body.scan('bc2cpp_guard_violation(').size == 2)
  end
  unless closed
    check.call("NEG: #{label}: nothing in the module is expanded", !code.include?('// COMPUTED_SEND :'))
    next
  end
  body = body_of.call(code, 'CsCpu_by_index')
  check.call("#{label}: by_index is three direct calls over imm/zpg/abs", arms_of.call(body) == 3 && body.include?('over imm/zpg/abs'))
  check.call("#{label}: the table index in by_index is the exposed Array body (ADR 0394), not a by-name []", body.include?('mrb_ary_aget1_impl(M, ') && !body.include?('"[]"'))
  check.call("#{label}: a table site rejects nil as Kernel##{send_name} does (TypeError), a literal site cannot see nil",
             body.include?('mrb_obj_to_sym(M') && !body_of.call(code, 'CsCpu_by_case').include?('mrb_obj_to_sym'))
  check.call("#{label}: by_hash is two direct calls over the Hash's values", arms_of.call(body_of.call(code, 'CsCpu_by_hash')) == 2)
  check.call("#{label}: by_case is three direct calls", arms_of.call(body_of.call(code, 'CsCpu_by_case')) == 3)
  check.call("#{label}: by_ternary is two direct calls", arms_of.call(body_of.call(code, 'CsCpu_by_ternary')) == 2)
  # `send` ignores visibility, so a private target is an ordinary arm.
  check.call("#{label}: a private target is an arm (#{send_name} ignores visibility)",
             expanded.call(body_of.call(code, 'CsCpu_by_priv')) && arms_of.call(body_of.call(code, 'CsCpu_by_priv')) == 1)
  NOT_EXPANDED.each do |fn|
    body = body_of.call(code, "CsCpu_#{fn}")
    check.call("NEG: #{label}: #{fn} keeps its one computed #{send_name}", !expanded.call(body) && sends_of.call(code, body, send_name) == 1)
  end
end

puts '== negative worlds: the site must stay one computed send'
# [what, extra source, method that must not be expanded, generate options]
KID = "class CsKid < CsCpu; def imm(_r, _w); :kid; end; end\n"
NEGATIVE_WORLDS = [
  ['a subclass overrides one of the names', KID, 'by_index', {}],
  ['a subclass overrides one of the names (literal set)', KID, 'by_case', {}],
  ['define_method installs one of the names', "class CsCpu; define_method(:zpg) { |_r, _w| :dm }; end\n", 'by_case', {}],
  ['define_method with a computed name', "class CsCpu; %w[q r].each { |n| define_method(n) { :dm } }; end\n", 'by_case', {}],
  ['alias_method gives one of the names another body', "class CsCpu; alias_method :zpg, :abs; end\n", 'by_case', {}],
  ['a singleton method on an instance', "CS_ONE = CsCpu.new\ndef CS_ONE.imm(_r, _w); :one; end\n", 'by_case', {}],
  ['a singleton class opened on an instance', "CS_TWO = CsCpu.new\nclass << CS_TWO; def zpg(_r, _w); :two; end; end\n", 'by_case', {}],
  ['define_singleton_method', "CsCpu.new.define_singleton_method(:abs) { |_r, _w| :three }\n", 'by_case', {}],
  ['a method_missing class', "class CsGhost; def method_missing(n, *a); :ghost; end; end\n", 'by_case', {}],
  ['send itself is redefined', "class CsCpu; def __send__(*a); :mine; end; end\n", 'by_case', {}],
  ['a second, unfrozen definition of the table', "class CsCpu; MODES = %i[imm zpg]; end\n", 'by_index', {}],
  ['the table name is also a class', "class MODES; end\n", 'by_index', {}],
  ['const_set rebinds constants at run time', "Object.const_set(:CS_ANY, 1)\n", 'by_index', {}],
  ['remove_const', "class CsCpu; remove_const(:OPS); end\n", 'by_hash', {}],
  ['Hash#[] is redefined', "class Hash; def [](k); :abs; end; end\n", 'by_hash', {}],
  ['Array#[] is redefined', "class Array; def [](i); :abs; end; end\n", 'by_index', {}],
  ['Kernel#freeze is redefined', "module Kernel; def freeze; self; end; end\n", 'by_index', {}],
  ['a foreign Ruby source also defines the table name', '', 'by_index', { foreign: [['f.rb', "MODES = 1\n"]] }],
  ['a native source also defines the table name', '', 'by_index',
   { native: [['n.c', "void f(mrb_state *M) { mrb_define_const(M, c, \"MODES\", v); }\n"]] }]
].freeze
NEGATIVE_WORLDS.each do |what, extra, fn, options|
  code = generate.call(world('__send__', extra: extra), **options)
  body = body_of.call(code, "CsCpu_#{fn}")
  kept = !body.empty? && !expanded.call(body) && original_call.call(code, body, '__send__')
  puts body.lines.grep(/COMPUTED_SEND|__send__|bc2cpp_send/).join if !kept && ENV['CSEND_VERBOSE']
  check.call("NEG: #{what}: #{fn} keeps its computed send", kept)
end

# A rebinding that leaves the other site alone: the control proves the negative is the cause.
[['a class nothing uses', "class CsGhost; end\n", 'by_case'],
 ['a second frozen definition of the table', "class CsCpu; MODES = %i[imm].freeze; end\n", 'by_index']].each do |what, extra, fn|
  body = body_of.call(generate.call(world('__send__', extra: extra)), "CsCpu_#{fn}")
  check.call("control: #{what} leaves #{fn} expanded", expanded.call(body))
end

puts '== kill switches'
count = ->(code) { code.scan('// COMPUTED_SEND :').size }
on = generate.call(world('__send__'))
off = generate.call(world('__send__'), env: { 'BC2CPP_COMPUTED_SEND' => '0' })
off_violation = generate.call(world('__send__'), env: { 'BC2CPP_GUARD_VIOLATION' => '0' })
converted = (SITES + %w[by_priv fresh]).select { |fn| expanded.call(body_of.call(on, "CsCpu_#{fn}")) }
check.call('BC2CPP_COMPUTED_SEND=0 expands nothing and every converted site is one by-name send',
           converted.size >= SITES.size + 1 && count.call(on) == converted.size && count.call(off).zero? &&
             converted.all? { |fn| sends_of.call(off, body_of.call(off, "CsCpu_#{fn}"), '__send__') == 1 })
check.call('BC2CPP_GUARD_VIOLATION=0 also keeps the by-name send', count.call(off_violation).zero?)
check.call('the by-name sends rise by exactly the converted sites',
           sends_of.call(off, off, '__send__') - sends_of.call(on, on, '__send__') == converted.size)
check.call('the violation arm names its family', on.include?('(COMPUTED_SEND)"') && on.include?('/* CLOSED_WORLD guard-violation: __send__ */'))

puts '== name proofs (SymbolTables / names_at on compiled bytecode)'
$LOAD_PATH.unshift(File.expand_path('../../tools/bc2cpp', __dir__))
require 'irep'
require 'bytecode_ir'
require 'computed_send_names'

ireps_of = lambda do |source, dir|
  path = File.join(dir, 'unit.rb')
  File.write(path, source)
  compile_ireps([path], 'unit', dir).first
end
tables_of = lambda do |source, native: [], foreign: []|
  Dir.mktmpdir do |dir|
    paths = ->(pairs) { pairs.map { |name, text| File.join(dir, name).tap { |file| File.write(file, text) } } }
    ComputedSendNames::SymbolTables.analyze(ireps_of.call(source, dir), paths.call(native), paths.call(foreign))
  end
end
names = ->(tables, name) { tables[name]&.to_a&.sort }

t = tables_of.call("A = %i[x y].freeze\nB = [:p, :q].freeze\nC = { 0 => :m, 1 => :n }.freeze\nD = { 'k' => :v }.freeze\n")
check.call('a frozen Symbol Array (%i and :sym forms) and Hash values are tables; keys are never read',
           names.call(t, 'A') == %w[x y] && names.call(t, 'B') == %w[p q] && names.call(t, 'C') == %w[m n] && names.call(t, 'D') == %w[v])
t = tables_of.call("E = %i[x y]\nF = %i[x].dup\nG = [:x, 1].freeze\nH = [:x, 'y'].freeze\nI = [].freeze\nJ = {}.freeze\nK = [:x, :y].map(&:to_s).freeze\n")
check.call('NEG: an unfrozen, duplicated, mixed, empty or computed table is not one', %w[E F G H I J K].all? { |n| t[n].nil? })
t = tables_of.call("A = %i[x].freeze\nclass P; A = %i[y z].freeze; end\nB = %i[x].freeze\nclass P; B = %i[y]; end\n")
check.call('two definitions of a bare name give the union; one of another shape poisons it',
           names.call(t, 'A') == %w[x y z] && t['B'].nil?)
check.call('NEG: const_set / remove_const / autoload anywhere refuses every table',
           %w[Object.const_set(:Z,1) Object.send(:remove_const,:Z) autoload(:Z,"z")].all? do |call|
             tables_of.call("A = %i[x].freeze\n#{call}\n").empty?
           end)
check.call('NEG: a CLASS or MODULE of the name, a foreign `NAME =` and a native definition poison it',
           tables_of.call("A = %i[x].freeze\nclass A; end\n")['A'].nil? &&
             tables_of.call("A = %i[x].freeze\n", foreign: [['f.rb', "A = 1\n"]])['A'].nil? &&
             tables_of.call("A = %i[x].freeze\n", native: [['n.c', "void f() { mrb_define_const(M, c, \"A\", v); }\n"]])['A'].nil? &&
             tables_of.call("A = %i[x].freeze\nmodule A; end\n")['A'].nil?)
check.call('NEG: without the native and foreign source lists nothing is proven (unscanned outside world)',
           ComputedSendNames::SymbolTables.analyze({}, nil, []).empty? && ComputedSendNames::SymbolTables.analyze({}, [], nil).empty?)

Dir.mktmpdir do |dir|
  ireps = ireps_of.call(<<~RUBY, dir)
    T = %i[a b].freeze
    class U
      def lit(k)
        send(k ? :x : :y)
      end
      def table(i)
        send(T[i])
      end
      def param(n)
        send(n)
      end
      def mixed(k)
        send(k ? :x : T[0])
      end
      def reassigned(k)
        n = :x
        n = k
        send(n)
      end
      def sym_or_str(k)
        send(k ? :x : 'y')
      end
    end
  RUBY
  tables = ComputedSendNames::SymbolTables.analyze(ireps, [], [])
  sends = ireps.values.flat_map do |irep|
    irep.instructions.each_with_index.filter_map { |insn, idx| [irep, idx, insn] if insn.op == 'SSEND' && insn.sym == 'send' }
  end
  results = sends.map { |irep, idx, insn| ComputedSendNames.names_at(irep, idx, insn.reg.to_i + 1, tables) }
  by_shape = results.map { |r| r && [r.names.sort, r.nilable, r.source] }
  p by_shape if ENV["CSEND_VERBOSE"]
  check.call('names_at: a ?: over literals, a table index (nilable), a mixed join; refused: a parameter, a reassigned register, a String',
             by_shape.compact.sort_by(&:to_s) == [[%w[a b], true, 'table'], [%w[a b x], true, 'literal+table'], [%w[x y], false, 'literal']].sort_by(&:to_s) &&
               by_shape.count(nil) == 3)
end

# -- 2. behaviour ------------------------------------------------------------------------------

SCENARIO = <<~'CPP'
  static void call_msg(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc, const mrb_value* argv) {
    dispatches = 0;
    mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
    int made = dispatches;
    if (M->exc) {
      mrb_value e = mrb_obj_value(M->exc);
      M->exc = nullptr;
      mrb_value msg = (mrb_funcall)(M, e, "message", 0);
      std::printf("%s => raised %s: %.*s\n", label, mrb_obj_classname(M, e), (int)RSTRING_LEN(msg), RSTRING_PTR(msg));
    } else {
      show(M, label, r);
    }
    if (compiled) std::printf("  dispatches=%d\n", made);
  }
  #define CALL1(label, obj, meth, arg) { mrb_value av[] = { arg }; call_msg(M, label, obj, meth, 1, av); }
  static int scenario(mrb_state* M) {
    if (!mrb_class_defined(M, "NameError")) mrb_define_class(M, "NameError", M->eStandardError_class);
    if (!mrb_class_defined(M, "NoMethodError")) mrb_define_class(M, "NoMethodError", mrb_class_get(M, "NameError"));
    mrb_value cpu = mrb_obj_new(M, mrb_class_get(M, "CsCpu"), 0, nullptr);
    mrb_gc_protect(M, cpu);
    auto I = [](int n) { return mrb_fixnum_value(n); };
    mrb_value t = mrb_true_value(), f = mrb_false_value(), n = mrb_nil_value();
    mrb_value x = mrb_str_new_cstr(M, "x");
    mrb_value imm = mrb_symbol_value(mrb_intern_lit(M, "imm"));
    for (int i : { 0, 1, 2, -1, 3, 7 }) {
      char label[32];
      std::snprintf(label, sizeof label, "by_index(%d)", i);   CALL1(label, cpu, "by_index", I(i));
      std::snprintf(label, sizeof label, "by_unfrozen(%d)", i); CALL1(label, cpu, "by_unfrozen", I(i));
      std::snprintf(label, sizeof label, "by_duped(%d)", i);    CALL1(label, cpu, "by_duped", I(i));
      std::snprintf(label, sizeof label, "by_mixed(%d)", i);    CALL1(label, cpu, "by_mixed", I(i));
      std::snprintf(label, sizeof label, "by_bad(%d)", i);      CALL1(label, cpu, "by_bad", I(i));
      std::snprintf(label, sizeof label, "by_wide(%d)", i);     CALL1(label, cpu, "by_wide", I(i));
      std::snprintf(label, sizeof label, "by_case(%d)", i);     CALL1(label, cpu, "by_case", I(i));
      std::snprintf(label, sizeof label, "fresh(%d)", i);       CALL1(label, cpu, "fresh", I(i));
      std::snprintf(label, sizeof label, "by_priv(%d)", i);     CALL1(label, cpu, "by_priv", I(i));
    }
    for (int k : { 0, 1, 2, -1 }) {
      char label[32];
      std::snprintf(label, sizeof label, "by_hash(%d)", k); CALL1(label, cpu, "by_hash", I(k));
    }
    CALL1("by_hash(nil)", cpu, "by_hash", n);
    CALL1("by_index(str)", cpu, "by_index", x);
    CALL1("by_ternary(true)", cpu, "by_ternary", t);
    CALL1("by_ternary(false)", cpu, "by_ternary", f);
    CALL1("by_ternary(nil)", cpu, "by_ternary", n);
    CALL1("by_param(imm)", cpu, "by_param", imm);
    CALL1("by_param(nil)", cpu, "by_param", n);
    CALL1("by_param(str)", cpu, "by_param", x);
    CALL1("by_param(1)", cpu, "by_param", I(1));
    call_msg(M, "a", cpu, "a", 0, nullptr);
    if (mrb_respond_to(M, cpu, mrb_intern_lit(M, "pub"))) {
      for (int k : { 0, 1, 5 }) {
        char label[32];
        std::snprintf(label, sizeof label, "pub(%d)", k); CALL1(label, cpu, "pub", I(k));
      }
      // pub_hidden is not run: a by-name public_send from compiled code skips the visibility check (ADR 0303).
      call_msg(M, "a2", cpu, "a", 0, nullptr);
    }
    return 0;
  }
CPP
NO_DISPATCH = (%w[by_index by_case by_hash] .product([0, 1, 2, -1, 3, 7]).map { |fn, i| "#{fn}(#{i})" } +
               %w[by_hash(nil) by_ternary(true) by_ternary(false) by_ternary(nil) pub(0) pub(1) pub(5)]).freeze
NO_DISPATCH_DROP = %w[by_hash(2) by_hash(3) by_hash(7) by_hash(-1) by_case(-1)].freeze # raise through a fallback or are unrelated

builds = []
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds << ['mrb_int 64, full-core', full, true, ENV['MRBC'], '', '__send__'] if full && runtime.compiler?
builds << ['mrb_int 64, core only', runtime.core, false, ENV['MRBC'], '', '__send__'] if runtime.core && runtime.compiler?
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32'] && runtime.compiler?
  builds << ['mrb_int 32, full-core', ENV['BC2CPP_MRUBY_FULL32'], true, ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie', '__send__']
end
builds.clear if ENV['CSEND_GENERATED_ONLY']
puts '== behaviour: SKIP, set BC2CPP_MRUBY_FULL / BC2CPP_FULL_BUILD_DIR / BC2CPP_MRUBY_CORE and have g++' if builds.empty?

values = ->(sections, name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') }.map { |l| l.gsub(/0x\h+/, '0xADDR') } }
run_world = lambda do |source, build, full_flag, closed|
  Dir.mktmpdir do |dir|
    _code, err = runtime.generate(source, dir, closed: closed, only_owners: OWNERS)
    built, output = runtime.run(dir, err, OWNERS, SCENARIO, build: build, full: full_flag)
    puts output unless built
    built ? runtime.sections(output) : nil
  end
end

builds.each do |label, build, full_flag, mrbc, flags, send_name|
  [true, false].each do |closed|
    next unless closed || label == builds.first.first

    puts "== behaviour on real mruby (#{label}, #{closed ? 'closed' : 'open'} world, #{send_name}), interpreted and compiled"
    saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
    ENV['MRBC'] = mrbc
    ENV['BC2CPP_CXXFLAGS'] = [saved.last, flags].compact.reject(&:empty?).join(' ')
    begin
      sections = run_world.call(world(send_name) + (send_name == 'send' ? PUBLIC_SEND : ''), build, full_flag, closed)
      check.call('the fixture compiles and runs against real mruby', !sections.nil?)
      next unless sections

      interpreted = values.call(sections, 'interpreted')
      compiled = values.call(sections, 'compiled')
      check.call("compiled answers what the interpreter answers (#{interpreted.size} calls)", interpreted.size > 60 && interpreted == compiled)
      interpreted.zip(compiled).each { |i, c| puts "    interpreted: #{i[0, 300]}\n    compiled:    #{c.to_s[0, 300]}" unless i == c }
      text = interpreted.join("\n")
      check.call('the table, case and ternary sites answer every name', %w[by_index(0) by_index(1) by_index(2)].zip(%w[:imm :zpg :abs]).all? { |l, v| text.include?("#{l} => #{v}") } &&
                 text.include?('by_index(-1) => :abs') && text.include?('by_ternary(true) => :inc') && text.include?('by_ternary(nil) => :dec'))
      check.call('the side effects of the arms are those of the interpreter', text.include?('a => '))
      if full_flag
        check.call("a nil from the table raises the TypeError #{send_name}(nil) raises",
                   text.include?('by_index(3) => raised TypeError: nil is not a symbol nor a string') &&
                   text.include?('by_hash(-1) => raised TypeError: nil is not a symbol nor a string'))
        check.call('a wrong arity still raises ArgumentError', text.include?('by_bad(1) => raised ArgumentError'))
      else
        check.call('a nil from the table raises TypeError', text.include?('by_index(3) => raised TypeError'))
      end
      per = sections.fetch('compiled', []).each_cons(2).select { |_, n| n.include?('dispatches=') }
                    .to_h { |l, n| [l[/\A\S+/], n[/dispatches=(\d+)/, 1].to_i] }
if closed
  silent = (NO_DISPATCH - NO_DISPATCH_DROP).select { |k| per.key?(k) }
  check.call("the expanded sites make no dynamic dispatch (#{silent.size} calls)", silent.size > 15 && silent.all? { |k| per[k].zero? })
else
  check.call('the open world dispatches by name (nothing is expanded there)', per['by_case(0)'].to_i.positive?)
end
      check.call('the sites with no proof still dispatch by name', per['by_param(imm)'].to_i.positive? && per['by_unfrozen(0)'].to_i.positive?)
    ensure
      ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
    end
  end
end

# The negative worlds also answer like the interpreter (they keep the computed send).
BEHAVIOUR_NEGATIVES = {
  'a subclass overrides imm' => "class CsKid < CsCpu; def imm(_r, _w); :kid; end; end\n",
  'a singleton on an instance' => "CS_ONE = CsCpu.new\ndef CS_ONE.imm(_r, _w); :one; end\n",
  'a method_missing class' => "class CsGhost; def method_missing(n, *a); :ghost; end; end\n",
  'Hash#[] is redefined' => "class Hash; def [](k); :abs; end; end\n"
}.freeze
builds.first(1).each do |label, build, full_flag, mrbc, flags, send_name|
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = flags
  begin
    BEHAVIOUR_NEGATIVES.each do |what, extra|
      sections = run_world.call(world(send_name, extra: extra) + (send_name == 'send' ? PUBLIC_SEND : ''), build, full_flag, true)
      same = !sections.nil? && values.call(sections, 'interpreted').size > 60 && values.call(sections, 'interpreted') == values.call(sections, 'compiled')
      check.call("#{what} (#{label}): compiled answers what the interpreter answers", same)
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

# -- 3. mutants --------------------------------------------------------------------------------

# Each mutant removes one proof from a copy of the generator; the generated-code checks above
# (CSEND_GENERATED_ONLY=1 skips the runs) must then fail.
MUTANTS = {
  'tools/bc2cpp/computed_send_names.rb' => {
    'a table need not be frozen' => ["call.sym == 'freeze'", 'true'],
    'a foreign definition of the table name is ignored' => ['poisoned.merge(IntegerConstants.foreign_const_names(foreign_paths))', ''],
    'a native definition of the table name is ignored' => ['poisoned.merge(IntegerConstants.native_defined_const_names(native_paths))', ''],
    'a CLASS of the table name is ignored' => ["when 'CLASS', 'MODULE'", "when 'NEVER'"],
    'const_set is ignored' => ['return {} if rebinder?(ireps)', ''],
    'the name set has no size limit' => ['MAX_NAMES = 24', 'MAX_NAMES = 1000'],
    'a name that is not a plain method name is accepted' => ['names.all? { |n| n.match?(PLAIN_NAME) }', 'true'],
    'a String element passes for a Symbol' => ["%w[LOADSYM SYMBOL].include?(insn.op)", 'true'],
    'a table definition of another shape is accepted' => ['found.empty? || found.any?(&:nil?)', 'found.empty?']
  },
  'tools/bc2cpp/codegen_computed_send.rb' => {
    '__send__ is trusted to be the core one' => ["@registry.fetch(name, []).all? { |definition| definition.owner == '<native>' }", 'true'],
    'an arm may keep a by-name dispatch' => ['live.include?(\'_impl(M\') && !live.match?(DYNAMIC_ARM)', 'true'],
    'Array#[] and freeze are trusted' => ['(TABLE_READERS + TABLE_FREEZERS).all? do |owner, name|', '(TABLE_READERS + TABLE_FREEZERS).all? do |owner, name|
      next true'],
    'a method_missing class does not withdraw' => ['@closed_world.method_missing_classes.empty?', 'true'],
    'a nil from a table is not rejected' => ['out << "      (void)mrb_obj_to_sym(M, #{var});\n" if names.nilable', ''],
    'the kill switch is ignored' => ["ENV[KILL_SWITCH] != '0' && ", ''],
    'a singleton on an instance does not withdraw' => ['@closed_world.exact_instances_singleton_free? &&', 'true &&'],
    'an installed name does not withdraw' => ['devirt_blocked_name?(name) || symbol_installed_names.include?(name)', 'false'],
    'an unresolved installer does not withdraw' => ['&& !symbol_installed_names.nil?', '']
  }
}.freeze
if ENV['CSEND_MUTANTS'] && ENV['CSEND_GENERATED_ONLY'].nil?
  puts '== mutants: one proof removed, a generated-code check must fail'
  require_relative 'mutant_pool'
  root = File.expand_path('../..', __dir__)
  # nil when the mutation does not apply, else the run of the check against the mutant.
  mutate = lambda do |(file, _what, from, to)|
    Dir.mktmpdir do |tmp|
      Dir.children(root).each do |entry|
        next if %w[.git tools scripts build].include?(entry)

        FileUtils.ln_s(File.join(root, entry), File.join(tmp, entry))
      end
      FileUtils.cp_r(File.join(root, 'tools'), tmp)
      FileUtils.cp_r(File.join(root, 'scripts'), tmp)
      path = File.join(tmp, file)
      text = File.read(path)
      mutated = text.sub(from, to)
      next nil if mutated == text

      File.write(path, mutated)
      # Stops at the first FAIL line: the mutant is caught (Bc2cppMutantPool.run).
      Bc2cppMutantPool.run({ 'CSEND_GENERATED_ONLY' => '1', 'CSEND_MUTANTS' => nil },
                           [RbConfig.ruby, File.join(tmp, 'scripts/bc2cpp/computed_send_check.rb')], stop_on: /^\s+FAIL /)
    end
  end
  jobs = MUTANTS.flat_map { |file, mutants| mutants.map { |what, (from, to)| [file, what, from, to] } }
  Bc2cppMutantPool.each_ordered(jobs, work: mutate) do |(_file, what), run|
    if run.nil?
      check.call("mutant (#{what}) applies", false)
    else
      check.call("mutant (#{what}) is caught", !run.success)
    end
  end
end

puts(failures.empty? ? 'bc2cpp_computed_send_check OK' : "FAILED: #{failures.size}")
exit(failures.empty? ? 0 : 1)
