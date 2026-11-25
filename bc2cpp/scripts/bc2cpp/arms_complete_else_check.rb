#!/usr/bin/env ruby
# frozen_string_literal: true

# Check ARMS_COMPLETE_ELSE (tools/bc2cpp/codegen_arms_complete_else.rb) on closed-world fixtures:
#   0. the chain reader on hand-written shapes: the arm forms it takes, a statement or a writing test that stops it, a
#      conjunction that is no arm, a class variable read from another register;
#   1. generated code: `o.key?(x)` over Hash (core fast arm), Tbl (bc2cpp_class_is) and Tbl's subclass Sub (an exact
#      mrb_class arm), `o.bytesize` behind the String arm, and the block call `o.visit(x) { }` over Box and Crate become
#      the proven nomethod; `o.times { }` behind a fixnum-only arm keeps its owner call (a bignum is an Integer too);
#   2. a world with `class MyHash < Hash` keeps key?'s owner call (Hash is subclassed), and one where a Box gets a
#      singleton class keeps visit's (the raw-class arms miss it); BC2CPP_ARMS_COMPLETE_ELSE=0 keeps them all;
#   3. each world run on a full-core mruby, compiled against interpreted: every receiver (an armed one, a subclass,
#      a singleton, nil, an Integer, a String) gives the same value or error.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/arms_complete_else_check.rb
# The run needs a full-core libmruby built from this tree's patched 3rd/mruby (BC2CPP_MRUBY_FULL, or one built here).

require 'tmpdir'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# 0. the chain reader.
require_relative '../../tools/bc2cpp/nomethod_reviewed'
class CodeGen; def self.prepend(*); end; end unless defined?(CodeGen)
require_relative '../../tools/bc2cpp/codegen_arms_complete_else'
scan = ArmsCompleteElseScan
arms_of = lambda do |shape|
  found = []
  out = scan.rewrite(shape) { |owners, arms, _m| found << [owners, arms]; true }
  [found, out]
end
TAIL = 'r4 = bc2cpp_owner_call_named(M, r4, "key?", 2, BC2CPP_OWNERS("Hash", "Tbl"), mrb_nil_value(), 1, r5, self); ' \
       '/* CLOSED_WORLD owner-call: key? */'
full_chain = <<~CPP
  {
  if (mrb_hash_p(r4) && mrb_obj_ptr(r4)->c == M->hash_class) {
    r4 = mrb_bool_value(mrb_hash_key_p(M, r4, r5));
  } else {
    // a comment is no statement
    if (mrb_likely(bc2cpp_class_is(M, r4, bc2cpp_owner_class_0(M)))) {
      r4 = Tbl_key$3f_impl(M, r4, r5);
    } else {
      { struct RClass* bc2cpp_soc = mrb_class(M, r4);
        if (bc2cpp_soc == bc2cpp_owner_class_1(M)) {
          r4 = Tbl_key$3f_impl(M, r4, "}{");
        } else if (mrb_obj_is_kind_of(M, r4, bc2cpp_owner_class_2(M))) {
          r4 = mrb_nil_value();
        } else {
          #{TAIL}
        } }
    }
  }
  }
CPP
found, out = arms_of.call(full_chain)
check.call('scan: every arm form of the chain, innermost first',
           found == [[%w[Hash Tbl], [[:kind_of, 'bc2cpp_owner_class_2(M)'], [:plain, 'bc2cpp_owner_class_1(M)'],
                                     [:any, 'bc2cpp_owner_class_0(M)'], [:plain, 'Hash']]]])
check.call('scan: the else becomes the nomethod with the call\'s arguments (no caller self)',
           out.include?('r4 = bc2cpp_nomethod_named(M, r4, "key?", 1, r5);') && !out.include?('bc2cpp_owner_call_named'))
statement = full_chain.sub(TAIL, "r4 = r6;\n#{TAIL}")
check.call('scan: a statement in front of the call stops the chain', arms_of.call(statement)[0].dig(0, 1) == [])
writing = full_chain.sub('} else if (mrb_obj_is_kind_of', '} else if ((r4 = r6, false)) {\n  } else if (mrb_obj_is_kind_of')
check.call('scan: a test that writes drops the tests before it and every outer chain',
           arms_of.call(writing)[0].dig(0, 1) == [[:kind_of, 'bc2cpp_owner_class_2(M)']])
