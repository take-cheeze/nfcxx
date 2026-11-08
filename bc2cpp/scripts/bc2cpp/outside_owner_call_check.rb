#!/usr/bin/env ruby
# frozen_string_literal: true

# Check OUTSIDE_OWNER_CALL on a closed-world fixture: a guard chain whose else stayed a by-name send
# only because a core or native class also defines the name (`CLOSED_WORLD kept: core_or_native`) ends in a call
# checked against every outside owner of the name, and answers as the interpreter does.
#
#   1. generated code: `o.delete(x)`, `o.name`, `o.at`, `o.print(x)` next to a Ruby class that defines each name end
#      in bc2cpp_owner_call with the owners the native and outside Ruby scans name (Array, Hash, String for `delete`),
#      at the OP_SEND check level of an explicit receiver, with no by-name send left;
#   2. withdrawals, each keeping `kept: core_or_native`: an outside native registration of the name on a class the
#      owner map cannot name, an outside Ruby `def obj.delete` on an object it cannot name, and the owner map switched
#      off (BC2CPP_NATIVE_OWNER_MAP=0);
#   3. run on a full-core mruby, compiled against interpreted: the Ruby arm, the core owners (Array#delete, Hash#delete
#      in mrblib, String#delete, Symbol#name, NameError#name, Array#at), nil and an Integer (NoMethodError), a raw C
#      function called with the wrong argument count (OP_SEND's aspec check: ArgumentError), a private Kernel method
#      on an explicit receiver (NoMethodError), and StringIO#print (outside Ruby) give the same value or error class
#      and message; a definition installed behind the closed world's back (a C `Integer#delete` the scans never saw)
#      raises the owner violation in the compiled run only.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/outside_owner_call_check.rb
# The run needs a full-core libmruby built from this tree's patched 3rd/mruby (BC2CPP_MRUBY_FULL, or one built here).

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/bc2cpp'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']

puts '-- owner-call formatting (host)'
formatting = CodeGen.allocate
owner_names = %w[Array Game::Bag Kernel.singleton].map(&:freeze).freeze
formatting.define_singleton_method(:name_owner_set) { |_name| owner_names }
[[], ['r2'], (1..CodeGen::FUNCALL_ARGC_MAX).map { |i| "r#{i}" }].each do |argv|
  args = argv.map { |arg| ", #{arg}" }.join
  list = owner_names.map { |owner| "\"#{owner}\"" }.join(', ')
  expected = "r1 = bc2cpp_owner_call_named(M, r0, \"push\", 0, BC2CPP_OWNERS(#{list}), mrb_nil_value(), " \
             "#{argv.size}#{args}); /* CLOSED_WORLD owner-call: push */"
  check.call("#{argv.size} arguments: owner-call output is byte-identical", formatting.outside_owner_call_line(1, 'r0', 'push', argv, owner_names) == expected)
  block_expected = expected.sub('mrb_nil_value()', 'block')
  check.call("#{argv.size} arguments: block owner-call output is byte-identical", formatting.block_owner_call_line('r1', 'r0', 'push', argv, 'block') == block_expected)
end
check.call('block calls exceeding the funcall argument limit still refuse',
           formatting.block_owner_call_line('r1', 'r0', 'push', Array.new(CodeGen::FUNCALL_ARGC_MAX + 1, 'r2'), 'block').nil?)
list = owner_names.map { |owner| "\"#{owner}\"" }.join(', ')
check.call('splat calls retain their argument-array expressions',
           formatting.block_owner_call_argv_line('r1', 'r0', 'push', 'argc', 'argv', 'block') ==
             "r1 = bc2cpp_owner_call_argv_named(M, r0, \"push\", 0, BC2CPP_OWNERS(#{list}), block, argc, argv); /* CLOSED_WORLD owner-call: push */")
check.call('numeric helper formatting retains its output',
           formatting.helper_owner_calls('mrb_funcall(M, recv, "push", 1, arg)') ==
             "bc2cpp_owner_call_named(M, recv, \"push\", 0, BC2CPP_OWNERS(#{list}), mrb_nil_value(), 1, arg) /* CLOSED_WORLD owner-call: push */")
