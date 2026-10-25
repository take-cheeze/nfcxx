#!/usr/bin/env ruby
# frozen_string_literal: true

# Check STATIC_OWNER_ARMS on a closed-world fixture: an owner call (OUTSIDE_OWNER_CALL / NAME_OWNER_SET) whose owner
# set holds compiled Ruby definitions gets exact-class arms in front of it, each a direct call of the definition the
# receiver's class reaches first, and the owner call stays as the else for every other receiver.
#
#   1. generated code: `o.push(x)` (Bag#push next to Array#push) gets arms for Bag and for SubBag, which inherits
#      Bag#push, but none for OddBag's own push (two Ruby definitions take the POLY chain, not this) and none in
#      front of a private definition (`o.first`) or an arity that does not fit (`o.push` with no argument); the arm
#      tests mrb_class (a singleton class never matches) and the owner call is still the else;
#      BLOCK_OWNER_ARMS: `o.each { ... }` (Bag#each yields) gets an arm passing the call's own block -- the heap RProc,
#      or the block parameter for a block that breaks or returns -- and a block given to Bag#tag, which takes none,
#      gets no block arm;
#   2. run on a full-core mruby, compiled against interpreted: Bag, SubBag, a subclass made at run time (no arm, owner
#      call), a Bag with a singleton class (no arm, owner call), Array (native owner), nil (NoMethodError), the
#      private Bag#first (NoMethodError) and Bag#push with no argument (ArgumentError) give the same value or error;
#      so do the block calls on Bag, SubBag (the block arm), a singleton SubBag and Array, a `break` and a non-local
#      `return` through the arm, and the ignored block.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/static_owner_dispatch_check.rb
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
abort 'SKIP: set MRBC' unless ENV['MRBC']

SOURCE = <<~RUBY
  class Bag
    def initialize; @items = [1, 2]; end
    def push(x); [:bag_push, x]; end
    def each; yield 1; yield 2; :bag_each; end
    def tag(x); [:bag_tag, x]; end

    private

    def first; :bag_first; end
  end
  class SubBag < Bag
  end
  class Probe
    def ps(o, x); o.push(x); end
    def ps0(o); o.push; end
    def fs(o); o.first; end
    def es(o); acc = []; o.each { |x| acc << x }; acc; end
    def eb(o); o.each { |x| break x * 10 if x == 2 }; end
    def er(o); o.each { |x| return :early if x == 2 }; :late; end
    def sp(o, a); o.push(*a); end
    def tg(o); o.tag(1) { :ignored }; end
  end
RUBY
OWNERS = %w[Bag SubBag Probe].freeze