conj = full_chain.sub('if (mrb_hash_p(r4) && mrb_obj_ptr(r4)->c == M->hash_class)',
                      'if (M->c == M->root_c && mrb_hash_p(r4) && mrb_obj_ptr(r4)->c == M->hash_class)')
check.call('scan: a conjunction with another test is no arm', !arms_of.call(conj)[0].dig(0, 1).include?([:plain, 'Hash']))
other = full_chain.sub('mrb_class(M, r4);', 'mrb_class(M, r7);')
check.call('scan: a class variable of another register gives no arm',
           !arms_of.call(other)[0].dig(0, 1).include?([:plain, 'bc2cpp_owner_class_1(M)']))
check.call('scan: an arm body is not a chain else',
           arms_of.call("if (bc2cpp_class_is(M, r4, bc2cpp_owner_class_0(M))) {\n  #{TAIL}\n}\n")[0].dig(0, 1) == [])

SOURCE = <<~RUBY
  class Tbl
    def initialize; @h = { 1 => 2 }; end
    def key?(k); @h.key?(k); end
  end
  class Sub < Tbl
  end
  class Box
    def initialize; @v = 3; end
    def visit(x); yield @v + x; end
  end
  class Crate
    def initialize; @w = 4; end
    def visit(x); yield @w * x; end
  end
  class Probe
    def kp(o, x); o.key?(x); end
    def vb(o, x); o.visit(x) { |v| v + 1 }; end
    def sz(o, _x); o.bytesize; end
    def tm(o, _x); s = 0; o.times { |i| s += i }; s; end
  end
RUBY
OWNERS = %w[Tbl Sub Box Crate Probe].freeze
SUBCLASSED = SOURCE.sub("class Probe\n", "class MyHash < Hash\nend\nclass Probe\n")
SINGLETON = SOURCE.sub("class Probe\n", "class Probe\n  def boxy; b = Box.new; def b.extra; 1; end; b; end\n")

