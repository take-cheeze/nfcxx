#!/usr/bin/env ruby
# frozen_string_literal: true

# Check LEAF_OWNER_ELSE (tools/bc2cpp/codegen_leaf_owner_else.rb) on a closed-world fixture:
#   0. the rewrite on the engine's two guarded shapes (MONO_EMBED_GUARD, an RGSS native arm);
#   1. generated code: `o.ping(x)`, whose only definer Leaf embeds an ivar (MONO_EMBED_GUARD) and has no subclass,
#      keeps its exact-class direct arm and its
#      else becomes the proven nomethod (no owner call left); `o.pong(x)`, defined by Base which Kid inherits, keeps
#      the owner call as the else;
#   2. run on a full-core mruby, compiled against interpreted: Leaf, a Leaf with a singleton class, Kid, Base, nil
#      and an Integer give the same value or error.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/leaf_owner_else_check.rb
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
  class Leaf
    def initialize; @v = 1; end
    def ping(x); [:leaf, @v, x]; end
  end
  class Base
    def initialize; @v = 2; end
    def pong(x); [:base, @v, x]; end
  end
  class Kid < Base
  end
  class Probe
    def lp(o, x); o.ping(x); end
    def bp(o, x); o.pong(x); end
  end
RUBY
OWNERS = %w[Leaf Base Kid Probe].freeze

body = ->(code, name) { code[/^mrb_value Probe_#{name}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }

# 0. the rewrite itself, on the two engine shapes (MONO_EMBED_GUARD with mrb_likely, an RGSS native arm): only a guarded
#    else of one owner the guard names, with no block, becomes the nomethod.
require_relative '../../tools/bc2cpp/nomethod_reviewed'
class CodeGen; def self.prepend(*); end; end unless defined?(CodeGen)
require_relative '../../tools/bc2cpp/codegen_leaf_owner_else'
SHAPES = <<~CPP
  if (mrb_likely(bc2cpp_class_is(M, r4, bc2cpp_owner_class_0(M)))) {
    r4 = Leaf_ping_impl(M, r4, r5);
  } else {
    r4 = bc2cpp_owner_call_named(M, r4, "ping", 2, BC2CPP_OWNERS("Leaf"), mrb_nil_value(), 1, r5, self); /* CLOSED_WORLD owner-call: ping */
  }
  if (bc2cpp_class_is(M, r8, rgss::native_bitmap_class())) {
    r8 = rgss::bitmap_blt_direct(M, r8,
        r9, r10, r11, r12, mrb_fixnum_value(255), FALSE);
  } else {
    r8 = bc2cpp_owner_call_named(M, r8, "blt", 2, BC2CPP_OWNERS("RGSS::Bitmap"), mrb_nil_value(), 4, r9, r10, r11, r12, self); /* CLOSED_WORLD owner-call: blt */
  }
  if (bc2cpp_class_is(M, r6, bc2cpp_owner_class_1(M))) {
    r6 = Base_pong_impl(M, r6, r7);
  } else {
    r6 = bc2cpp_owner_call_named(M, r6, "pong", 2, BC2CPP_OWNERS("Base", "Kid"), mrb_nil_value(), 1, r7, self); /* CLOSED_WORLD owner-call: pong */
  }
  if (bc2cpp_class_is(M, r2, bc2cpp_owner_class_0(M))) {
    r2 = Leaf_each_impl(M, r2, blk);
  } else {
    r2 = bc2cpp_owner_call_named(M, r2, "each", 2, BC2CPP_OWNERS("Leaf"), bc2cpp_blk_stack_1.proc(), 0, self); /* CLOSED_WORLD owner-call: each */
  }
CPP
asked = []
out = LeafOwnerElse.rewrite(SHAPES) { |cls, owner| asked << [cls, owner]; true }
check.call('rewrite: the guarded single-owner elses become the nomethod (args without the caller self)',
           out.include?('r4 = bc2cpp_nomethod_named(M, r4, "ping", 1, r5);') &&
           out.include?('r8 = bc2cpp_nomethod_named(M, r8, "blt", 4, r9, r10, r11, r12);'))
check.call('rewrite: the guard asks about its own class expression and owner',
           asked == [['bc2cpp_owner_class_0(M)', 'Leaf'], ['rgss::native_bitmap_class()', 'RGSS::Bitmap']])
check.call('rewrite: a two-owner set and a block call keep their owner calls',
           out.include?('"pong", 2, BC2CPP_OWNERS("Base", "Kid")') && out.include?('"each", 2, BC2CPP_OWNERS("Leaf"), bc2cpp_blk'))
check.call('rewrite: a leaf the closed world does not prove keeps the owner call',
           LeafOwnerElse.rewrite(SHAPES) { false } == SHAPES)

Dir.mktmpdir('leaf-owner-else') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'leaf_owner_else.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  lp = body.call(code, 'lp')
  bp = body.call(code, 'bp')
  check.call('ping: the exact-class arm calls Leaf_ping_impl', lp.include?('Leaf_ping_impl(M, '))
  check.call('ping: the else is the proven nomethod, no owner call', lp.include?('bc2cpp_nomethod(M, ') &&
             !lp.include?('bc2cpp_owner_call'))
  check.call('pong: Base has a subclass, the owner call stays', bp.include?('bc2cpp_owner_call(M, ') &&
             !bp.include?('LEAF_OWNER_ELSE'))

  unless ENV['CC_GENERATED_ONLY'] == '1'
    harness = <<~'CPP'
      #include <mruby/error.h>
      #include <string>
      struct Call { mrb_value obj; mrb_sym mid; mrb_value argv[2]; };
      static mrb_value call_body(mrb_state* M, void* ud) {
        Call* c = (Call*)ud;
        return mrb_funcall_argv(M, c->obj, c->mid, 2, c->argv);
      }
      static void row(mrb_state* M, const char* label, const char* meth, mrb_value recv) {
        mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
        Call c = { probe, mrb_intern_cstr(M, meth), { recv, mrb_int_value(M, 2) } };
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
        row(M, "leaf.ping", "lp", eval(M, "Leaf.new"));
        row(M, "singleton leaf.ping", "lp", eval(M, "l = Leaf.new; def l.extra; end; l"));
        row(M, "kid.ping", "lp", eval(M, "Kid.new"));
        row(M, "nil.ping", "lp", mrb_nil_value());
        row(M, "int.ping", "lp", mrb_int_value(M, 1));
        row(M, "kid.pong", "bp", eval(M, "Kid.new"));
        row(M, "base.pong", "bp", eval(M, "Base.new"));
        row(M, "nil.pong", "bp", mrb_nil_value());
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
      check.call('a singleton Leaf still answers ping', compiled.any? { |l| l.start_with?('singleton leaf.ping') && l.include?(':leaf') })
      check.call('a non-Leaf receiver raises NoMethodError', compiled.any? { |l| l.start_with?('kid.ping') && l.include?('NoMethodError') })
      check.call('the inherited pong still runs', compiled.any? { |l| l.start_with?('kid.pong') && l.include?(':base') })
      warn output unless failures.empty?
    else
      puts '  SKIP run: no full-core mruby build'
    end
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp leaf owner else check: PASS'