body = ->(code, name) { code[/^mrb_value Probe_#{name}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }

Dir.mktmpdir('static-owner-dispatch') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'static_owner_dispatch.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  ps = body.call(code, 'ps')
  check.call('push: STATIC_OWNER_ARMS marker', ps.include?('STATIC_OWNER_ARMS :push'))
  check.call('push: a direct arm calls Bag_push_impl', ps.scan('Bag_push_impl(M, ').size >= 2)
  check.call('push: arms test the exact class (mrb_class, so a singleton class never matches)',
             ps.match?(/bc2cpp_soc = mrb_class\(M, r\d+\);/) && ps.match?(/bc2cpp_soc == bc2cpp_owner_class_\d+\(M\)/))
  check.call('push: the owner call stays as the else', ps.include?('bc2cpp_owner_call(M, ') &&
             ps.index('Bag_push_impl').to_i < ps.index('bc2cpp_owner_call(').to_i)
  check.call('push: two arms (Bag, SubBag inheriting Bag#push)', ps.scan(/bc2cpp_soc == bc2cpp_owner_class_\d+\(M\)\) \{/).size == 2)
  ps0 = body.call(code, 'ps0')
  check.call('push with no argument: no arm (arity does not fit), owner call only',
             !ps0.include?('STATIC_OWNER_ARMS') && ps0.include?('bc2cpp_owner_call(M, '))
  fs = body.call(code, 'fs')
  check.call('private first: no arm, owner call only', !fs.include?('STATIC_OWNER_ARMS') && fs.include?('bc2cpp_owner_call(M, '))
  check.call('no by-name send left', ![ps, ps0, fs].any? { |b| b.include?('bc2cpp_send(') })
  es = body.call(code, 'es')
  eb = body.call(code, 'eb')
  check.call('block each: STATIC_OWNER_ARMS marker', es.include?('STATIC_OWNER_ARMS :each') && eb.include?('STATIC_OWNER_ARMS :each'))
  check.call('block each: the arm passes the call\'s own block to Bag_each_impl',
             es.match?(/Bag_each_impl\(M, r\d+, bc2cpp_blk_heap_\d+\(\)\);/) &&
             eb.match?(/Bag_each_impl\(M, r\d+, mrb_obj_value\(bc2cpp_blk_proc_\d+\)\);/))
  check.call('block each: the block owner call stays as the else',
             es.match?(/bc2cpp_owner_call\(M, r\d+, \d+, 0, BC2CPP_OWNERS\([^)]*\), bc2cpp_blk_heap_\d+\(\), 0\)/))
  tg = body.call(code, 'tg')
  check.call('a block to a definition that takes none: no block arm',
             !tg.include?('STATIC_OWNER_ARMS') && !tg.match?(/Bag_tag_impl\(M, [^;]*blk/))

  unless ENV['CC_GENERATED_ONLY'] == '1'
    harness = <<~'CPP'
      #include <mruby/error.h>
      #include <string>
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
        row(M, "bag.push", "ps", eval(M, "Bag.new"), 1, two);
        row(M, "subbag.push (inherited arm)", "ps", eval(M, "SubBag.new"), 1, two);
        row(M, "runtime subclass.push (no arm)", "ps", eval(M, "class LateBag < Bag; end; LateBag.new"), 1, two);
        row(M, "singleton bag.push (no arm)", "ps", eval(M, "b = Bag.new; b.singleton_class; b"), 1, two);
        row(M, "array.push", "ps", eval(M, "[1]"), 1, two);
        row(M, "nil.push", "ps", mrb_nil_value(), 1, two);
        row(M, "bag.push no argument", "ps0", eval(M, "Bag.new"), 0, mrb_nil_value());
        row(M, "bag.first (private)", "fs", eval(M, "Bag.new"), 0, mrb_nil_value());
        row(M, "array.first", "fs", eval(M, "[7]"), 0, mrb_nil_value());
        row(M, "bag.each block", "es", eval(M, "Bag.new"), 0, mrb_nil_value());
        row(M, "subbag.each block (block arm)", "es", eval(M, "SubBag.new"), 0, mrb_nil_value());
        row(M, "singleton subbag.each block (no arm)", "es", eval(M, "b = SubBag.new; b.singleton_class; b"), 0, mrb_nil_value());
        row(M, "array.each block", "es", eval(M, "[5, 6]"), 0, mrb_nil_value());
        row(M, "subbag.each break", "eb", eval(M, "SubBag.new"), 0, mrb_nil_value());
        row(M, "subbag.each return", "er", eval(M, "SubBag.new"), 0, mrb_nil_value());
        row(M, "array.each return", "er", eval(M, "[1, 2]"), 0, mrb_nil_value());
        row(M, "subbag.tag block ignored", "tg", eval(M, "SubBag.new"), 0, mrb_nil_value());
        return 0;
      }
    CPP
    build = runtime.full_or_build
    if build
      built, output = runtime.run(dir, err, OWNERS, harness, build: build, full: true)
      sections = runtime.sections(output)
      compiled = sections['compiled'].to_a
      interpreted = sections['interpreted'].to_a
      check.call('built and ran', built)
      check.call('runtime parity (every row)', !compiled.empty? && compiled == interpreted)
      check.call('the inherited arm answers Bag#push', compiled.any? { |l| l.start_with?('subbag.push') && l.include?(':bag_push') })
      check.call('a private definition still raises', compiled.any? { |l| l.start_with?('bag.first') && l.include?('NoMethodError') })
      check.call('the block arm runs the block (SubBag#each)', compiled.any? { |l| l.start_with?('subbag.each block (block arm)') && l.include?('[1, 2]') })
      check.call('break through the block arm', compiled.any? { |l| l.start_with?('subbag.each break') && l.end_with?('=> 20') })
      check.call('non-local return through the block arm', compiled.any? { |l| l.start_with?('subbag.each return') && l.end_with?('=> :early') })
      check.call('a wrong argument count still raises', compiled.any? { |l| l.start_with?('bag.push no argument') && l.include?('ArgumentError') })
      warn output unless failures.empty?
    else
      puts '  SKIP run: no full-core mruby build'
    end
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp static owner dispatch check: PASS'