cached = formatting.owner_call_owner_list(owner_names)
check.call('deeply frozen lists reuse their frozen formatting', cached.frozen? && formatting.owner_call_owner_list(owner_names).equal?(cached))
mutable_name = +'Array'
mutable = [mutable_name].freeze
formatting.owner_call_owner_list(mutable)
mutable_name.replace('Hash')
check.call('a shallow-frozen list never caches mutable names', formatting.owner_call_owner_list(mutable) == '"Hash"')
mutable_list = ['Array']
formatting.owner_call_owner_list(mutable_list)
mutable_list << 'Hash'
check.call('mutable lists are rendered again after mutation', formatting.owner_call_owner_list(mutable_list) == '"Array", "Hash"')
snapshot_name = +'Array'
snapshot = formatting.freeze_owner_call_owners([snapshot_name])
snapshot_name.replace('Hash')
check.call('owner decisions retain an immutable name snapshot', snapshot.frozen? && snapshot.first.frozen? && snapshot == ['Array'])
other = CodeGen.allocate
check.call('formatting caches belong to one generator', !other.owner_call_owner_list(owner_names).equal?(cached))
(OutsideOwnerCall::OWNER_LIST_CACHE_MAX + 1).times do |i|
  formatting.owner_call_owner_list(["Owner#{i}".freeze].freeze)
end
check.call('formatting cache remains bounded', formatting.instance_variable_get(:@owner_call_owner_lists).size == OutsideOwnerCall::OWNER_LIST_CACHE_MAX)

puts '-- checked-send rewrite (host)'
# CheckedSend#replace_call_head must rewrite exactly what gsub(/\bFROM/) did.
heads = ['mrb_funcall(M, r1, "push",', 'bc2cpp_owner_call_named(M, self, "fé", 0,']
pieces = heads + heads.map { |head| "_#{head}" } + heads.map { |head| "é#{head}" } +
         ['mrb_funcall(M, r2, "push",', 'bc2cpp_owner_call_named(M, self, "fé", 1,', ' ', ';', '9', 'é']
