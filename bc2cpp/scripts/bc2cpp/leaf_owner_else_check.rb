#!/usr/bin/env ruby
# frozen_string_literal: true

# Check LEAF_OWNER_ELSE (tools/bc2cpp/codegen_leaf_owner_else.rb) on a closed-world fixture:
#   0. the rewrite on the engine's two guarded shapes (MONO_EMBED_GUARD, an RGSS native arm);
#   1. generated code: `o.ping(x)`, whose only definer Leaf embeds an ivar (MONO_EMBED_GUARD) and has no subclass,
#      keeps its exact-class direct arm and its
#      else becomes the proven nomethod (no owner call left); `o.pong(x)`, defined by Base which Kid inherits, keeps
#      the owner call as the else;
#   2. GUARD_HOIST (codegen_guard_hoist.rb): `twice` tests its receiver once, the second send's guard is cut by the
#      first one's raising else; `moved` (the local rewritten) and `looped` (rewritten inside the loop) keep both
#      guards; in a world that also gives an instance a singleton method nothing is cut; BC2CPP_GUARD_HOIST=0
#      keeps both tests of `twice`;
#   3. run on a full-core mruby, compiled against interpreted: Leaf, a Leaf with a singleton class, Kid, Base, nil
#      and an Integer give the same value or error, and so do the GUARD_HOIST methods (a Kid swapped in after the
#      first guard raises NoMethodError).
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/leaf_owner_else_check.rb
# The run needs a full-core libmruby built from this tree's patched 3rd/mruby (BC2CPP_MRUBY_FULL, or one built here).

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] ||= ''
# ARMS_COMPLETE_ELSE would also close pong's else (Base and Kid both get arms); off, the owner call shows what
# LEAF_OWNER_ELSE leaves.
ENV['BC2CPP_ARMS_COMPLETE_ELSE'] = '0'
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~RUBY
  class Leaf
    def initialize; @v = 1; end
    def ping(x); [:leaf, @v, x]; end
    def pang(x); [:pang, @v, x]; end
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
    def twice(o, x); [o.ping(x), o.pang(x)]; end
    def moved(o, p, x); a = o.ping(x); o = p; [a, o.pang(x)]; end
    def looped(o, p, x)
      a = o.ping(x)
      r = nil
      i = 0
      while i < 2
        r = o.pang(x)
        o = p
        i += 1
      end
      [a, r]
    end
  end
RUBY
OWNERS = %w[Leaf Base Kid Probe].freeze
# The same world with an instance singleton maker (a singleton method of another name, so pang keeps its guards).
SINGLE_SOURCE = <<~RUBY
  #{SOURCE}
  class Probe
    def single(o, x)
      a = o.ping(x)
      o.define_singleton_method(:zap) { |y| [:sing, y] }
      [a, o.pang(x)]
    end
  end
RUBY

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
  tests = ->(name) { body.call(code, name).scan('bc2cpp_class_is(').size }
  hoisted = ->(name) { body.call(code, name).include?('GUARD_HOIST') }
  check.call('hoist: twice tests its receiver once, pang keeps its direct call',
             tests.call('twice') == 1 && hoisted.call('twice') && body.call(code, 'twice').include?('Leaf_pang_impl(M, '))
  check.call('hoist: a rewritten local keeps its second guard', tests.call('moved') == 2 && !hoisted.call('moved'))
  check.call('hoist: a local the loop rewrites keeps its guard in the loop',
             tests.call('looped') == 2 && !hoisted.call('looped'))
  single_dir = File.join(dir, 'hoist-single')
  FileUtils.mkdir_p(single_dir)
  single_code, = runtime.generate(SINGLE_SOURCE, single_dir, only_owners: OWNERS)
  check.call('hoist: a world with an instance singleton maker cuts no guard',
             !single_code.include?('GUARD_HOIST') && body.call(single_code, 'twice').scan('bc2cpp_class_is(').size == 2)
  off_dir = File.join(dir, 'hoist-off')
  FileUtils.mkdir_p(off_dir)
  saved = ENV['BC2CPP_GUARD_HOIST']
  ENV['BC2CPP_GUARD_HOIST'] = '0'
  off_code, = runtime.generate(SOURCE, off_dir, only_owners: OWNERS)
  saved ? ENV['BC2CPP_GUARD_HOIST'] = saved : ENV.delete('BC2CPP_GUARD_HOIST')
  check.call('hoist: BC2CPP_GUARD_HOIST=0 keeps both tests of twice',
             body.call(off_code, 'twice').scan('bc2cpp_class_is(').size == 2 && !body.call(off_code, 'twice').include?('GUARD_HOIST'))

  unless ENV['CC_GENERATED_ONLY'] == '1'
    harness = <<~'CPP'
      #include <mruby/error.h>
      #include <string>
      struct Call { mrb_value obj; mrb_sym mid; mrb_int argc; mrb_value argv[3]; };
      static mrb_value call_body(mrb_state* M, void* ud) {
        Call* c = (Call*)ud;
        return mrb_funcall_argv(M, c->obj, c->mid, c->argc, c->argv);
      }
      static void row(mrb_state* M, const char* label, const char* meth, mrb_value recv,
                      mrb_value other = mrb_undef_value()) {
        mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
        Call c = mrb_undef_p(other) ? Call{ probe, mrb_intern_cstr(M, meth), 2, { recv, mrb_int_value(M, 2) } }
                                    : Call{ probe, mrb_intern_cstr(M, meth), 3, { recv, other, mrb_int_value(M, 2) } };
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
        row(M, "leaf.twice", "twice", eval(M, "Leaf.new"));
        row(M, "kid.twice", "twice", eval(M, "Kid.new"));
        row(M, "leaf.moved leaf", "moved", eval(M, "Leaf.new"), eval(M, "Leaf.new"));
        row(M, "leaf.moved kid", "moved", eval(M, "Leaf.new"), eval(M, "Kid.new"));
        row(M, "leaf.looped leaf", "looped", eval(M, "Leaf.new"), eval(M, "Leaf.new"));
        row(M, "leaf.looped kid", "looped", eval(M, "Leaf.new"), eval(M, "Kid.new"));
        row(M, "singleton leaf.twice", "twice", eval(M, "l = Leaf.new; def l.extra; end; l"));
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
      check.call('hoist: a Kid swapped in after the guard raises NoMethodError',
                 compiled.any? { |l| l.start_with?('leaf.moved kid') && l.include?('NoMethodError') } &&
                 compiled.any? { |l| l.start_with?('leaf.looped kid') && l.include?('NoMethodError') })
      check.call('hoist: a Leaf with a singleton class passes the one guard of twice',
                 compiled.any? { |l| l.start_with?('singleton leaf.twice') && l.include?(':pang') })
      warn output unless failures.empty?
    else
      puts '  SKIP run: no full-core mruby build'
    end
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp leaf owner else check: PASS'