body = ->(code, name) { code[/^mrb_value Probe_#{name}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
closed = ->(text) { text.include?('ARMS_COMPLETE_ELSE') && text.include?('bc2cpp_nomethod(M, ') && !text.include?('bc2cpp_owner_call') }

HARNESS = <<~'CPP'
  #include <mruby/error.h>
  #include <string>
  struct Call { mrb_value obj; mrb_sym mid; mrb_value argv[2]; };
  static mrb_value call_body(mrb_state* M, void* ud) {
    Call* c = (Call*)ud;
    return mrb_funcall_argv(M, c->obj, c->mid, 2, c->argv);
  }
  static void row(mrb_state* M, const char* label, const char* meth, mrb_value recv) {
    mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
    Call c = { probe, mrb_intern_cstr(M, meth), { recv, mrb_int_value(M, 1) } };
    mrb_bool raised = FALSE;
    mrb_value v = mrb_protect_error(M, call_body, &c, &raised);
    std::string out;
    if (raised) {
      mrb_value msg = mrb_funcall(M, v, "message", 0);
      out = std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
    } else {
      mrb_value s = mrb_inspect(M, v);
      out = std::string(RSTRING_PTR(s), RSTRING_LEN(s));
    }
    std::printf("%s => %s\n", label, out.c_str());
  }
  static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
CPP
SCENARIO = <<~'CPP'
  static int scenario(mrb_state* M) {
    row(M, "hash.key?", "kp", eval(M, "{ 1 => :a }"));
    row(M, "tbl.key?", "kp", eval(M, "Tbl.new"));
    row(M, "sub.key?", "kp", eval(M, "Sub.new"));
    row(M, "singleton tbl.key?", "kp", eval(M, "t = Tbl.new; def t.extra; end; t"));
    row(M, "nil.key?", "kp", mrb_nil_value());
    row(M, "int.key?", "kp", mrb_int_value(M, 1));
    row(M, "str.key?", "kp", eval(M, "'s'"));
    row(M, "box.visit", "vb", eval(M, "Box.new"));
    row(M, "crate.visit", "vb", eval(M, "Crate.new"));
    row(M, "nil.visit", "vb", mrb_nil_value());
    row(M, "str.bytesize", "sz", eval(M, "'abc'"));
    row(M, "int.bytesize", "sz", mrb_int_value(M, 5));
    row(M, "int.times", "tm", mrb_int_value(M, 4));
    row(M, "nil.times", "tm", mrb_nil_value());
    EXTRA
    return 0;
  }
CPP

build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : runtime.full_or_build
parity = lambda do |label, dir, err, extra|
  next puts("  SKIP run #{label}: no full-core mruby build") unless build

  harness = HARNESS + SCENARIO.sub('EXTRA', extra)
  built, output = runtime.run(dir, err, OWNERS + (label == 'subclassed' ? %w[MyHash] : []), harness, build: build, full: true)
  sections = runtime.sections(output)
  compiled = sections['compiled'].to_a
  check.call("#{label}: built and ran", built)
  check.call("#{label}: runtime parity (every row)", !compiled.empty? && compiled == sections['interpreted'].to_a)
  warn output unless compiled == sections['interpreted'].to_a
  compiled
end

Dir.mktmpdir('arms-complete-else') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'arms_complete_else.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  check.call('key?: the Hash, Tbl and Sub arms close the else', closed.call(body.call(code, 'kp')) &&
             body.call(code, 'kp').include?('Tbl_key$3f_impl(M, '))
  check.call('bytesize: the String arm closes the else', closed.call(body.call(code, 'sz')))
  check.call('visit: the block call\'s Box and Crate arms close the else', closed.call(body.call(code, 'vb')) &&
             body.call(code, 'vb').include?('Box_visit_impl(M, '))
  check.call('times: a fixnum arm misses a bignum, the owner call stays',
             body.call(code, 'tm').include?('bc2cpp_owner_call(M, ') && !body.call(code, 'tm').include?('ARMS_COMPLETE_ELSE'))
  rows = parity.call('closed', dir, err, '')
  if rows
    check.call('a Sub and a singleton Tbl still answer key?', rows.include?('sub.key? => true') &&
               rows.include?('singleton tbl.key? => true'))
    check.call('an unarmed receiver raises NoMethodError', rows.any? { |l| l.start_with?('nil.key?') && l.include?('NoMethodError') })
  end
end

Dir.mktmpdir('arms-complete-else-subclassed') do |dir|
  code, err = runtime.generate(SUBCLASSED, dir, only_owners: OWNERS + %w[MyHash])
  check.call('subclassed: Hash has a subclass, key? keeps its owner call',
             body.call(code, 'kp').include?('bc2cpp_owner_call(M, ') && !body.call(code, 'kp').include?('ARMS_COMPLETE_ELSE'))
  rows = parity.call('subclassed', dir, err, 'row(M, "myhash.key?", "kp", eval(M, "h = MyHash.new; h[1] = 2; h"));')
  check.call('subclassed: a MyHash answers key?', rows.include?('myhash.key? => true')) if rows
end

Dir.mktmpdir('arms-complete-else-singleton') do |dir|
  code, err = runtime.generate(SINGLETON, dir, only_owners: OWNERS)
  check.call('singleton: a Box may have a singleton class, visit keeps its dispatch',
             !body.call(code, 'vb').include?('ARMS_COMPLETE_ELSE'))
  extra = 'row(M, "singleton box.visit", "vb", mrb_funcall(M, mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr), "boxy", 0));'
  rows = parity.call('singleton', dir, err, extra)
  check.call('singleton: a singleton Box answers visit', rows.include?('singleton box.visit => 5')) if rows
end

Dir.mktmpdir('arms-complete-else-off') do |dir|
  ENV['BC2CPP_ARMS_COMPLETE_ELSE'] = '0'
  code, = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  ENV.delete('BC2CPP_ARMS_COMPLETE_ELSE')
  check.call('switch off: BC2CPP_ARMS_COMPLETE_ELSE=0 keeps every owner call', !code.include?('ARMS_COMPLETE_ELSE') &&
             body.call(code, 'kp').include?('bc2cpp_owner_call(M, '))
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp arms complete else check: PASS'