random = Random.new(3086)
same = (0...2_000).all? do
  code = Array.new(random.rand(0..6)) { pieces.sample(random: random) }.join
  heads.all? do |head|
    to = head.sub(/\A\w+/, 'X')
    code.gsub(/\b#{Regexp.escape(head)}/) { to } == formatting.send(:replace_call_head, code, head, to)
  end
end
check.call('checked-send rewrite matches the word-bounded regexp', same)
plain = 'r1 = mrb_funcall(M, r2, "push", 0);'
check.call('checked-send rewrite returns unmatched code itself', formatting.send(:replace_call_head, plain, heads.first, 'X').equal?(plain))

SOURCE = <<~RUBY
  class Bag
    def initialize; @items = [1, 2]; end
    def delete(x); @items.delete(x); end
    def name; "bag"; end
    def at; :bag_at; end
    def print(x); x; end
    def push(x); [:bag_push, x]; end
    def empty?; false; end
    def fwd(*a); push(*a); end
  end
  class SplW
    def put(a, b = 0); [:put, a, b]; end
  end
  class SplTee
    def initialize; @w = SplW.new; end
    def go(*a); @w.put(*a); end
  end
  class Probe
    def del(o, x); o.delete(x); end
    def nm(o); o.name; end
    def at(o); o.at; end
    def pr(o, x); o.print(x); end
    def pk(o, f); o.pack(f); end
    def ps(o, x); o.push(x); end
    def em(o); o.empty?; end
    def sp(o, a); o.push(*a); end
    def fw(o, a); o.fwd(*a); end
    def tg(t, a); t.go(*a); end
  end
RUBY
OWNERS = %w[Bag Probe SplW SplTee].freeze

body = ->(code, name) { code[/^mrb_value Probe_#{name}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
owners_of = ->(text) { text[/BC2CPP_OWNERS\(([^)]*)\)/, 1].to_s.scan(/"([^"]+)"/).flatten }

Dir.mktmpdir('outside-owner-call') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'outside_owner_call.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  del = body.call(code, 'del')
  check.call('delete: else is the owner call', del.include?('bc2cpp_owner_call(M, ') && del.include?('CLOSED_WORLD owner-call: delete'))
  check.call('delete: no by-name send left', !del.include?('bc2cpp_send(') && !del.include?('kept: core_or_native'))
  check.call('delete: owners are the core definers', (%w[Array Hash String] - owners_of.call(del)).empty?)
  check.call('delete: explicit receiver checks (level 2)', del.match?(/bc2cpp_owner_call\(M, r\d+, \d+, 2, /))
  check.call('delete: the Ruby arm stays first', del.index('Bag_delete_impl').to_i < del.index('bc2cpp_owner_call').to_i)
  check.call('name: owners include Symbol and NameError', (%w[NameError Symbol] - owners_of.call(body.call(code, 'nm'))).empty?)
  check.call('at: owners include Array', owners_of.call(body.call(code, 'at')).include?('Array'))
  check.call('print: owners include Kernel', owners_of.call(body.call(code, 'pr')).include?('Kernel'))
  pk = body.call(code, 'pk')
  check.call('bare pack (no guard chain): the send is the owner call with Array as its owner',
             pk.include?('OUTSIDE_OWNER_CALL :pack') && pk.include?('bc2cpp_owner_call(M, ') &&
               owners_of.call(pk).include?('Array') && !pk.include?('bc2cpp_send('))
  ps = body.call(code, 'ps')
  check.call('push, two owners (Array and the project Bag): owner call over exactly {Array, Bag}, no by-name send',
             ps.include?('bc2cpp_owner_call(M, ') && owners_of.call(ps) == %w[Array Bag] && !ps.include?('bc2cpp_send('))
  em = body.call(code, 'em')
  check.call('empty?: the registered-expression arms end in the owner call, not a by-name send',
             em.include?('bc2cpp_owner_call(M, ') && (%w[Array Bag Hash String] - owners_of.call(em)).empty? &&
               !em.include?('bc2cpp_send('))
  sp = body.call(code, 'sp')
  check.call('push(*list), a run-time sized Array: the owner call over {Array, Bag} with the Array\'s items, no by-name send',
             sp.include?('bc2cpp_owner_call_argv(M, ') && owners_of.call(sp) == %w[Array Bag] &&
               !sp.include?('bc2cpp_funcall_argv(') && !sp.include?('bc2cpp_send('))
  fwd = code[/^mrb_value Bag_fwd_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
  check.call('push(*a) in a Bag body: the owner call over the Array\'s items, no by-name send',
             fwd.match?(/bc2cpp_owner_call_argv\(M, self, /) && !fwd.include?('bc2cpp_funcall_argv('))
  tee = code[/^mrb_value SplTee_go_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
  check.call('put(*a) on a typed receiver: the compiled arities stay direct arms and any other length is the owner call',
             tee.include?('case 1:') && tee.include?('case 2:') && !tee.include?('bc2cpp_funcall_argv(') &&
               tee.match?(/default:\s*r\d+ = bc2cpp_owner_call_argv\(M, /))
  check.call('helper emitted once', code.scan('static mrb_value bc2cpp_owner_call(').size == 1)
  check.call('closed-world summary keeps no core_or_native', !err.include?('KEPT core_or_native'))

  unless ENV['CC_GENERATED_ONLY'] == '1'
    harness = <<~'CPP'
      #include <mruby/error.h>
      #include <string>
      static mrb_value rogue_delete(mrb_state* M, mrb_value self) { return mrb_str_new_lit(M, "rogue"); }
      struct Call { mrb_value obj; mrb_sym mid; mrb_int argc; mrb_value argv[2]; };
      static mrb_value call_body(mrb_state* M, void* ud) {
        Call* c = (Call*)ud;
        return mrb_funcall_argv(M, c->obj, c->mid, c->argc, c->argv);
      }
      static void row(mrb_state* M, const char* label, const char* meth, mrb_value recv, int argc, mrb_value arg) {
        mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
        Call c = { probe, mrb_intern_cstr(M, meth), argc + 1, { recv, arg } };
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
      static int scenario(mrb_state* M) {
        mrb_value two = mrb_int_value(M, 2);
        row(M, "bag.delete", "del", mrb_obj_new(M, mrb_class_get(M, "Bag"), 0, nullptr), 1, two);
        row(M, "array.delete", "del", eval(M, "[1, 2, 3]"), 1, two);
        row(M, "hash.delete", "del", eval(M, "{2 => :two}"), 1, two);
        row(M, "string.delete", "del", eval(M, "'a2b2'"), 1, mrb_str_new_lit(M, "2"));
        row(M, "nil.delete", "del", mrb_nil_value(), 1, two);
        row(M, "symbol.name", "nm", eval(M, ":sym"), 0, mrb_nil_value());
        row(M, "name_error.name", "nm", eval(M, "NameError.new('m', :missing)"), 0, mrb_nil_value());
        row(M, "object.name", "nm", eval(M, "Object.new"), 0, mrb_nil_value());
        row(M, "array.at (aspec)", "at", eval(M, "[1]"), 0, mrb_nil_value());
        row(M, "object.print (private)", "pr", eval(M, "Object.new"), 1, two);
        row(M, "stringio.print", "pr", eval(M, "StringIO.new"), 1, two);
        row(M, "array.pack", "pk", eval(M, "[65, 66]"), 1, mrb_str_new_lit(M, "C*"));
        row(M, "string.pack", "pk", eval(M, "'ab'"), 1, mrb_str_new_lit(M, "C*"));
        row(M, "nil.pack", "pk", mrb_nil_value(), 1, mrb_str_new_lit(M, "C*"));
        row(M, "array.push", "ps", eval(M, "[1]"), 1, two);
        row(M, "bag.push", "ps", mrb_obj_new(M, mrb_class_get(M, "Bag"), 0, nullptr), 1, two);
        row(M, "nil.push", "ps", mrb_nil_value(), 1, two);
        row(M, "array.push(*)", "sp", eval(M, "[1]"), 1, eval(M, "[2, 3]"));
        row(M, "bag.push(*)", "sp", mrb_obj_new(M, mrb_class_get(M, "Bag"), 0, nullptr), 1, eval(M, "[2]"));
        row(M, "bag.push(*) arity", "sp", mrb_obj_new(M, mrb_class_get(M, "Bag"), 0, nullptr), 1, eval(M, "[2, 3]"));
        row(M, "bag.push(*[])", "sp", mrb_obj_new(M, mrb_class_get(M, "Bag"), 0, nullptr), 1, eval(M, "[]"));
        row(M, "nil.push(*)", "sp", mrb_nil_value(), 1, eval(M, "[2]"));
        row(M, "integer.push(*)", "sp", mrb_int_value(M, 3), 1, eval(M, "[]"));
        row(M, "bag.fwd(*[2])", "fw", mrb_obj_new(M, mrb_class_get(M, "Bag"), 0, nullptr), 1, eval(M, "[2]"));
        row(M, "bag.fwd(*[2, 3])", "fw", mrb_obj_new(M, mrb_class_get(M, "Bag"), 0, nullptr), 1, eval(M, "[2, 3]"));
        row(M, "bag.fwd(*[])", "fw", mrb_obj_new(M, mrb_class_get(M, "Bag"), 0, nullptr), 1, eval(M, "[]"));
        row(M, "tee.go(*[1])", "tg", mrb_obj_new(M, mrb_class_get(M, "SplTee"), 0, nullptr), 1, eval(M, "[1]"));
        row(M, "tee.go(*[1, 2])", "tg", mrb_obj_new(M, mrb_class_get(M, "SplTee"), 0, nullptr), 1, eval(M, "[1, 2]"));
        row(M, "tee.go(*[1, 2, 3])", "tg", mrb_obj_new(M, mrb_class_get(M, "SplTee"), 0, nullptr), 1, eval(M, "[1, 2, 3]"));
        row(M, "tee.go(*[])", "tg", mrb_obj_new(M, mrb_class_get(M, "SplTee"), 0, nullptr), 1, eval(M, "[]"));
        row(M, "array.empty?", "em", eval(M, "[]"), 0, mrb_nil_value());
        row(M, "bag.empty?", "em", mrb_obj_new(M, mrb_class_get(M, "Bag"), 0, nullptr), 0, mrb_nil_value());
        row(M, "array subclass.empty?", "em", eval(M, "class SubArr < Array; end; SubArr.new"), 0, mrb_nil_value());
        row(M, "integer.empty?", "em", mrb_int_value(M, 3), 0, mrb_nil_value());
        mrb_define_method(M, M->integer_class, "delete", rogue_delete, MRB_ARGS_REQ(1));
        row(M, "rogue Integer#delete", "del", mrb_int_value(M, 5), 1, two);
        return 0;
      }
    CPP
    build = runtime.full_or_build
    if build
      built, output = runtime.run(dir, err, OWNERS, harness, build: build, full: true)
      sections = runtime.sections(output)
      compiled = sections['compiled'].to_a
      interpreted = sections['interpreted'].to_a
      rogue = ->(lines) { lines.find { |line| line.start_with?('rogue') }.to_s }
      plain = ->(lines) { lines.reject { |line| line.start_with?('rogue') } }
      check.call('built and ran', built)
      check.call('runtime parity (every non-rogue row)', !compiled.empty? && plain.call(compiled) == plain.call(interpreted))
      check.call('interpreted rogue definition runs', rogue.call(interpreted).include?('"rogue"'))
      check.call('compiled rogue definition is an owner violation',
                 rogue.call(compiled).include?('BC2cppGuardViolation') && rogue.call(compiled).include?('closed-world owner violation'))
      warn output unless failures.empty?
    else
      puts '  SKIP run: no full-core mruby build'
    end
  end
end

# Withdrawals: each world leaves `delete` kept. An outside source joins the closed world as a gem of the build, whose
# src/ and mrblib/ the closed world scans.
withdraw = lambda do |label, files = {}|
  Dir.mktmpdir('outside-owner-call-w') do |dir|
    gem = File.join(dir, 'rogue_gem')
    files.each { |path, text| FileUtils.mkdir_p(File.dirname(File.join(gem, path))) && File.write(File.join(gem, path), text) }
    options = files.empty? ? {} : { build_gems: [['rogue-gem', gem]] }
    code, = runtime.generate(SOURCE, dir, only_owners: OWNERS, **options)
    del = body.call(code, 'del')
    check.call("#{label}: delete keeps its by-name else", del.include?('kept: core_or_native') && !del.include?('bc2cpp_owner_call('))
  end
end
withdraw.call('native owner not nameable', 'src/rogue_owner.c' => <<~C)
  #include <mruby.h>
  static mrb_value rogue(mrb_state* mrb, mrb_value self) { return self; }
  void rogue_install(mrb_state* mrb, struct RClass* target) {
    mrb_define_method(mrb, target, "delete", rogue, MRB_ARGS_REQ(1));
  }
C
withdraw.call('outside Ruby owner not nameable', 'mrblib/rogue_owner.rb' => "HOLDER = Object.new\ndef HOLDER.delete(x) = x\n")
Dir.mktmpdir('outside-owner-call-mm') do |dir|
  code, = runtime.generate("#{SOURCE}\nclass Ghost\n  def method_missing(n, *a) = n\n  def respond_to_missing?(n, p = false) = true\nend\n",
                           dir, only_owners: OWNERS)
  pk = body.call(code, 'pk')
  check.call('a method_missing class makes every owner set unknown: pack keeps its by-name send',
             pk.include?('bc2cpp_send(') && !pk.include?('bc2cpp_owner_call('))
end
begin
  ENV['BC2CPP_NATIVE_OWNER_MAP'] = '0'
  withdraw.call('owner map off')
ensure
  ENV.delete('BC2CPP_NATIVE_OWNER_MAP')
end

# A registration through the state's own name (`M->array_class`, as mruby-rgss spells its capture of the core sort)
# names its class like `mrb->array_class`, so the alias is an owner of the name and the send is the owner call.
ALIAS_SOURCE = <<~RUBY
  class AliasProbe
    def ns(a); a.dup.ns_sorted!; end
  end
RUBY
Dir.mktmpdir('outside-owner-call-alias') do |dir|
  gem = File.join(dir, 'alias_gem')
  FileUtils.mkdir_p(File.join(gem, 'src'))
  File.write(File.join(gem, 'src/alias_install.c'), <<~C)
    #include <mruby.h>
    void alias_install(mrb_state* M) { mrb_define_alias(M, M->array_class, "ns_sorted!", "sort!"); }
  C
  code, err = runtime.generate(ALIAS_SOURCE, dir, only_owners: %w[AliasProbe], build_gems: [['alias-gem', gem]])
  ns = code[/^mrb_value AliasProbe_ns_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
  ns_line = ns.lines.find { |line| line.include?('owner-call: ns_sorted!') }.to_s
  check.call('M->array_class alias: the send is the owner call over {Array}, no by-name send',
             ns_line.include?('bc2cpp_owner_call(M, ') && owners_of.call(ns_line) == %w[Array] && !ns.include?('bc2cpp_send('))
  unless ENV['CC_GENERATED_ONLY'] == '1'
    harness = <<~'CPP'
      static int scenario(mrb_state* M) {
        mrb_define_alias(M, M->array_class, "ns_sorted!", "sort!");
        mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "AliasProbe"), 0, nullptr);
        mrb_value arg = mrb_load_string(M, "[3, 1, 2]");
        mrb_value s = mrb_inspect(M, mrb_funcall(M, probe, "ns", 1, arg));
        std::printf("alias sort => %.*s\n", (int)RSTRING_LEN(s), RSTRING_PTR(s));
        return 0;
      }
    CPP
    build = runtime.full_or_build
    if build
      built, output = runtime.run(dir, err, %w[AliasProbe], harness, build: build, full: true)
      sections = runtime.sections(output)
      compiled = sections['compiled'].to_a
      interpreted = sections['interpreted'].to_a
      check.call('M->array_class alias: built and ran', built && interpreted.include?('alias sort => [1, 2, 3]'))
      check.call('M->array_class alias: compiled matches interpreted', !compiled.empty? && compiled == interpreted)
    else
      puts '  SKIP run: no full-core mruby build'
    end
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp outside owner call check: PASS'
