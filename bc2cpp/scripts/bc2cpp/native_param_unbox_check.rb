#!/usr/bin/env ruby
# frozen_string_literal: true

# Check NATIVE_PARAM_UNBOX (docs/adr/0372): a native direct arm converts its :int/:float arguments itself with the
# conversion mrb_get_args performs (mrb_as_int / mrb_as_float), in argument order, instead of testing for an Integer
# and dispatching by name otherwise.
#
# 1. The audit (no tools needed): mruby's "i"/"f"/"b" arms are still what the code generator spells (digest-pinned), and
#    every NativeDirect entry with such an argument is bound by `decls; mrb_get_args(M, fmt, &vars); return entry(M, self, vars)`.
# 2. Generated code (needs MRBC): no tag test, no by-name else on the arm, the conversions are statements in order, a
#    Bitmap.new keeps one tag test on its first argument (it picks the String branch), the kill switch
#    BC2CPP_NATIVE_PARAM_UNBOX=0 restores the old gate, and every world that makes the native not the target keeps its arm
#    out (reopened class, prepend, alias, define_method, singleton, method_missing, wrong arity).
# 3. Behaviour on real mruby with stand-ins for the rgss:: bodies (the real ones need SDL): for Integer, Float (0.5, -0.5, 1e30,
#    NaN, +-Infinity, bignum), nil, String, true/false, Symbol, Array, Object, Rational and objects with a to_int that logs, raises
#    or answers a non-Integer, one and two bad arguments, a frozen receiver and a wrong argument count, the compiled
#    answers, exceptions (class and message), to_int call order and the values the bodies saw equal the interpreter's, with and
#    without the kill switch.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/native_param_unbox_check.rb
# Also run with BC2CPP_CXXFLAGS="-DMRB_32BIT -DMRB_INT32" on a 32-bit mrb_int build (BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32).

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative 'native_param_audit'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

root = File.expand_path('../..', __dir__)
runtime = Bc2cppFixtureRuntime

# -- 1. audit ---------------------------------------------------------------------------

puts '== audit'
mruby_dir = File.join(root, '3rd/mruby')
if File.exist?(File.join(mruby_dir, 'src/class.c'))
  digests = NativeParamAudit.pin_digests(mruby_dir)
  NativeParamAudit::MRUBY_PINS.each do |(file, marker), pinned|
    check.call("mruby #{file} #{marker} is the audited text", digests[[file, marker]] == pinned)
  end
  class_c = File.read(File.join(mruby_dir, 'src/class.c'))
  check.call('"i" is exactly *p = mrb_as_int(mrb, *pickarg)',
             NativeParamAudit.squash(NativeParamAudit.mruby_text(class_c, "case 'i':")).include?('*p = mrb_as_int(mrb, *pickarg);'))
  check.call('"f" is exactly *p = mrb_as_float(mrb, *pickarg)',
             NativeParamAudit.squash(NativeParamAudit.mruby_text(class_c, "case 'f':")).include?('*p = mrb_as_float(mrb, *pickarg);'))
  check.call('"b" is exactly *boolp = mrb_test(*pickarg)',
             NativeParamAudit.squash(NativeParamAudit.mruby_text(class_c, "case 'b':")).include?('*boolp = mrb_test(*pickarg);'))
else
  check.call('3rd/mruby is present to pin the specifiers', false)
end

bindings = NativeParamAudit.bindings(Dir[File.join(root, 'mruby-rgss/src/*.cxx')].sort)
by_target = bindings.group_by { |owner, name, _body, _label| [owner, name] }
audited = 0
NativeDirect::ENTRIES.each do |name, owners|
  owners.each do |owner, entry|
    next unless entry.kinds.any? { |k| %i[int float bool].include?(k) }

    regs = by_target[[owner, name]]
    check.call("#{owner}##{name}: registered by a binding the audit can read", regs && !regs.empty?)
    Array(regs).each do |_o, _n, body, label|
      callees = [entry.function, entry.function.sub(/_direct\z/, '_native_body')]
      reasons = NativeParamAudit.audit_body(body, entry.kinds, callees)
      audited += 1
      check.call("#{owner}##{name}: #{label} is `decls; mrb_get_args(#{entry.kinds.inspect}); return #{entry.function}`", reasons.empty?)
      puts "       #{reasons.join('; ')}" unless reasons.empty?
    end
  end
end
check.call('the audit covered the table', audited >= 50)

# What the audit must refuse (a mutated binding).
good = <<~CPP
  mrb_int a, b = 0;
  mrb_get_args(M, "ii", &a, &b);
  return rgss::thing_direct(M, self, a, b);
CPP
audit = ->(body, kinds = %i[int int]) { NativeParamAudit.audit_body(body, kinds, %w[thing_direct]) }
check.call('the audit accepts the binding shape', audit.call(good).empty?)
check.call('the audit refuses a statement before mrb_get_args',
           !audit.call("mrb_int a, b;\nmrb_check_frozen(M, self);\nmrb_get_args(M, \"ii\", &a, &b);\nreturn rgss::thing_direct(M, self, a, b);").empty?)
check.call('the audit refuses a call in a declaration initializer',
           !audit.call("mrb_int a = side(M), b;\nmrb_get_args(M, \"ii\", &a, &b);\nreturn rgss::thing_direct(M, self, a, b);").empty?)
check.call('the audit refuses an optional argument', !audit.call(good.sub('"ii"', '"i|i"')).empty?)
check.call('the audit refuses swapped call arguments', !audit.call(good.sub('self, a, b', 'self, b, a')).empty?)
check.call('the audit refuses work after the call', !audit.call(good.sub('return rgss::thing_direct(M, self, a, b);', 'rgss::thing_direct(M, self, a, b); return self;')).empty?)
check.call('the audit refuses another callee', !audit.call(good.sub('thing_direct', 'other_direct')).empty?)
check.call('the audit refuses a different specifier', !audit.call(good.sub('"ii"', '"in"')).empty?)

# -- fixture ----------------------------------------------------------------------------

CLASSES = <<~RUBY
  module RGSS
    class Rect; end
    class Color; end
    class Sprite; end
    class Window; end
    class Viewport; end
    class Plane; end
    class Tilemap; end
    # mruby-rgss/mrblib/lib.rb's own dispatch: a String is a file, anything else is the "ii" size form.
    class Bitmap
      def initialize(f, s = nil)
        if f.kind_of? String
          @file = f
        else
          _init_size(f, s)
        end
      end
    end
  end
  module PuLog; end
RUBY

CALLERS = <<~RUBY
  class PuCaller
    def set_x(r, v); r.x = v; end
    def set_angle(s, v); s.angle = v; end
    def set_visible(s, v); s.visible = v; end
    def flash2(s, c, n); s.flash(c, n); end
    def flash1(s, c); s.flash(c); end
    def trans(b, m, p, v); b._transition_alpha(m, p, v); end
    def init_size(b, w, h); b._init_size(w, h); end
    def new_bitmap(w, h); RGSS::Bitmap.new(w, h); end
    def new_rect(a, b, c, d); RGSS::Rect.new(a, b, c, d); end
    def new_color(a, b, c, d); RGSS::Color.new(a, b, c, d); end
  end
RUBY

# One-argument calls take every value; two-argument calls take the pairs of a smaller set. The driver runs unchanged in
# the interpreted and the compiled VM, so only PuCaller differs.
DRIVER = <<~RUBY
  $pu_calls = []
  class PuObj
    def initialize(tag, answer); @tag = tag; @answer = answer; end
    def to_int
      $pu_calls << "to_int(\#{@tag})"
      raise ArgumentError, "boom \#{@tag}" if @answer == :raise
      @answer
    end
    def to_f
      $pu_calls << "to_f(\#{@tag})"
      @answer
    end
    def inspect; "PuObj(\#{@tag})"; end
  end
  class PuPlain; def inspect; 'PuPlain'; end; end
  class PuDriver
    def values
      v = [0, 5, -3, 2**31, 2**40, 2**64, 0.5, -0.5, 2.5, 1e30, 0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0, nil, 's', true, false, :sym, [1], PuPlain.new,
           PuObj.new('ok', 7), PuObj.new('raise', :raise), PuObj.new('str', 'x'), PuObj.new('flo', 2.5), PuObj.new('nil', nil)]
      begin
        v << Rational(7, 2)
      rescue NoMethodError, NameError
        nil
      end
      v
    end

    def pairs
      small = [3, 1.5, nil, 's', PuObj.new('a', 4), PuObj.new('r', :raise), PuObj.new('b', 'x'), 0.0 / 0.0, 2**64]
      small.flat_map { |a| small.map { |b| [a, b] } }
    end

    def show(v)
      return 'NaN' if v.is_a?(Float) && v.nan?
      return v.inspect if v.nil? || v == true || v == false || v.is_a?(Integer) || v.is_a?(Float) || v.is_a?(String) || v.is_a?(Symbol) || v.is_a?(Array)

      v.is_a?(PuObj) || v.is_a?(PuPlain) ? v.inspect : v.class.to_s
    end

    def attempt(label)
      $pu_calls.clear
      PuLog.take
      begin
        r = yield
        out = "\#{label} => \#{show(r)}"
      rescue Exception => e
        out = "\#{label} => raised \#{e.class}: \#{e.message}"
      end
      body, dispatched = PuLog.take
      out + " calls=\#{$pu_calls.join(',')} body=\#{body}" + "\n  dispatches=\#{dispatched}"
    end

    def rects
      [['plain', RGSS::Rect.allocate], ['frozen', RGSS::Rect.allocate.freeze]]
    end

    def run
      out = []
      c = PuCaller.new
      values.each_with_index do |v, i|
        rects.each { |tag, r| out << attempt("x=[\#{i}] \#{tag} \#{show(v)}") { c.set_x(r, v) } }
        out << attempt("angle=[\#{i}] \#{show(v)}") { c.set_angle(RGSS::Sprite.allocate, v) }
        out << attempt("visible=[\#{i}] \#{show(v)}") { c.set_visible(RGSS::Sprite.allocate, v) }
        out << attempt("flash[\#{i}] \#{show(v)}") { c.flash2(RGSS::Sprite.allocate, :color, v) }
        out << attempt("Window x=[\#{i}] \#{show(v)}") { c.set_x(RGSS::Window.allocate, v) }
        out << attempt("Bitmap.new[\#{i}] \#{show(v)}x3") { c.new_bitmap(v, 3) }
        out << attempt("Bitmap.new[\#{i}] 3x\#{show(v)}") { c.new_bitmap(3, v) }
        out << attempt("Rect.new[\#{i}] \#{show(v)}") { c.new_rect(1, v, 3, 4) }
        out << attempt("Color.new[\#{i}] \#{show(v)}") { c.new_color(1, 2, v, 4) }
      end
      pairs.each_with_index do |(a, b), i|
        out << attempt("trans[\#{i}] \#{show(a)} \#{show(b)}") { c.trans(RGSS::Bitmap.allocate, :map, a, b) }
        out << attempt("init_size[\#{i}] \#{show(a)} \#{show(b)}") { c.init_size(RGSS::Bitmap.allocate, a, b) }
        out << attempt("Bitmap.new[\#{i}] \#{show(a)} \#{show(b)}") { c.new_bitmap(a, b) }
        out << attempt("Rect.new[\#{i}] \#{show(a)} \#{show(b)}") { c.new_rect(a, b, b, a) }
        out << attempt("Color.new[\#{i}] \#{show(a)} \#{show(b)}") { c.new_color(a, b, b, a) }
        rects.each { |tag, r| out << attempt("frozen x=[\#{i}] \#{tag} \#{show(a)}") { c.set_x(r, a) } }
      end
      out << attempt('flash1') { c.flash1(RGSS::Sprite.allocate, :color) }
      out << attempt('flash1 viewport') { c.flash1(RGSS::Viewport.allocate, :color) }
      out << attempt('x= on a String') { c.set_x('str', 1) }
      out << attempt('x= on nil') { c.set_x(nil, 1) }
      out
    end
  end
RUBY

OWNERS = %w[PuCaller].freeze

# Link-and-run stand-ins: each body logs the receiver class, the method and the C values it was handed, and raises the
# FrozenError a real body would raise for a frozen receiver, after the conversions.
STANDIN = <<~'CPP'
  #include <string>
  #include <cmath>
  static std::string pu_log;
  static mrb_state* pu_M = nullptr;
  static RClass* pu_class(const char* name) { return mrb_class_get_under(pu_M, mrb_module_get(pu_M, "RGSS"), name); }
  static void pu_note(mrb_state* M, mrb_value self, const char* name, const std::string& args) {
    pu_log += std::string(mrb_obj_classname(M, self)) + "#" + name + "(" + args + ");";
    mrb_check_frozen_value(M, self);
  }
  static std::string pu_i(mrb_int v) { return std::to_string((long long)v); }
  static std::string pu_f(mrb_float v) { return std::isnan(v) ? std::string("nan") : std::to_string(v); }
  namespace rgss {
  RClass* native_rect_class(void) { return pu_class("Rect"); }
  RClass* native_color_class(void) { return pu_class("Color"); }
  RClass* native_tone_class(void) { return pu_class("Rect"); }
  RClass* native_sprite_class(void) { return pu_class("Sprite"); }
  RClass* native_bitmap_class(void) { return pu_class("Bitmap"); }
  RClass* native_table_class(void) { return pu_class("Rect"); }
  RClass* native_window_class(void) { return pu_class("Window"); }
  RClass* native_viewport_class(void) { return pu_class("Viewport"); }
  RClass* native_plane_class(void) { return pu_class("Plane"); }
  RClass* native_tilemap_class(void) { return pu_class("Tilemap"); }
  mrb_value rect_new_direct(mrb_state* M, RClass* k, mrb_int x, mrb_int y, mrb_int w, mrb_int h) {
    pu_log += "Rect.new(" + pu_i(x) + "," + pu_i(y) + "," + pu_i(w) + "," + pu_i(h) + ");";
    return (mrb_funcall_id)(M, mrb_obj_value(k), mrb_intern_lit(M, "allocate"), 0);
  }
  mrb_value color_new_direct(mrb_state* M, RClass* k, mrb_float r, mrb_float g, mrb_float b, mrb_float a) {
    pu_log += "Color.new(" + pu_f(r) + "," + pu_f(g) + "," + pu_f(b) + "," + pu_f(a) + ");";
    return (mrb_funcall_id)(M, mrb_obj_value(k), mrb_intern_lit(M, "allocate"), 0);
  }
  mrb_value bitmap_new_direct(mrb_state* M, RClass* k, mrb_int w, mrb_int h) {
    pu_log += "Bitmap.new(" + pu_i(w) + "," + pu_i(h) + ");";
    return (mrb_funcall_id)(M, mrb_obj_value(k), mrb_intern_lit(M, "allocate"), 0);
  }
  mrb_value bmp_init_size_direct(mrb_state* M, mrb_value self, mrb_int w, mrb_int h) {
    pu_log += "Bitmap.new(" + pu_i(w) + "," + pu_i(h) + ");";
    return self;
  }
  mrb_value rect_x_set_direct(mrb_state* M, mrb_value self, mrb_int x) { pu_note(M, self, "x=", pu_i(x)); return self; }
  mrb_value object_x_set_direct(mrb_state* M, mrb_value self, mrb_int x) { pu_note(M, self, "x=", pu_i(x)); return self; }
  mrb_value spr_set_angle_direct(mrb_state* M, mrb_value self, mrb_float d) { pu_note(M, self, "angle=", pu_f(d)); return self; }
  mrb_value object_visible_set_direct(mrb_state* M, mrb_value self, mrb_bool v) { pu_note(M, self, "visible=", pu_i(v)); return self; }
  mrb_value tilemap_visible_set_direct(mrb_state* M, mrb_value self, mrb_bool v) { pu_note(M, self, "visible=", pu_i(v)); return self; }
  mrb_value sprite_flash_direct(mrb_state* M, mrb_value self, mrb_value c, mrb_int n) { pu_note(M, self, "flash", "c," + pu_i(n)); return self; }
  mrb_value viewport_flash_direct(mrb_state* M, mrb_value self, mrb_value c, mrb_int n) { pu_note(M, self, "flash", "c," + pu_i(n)); return self; }
  mrb_value bmp_transition_alpha_direct(mrb_state* M, mrb_value self, mrb_value m, mrb_float p, mrb_float v) {
    pu_note(M, self, "_transition_alpha", "m," + pu_f(p) + "," + pu_f(v));
    return self;
  }
  }  // namespace rgss
  // The bindings the interpreter reaches by dispatch, shaped exactly like mruby-rgss's (the audit above pins that shape).
  #define PU_BIND1(fn, fmt, type, direct) \
    static mrb_value fn(mrb_state* M, mrb_value self) { type a; mrb_get_args(M, fmt, &a); return rgss::direct(M, self, a); }
  PU_BIND1(pu_rect_x, "i", mrb_int, rect_x_set_direct)
  PU_BIND1(pu_obj_x, "i", mrb_int, object_x_set_direct)
  PU_BIND1(pu_angle, "f", mrb_float, spr_set_angle_direct)
  PU_BIND1(pu_visible, "b", mrb_bool, object_visible_set_direct)
  PU_BIND1(pu_tm_visible, "b", mrb_bool, tilemap_visible_set_direct)
  static mrb_value pu_sprite_flash(mrb_state* M, mrb_value self) {
    mrb_value c; mrb_int n; mrb_get_args(M, "oi", &c, &n); return rgss::sprite_flash_direct(M, self, c, n);
  }
  static mrb_value pu_viewport_flash(mrb_state* M, mrb_value self) {
    mrb_value c; mrb_int n; mrb_get_args(M, "oi", &c, &n); return rgss::viewport_flash_direct(M, self, c, n);
  }
  static mrb_value pu_trans(mrb_state* M, mrb_value self) {
    mrb_value m; mrb_float p, v; mrb_get_args(M, "off", &m, &p, &v); return rgss::bmp_transition_alpha_direct(M, self, m, p, v);
  }
  static mrb_value pu_init_size(mrb_state* M, mrb_value self) {
    mrb_int w, h; mrb_get_args(M, "ii", &w, &h); return rgss::bmp_init_size_direct(M, self, w, h);
  }
  static mrb_value pu_rect_init(mrb_state* M, mrb_value self) {
    mrb_int x, y, w, h;
    mrb_get_args(M, "iiii", &x, &y, &w, &h);
    pu_log += "Rect.new(" + pu_i(x) + "," + pu_i(y) + "," + pu_i(w) + "," + pu_i(h) + ");";
    return self;
  }
  static mrb_value pu_color_init(mrb_state* M, mrb_value self) {
    mrb_float r, g, b, a;
    mrb_get_args(M, "ffff", &r, &g, &b, &a);
    pu_log += "Color.new(" + pu_f(r) + "," + pu_f(g) + "," + pu_f(b) + "," + pu_f(a) + ");";
    return self;
  }
  static mrb_value pu_take(mrb_state* M, mrb_value) {
    mrb_value r = mrb_ary_new_capa(M, 2);
    mrb_ary_push(M, r, mrb_str_new(M, pu_log.data(), pu_log.size()));
    mrb_ary_push(M, r, mrb_fixnum_value(dispatches));
    pu_log.clear();
    dispatches = 0;
    return r;
  }
  static int scenario(mrb_state* M) {
    pu_M = M;
    auto def = [&](const char* k, const char* n, mrb_func_t f, int args) { mrb_define_method(M, pu_class(k), n, f, MRB_ARGS_REQ(args)); };
    def("Rect", "x=", pu_rect_x, 1);
    def("Sprite", "x=", pu_obj_x, 1); def("Window", "x=", pu_obj_x, 1);
    def("Sprite", "angle=", pu_angle, 1);
    def("Sprite", "visible=", pu_visible, 1); def("Window", "visible=", pu_visible, 1);
    def("Viewport", "visible=", pu_visible, 1); def("Plane", "visible=", pu_visible, 1); def("Tilemap", "visible=", pu_tm_visible, 1);
    def("Sprite", "flash", pu_sprite_flash, 2); def("Viewport", "flash", pu_viewport_flash, 2);
    def("Bitmap", "_transition_alpha", pu_trans, 3);
    def("Bitmap", "_init_size", pu_init_size, 2);
    def("Rect", "initialize", pu_rect_init, 4);
    def("Color", "initialize", pu_color_init, 4);
    mrb_define_module_function(M, mrb_module_get(M, "PuLog"), "take", pu_take, MRB_ARGS_NONE());
    mrb_value driver = mrb_obj_new(M, mrb_class_get(M, "PuDriver"), 0, nullptr);
    mrb_value lines = mrb_funcall_id(M, driver, mrb_intern_lit(M, "run"), 0);
    if (M->exc) { mrb_print_error(M); return 3; }
    for (mrb_int i = 0; i < RARRAY_LEN(lines); ++i) {
      mrb_value s = mrb_ary_ref(M, lines, i);
      std::printf("%.*s\n", (int)RSTRING_LEN(s), RSTRING_PTR(s));
    }
    return 0;
  }
CPP

generate = lambda do |source, dir, closed: true, env: {}, only: OWNERS, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(source, dir, closed: closed, only_owners: only, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end
body_of = lambda do |code, fn|
  code[/^mrb_value PuCaller_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
live_of = ->(code, fn) { body_of.call(code, fn).lines.reject { |l| l.lstrip.start_with?('//') }.join }

# -- 2. generated code --------------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, = generate.call(CLASSES + CALLERS, dir)
    Dir.mktmpdir do |off|
      legacy, = generate.call(CLASSES + CALLERS, off, env: { 'BC2CPP_NATIVE_PARAM_UNBOX' => '0' })

      x = live_of.call(code, 'set_x')
      check.call('x=: one converting arm per entry point, no Integer tag test, no mrb_integer, one by-name send (the chain tail)',
                 x.include?('rgss::rect_x_set_direct(') && x.include?('rgss::object_x_set_direct(') &&
                   x.scan(/mrb_as_int\(M, r\d+\)/).size == 2 && !x.include?('mrb_integer') && x.scan('bc2cpp_send(').size == 1)
      check.call('x=: the receiver class-identity test is kept and the tail still dispatches a receiver outside the arms',
                 x.include?('bc2cpp_native_class ==') && x.include?("} else {\n    r") && x.scan('bc2cpp_send(').size == 1)
      lx = live_of.call(legacy, 'set_x')
      check.call('BC2CPP_NATIVE_PARAM_UNBOX=0: x= keeps its Integer tag test and the by-name else',
                 lx.scan('mrb_integer_p(r').size == 2 && lx.scan('bc2cpp_send(').size == 3 && !lx.include?('mrb_as_int('))

      t = live_of.call(code, 'trans')
      check.call('a call with two float arguments converts them in two statements, in argument order',
                 t.match?(/mrb_float (bc2cpp_pu\d+_1) = mrb_as_float\(M, r(\d+)\);\n\s+mrb_float (bc2cpp_pu\d+_2) = mrb_as_float\(M, r(\d+)\);\n\s+r\d+ = rgss::bmp_transition_alpha_direct\(M, r\d+, r\d+, \1, \3\);/) &&
                   (m = t.match(/= mrb_as_float\(M, r(\d+)\);\n\s+mrb_float \S+ = mrb_as_float\(M, r(\d+)\)/)) && m[1].to_i < m[2].to_i)
      check.call('and it never nests a conversion in the call expression', !t.match?(/_direct\([^;]*mrb_as_float/))

      f = live_of.call(code, 'flash2')
      check.call('an untyped argument is passed through, only the :int one is converted',
                 f.match?(/mrb_int bc2cpp_pu\d+_1 = mrb_as_int\(M, r\d+\);\n\s+r\d+ = rgss::sprite_flash_direct\(M, r\d+, r\d+, bc2cpp_pu\d+_1\);/))
      check.call('a :bool argument is mrb_test, with no conversion statement',
                 live_of.call(code, 'set_visible').include?('mrb_test(r') && !live_of.call(code, 'set_visible').include?('mrb_as_'))
      check.call('a call of another arity than the entry point takes keeps the by-name send',
                 live_of.call(code, 'flash1').include?('bc2cpp_send(') && !live_of.call(code, 'flash1').include?('rgss::'))
      i = live_of.call(code, 'init_size')
      check.call('_init_size: both arguments are converted as "ii" does, in order', i.match?(/mrb_int (bc2cpp_pu\d+_0) = mrb_as_int\(M, r(\d+)\);\n\s+mrb_int bc2cpp_pu\d+_1 = mrb_as_int\(M, r(\d+)\);/) &&
                   !i.include?('mrb_integer_p'))

      nb = live_of.call(code, 'new_bitmap')
      check.call('Bitmap.new keeps one tag test, on the first argument only (it picks the String branch), and converts the second',
                 nb.scan(/mrb_integer_p\(/).size == 1 && nb.include?('mrb_as_int(M, ') && nb.include?('bc2cpp_send('))
      lnb = live_of.call(legacy, 'new_bitmap')
      check.call('BC2CPP_NATIVE_PARAM_UNBOX=0: Bitmap.new tests both arguments',
                 lnb.match?(/mrb_integer_p\(r\d+\) && mrb_integer_p\(r\d+\)/))
      nr = live_of.call(code, 'new_rect')
      check.call('Rect.new converts its four arguments as four statements in order, none inside the call',
                 nr.scan(/mrb_int bc2cpp_pu\d+_\d = mrb_as_int\(M, r\d+\);/).size == 4 && !nr.match?(/rect_new_direct\([^;]*mrb_as_int/))
      nc = live_of.call(code, 'new_color')
      check.call('Color.new converts its four arguments as four float statements in order',
                 nc.scan(/mrb_float bc2cpp_pu\d+_\d = mrb_as_float\(M, r\d+\);/).size == 4 && !nc.match?(/color_new_direct\([^;]*mrb_as_float/))

      # Worlds where the name no longer reaches the native keep the old gate (tag test, by-name else) or lose the arm;
      # worlds that leave the native the target stay converting. A nested `module RGSS` keeps the owner name resolvable.
      reopen = ->(body) { "module RGSS\n  class Rect\n#{body}\n  end\nend\n" }
      worlds = [
        ['a reopened Rect with a Ruby x=', reopen.call('def x=(v); @x = v; end'), :withdrawn],
        ['a module prepended to Rect', "module PuPre\n  def x=(v); super(v + 1); end\nend\n#{reopen.call('prepend PuPre')}", :withdrawn],
        ['a define_method of x= on Rect', reopen.call('define_method(:x=) { |v| @x = v }'), :withdrawn],
        ['an alias_method of x=', reopen.call('alias_method :x=, :inspect'), :gate],
        ['an alias keyword of x=', reopen.call('alias x= inspect'), :gate],
        ['a runtime installer with a computed name', "class PuCaller\n  def install(k, n); k.send(:define_method, n) { |v| v }; end\nend\n", :gate],
        ['a singleton method on an object', "class PuCaller\n  def single(r); def r.x=(v); :s; end; r; end\nend\n", :gate],
        ['define_singleton_method', "class PuCaller\n  def single(r); r.define_singleton_method(:x=) { |v| :s }; r; end\nend\n", :gate],
        ['instance_eval defining x=', "class PuCaller\n  def ev(r); r.instance_eval { def x=(v); :ie; end }; end\nend\n", :gate],
        ['an Object#method_missing', "class Object\n  def method_missing(n, *a); :mm; end\nend\n", :gate],
        ['a Rect#method_missing (x= is found natively first)', reopen.call('def method_missing(n, *a); :mm; end'), :converting],
        ['a Ruby subclass of Rect (its instances miss the exact-class test)', "class PuSub < RGSS::Rect\n  def x=(v); :sub; end\nend\n", :converting],
        ['a module included into Rect (the class\'s own native precedes it)', "module PuInc\n  def x=(v); :inc; end\nend\n#{reopen.call('include PuInc')}", :converting]
      ]
      worlds.each do |what, extra, expect|
        Dir.mktmpdir do |wd|
          wcode, = generate.call(CLASSES + CALLERS + extra, wd, only: nil)
          wx = live_of.call(wcode, 'set_x')
          rect_arm = wx.include?('rgss::rect_x_set_direct(')
          verdict = case expect
                    when :withdrawn then !rect_arm
                    when :gate then rect_arm && wx.scan('mrb_integer_p(r').size == 2 && wx.scan('bc2cpp_send(').size == 3 && !wx.include?('mrb_as_int(')
                    else rect_arm && !wx.include?('mrb_integer_p(') && wx.scan('mrb_as_int(M, ').size == 2
                    end
          says = { withdrawn: 'the Rect arm is gone', gate: 'the arm keeps its Integer test and by-name else', converting: 'the arm converts' }
          check.call("#{what}: #{says.fetch(expect)}", verdict)
        end
      end
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 3. behaviour -------------------------------------------------------------------------

builds = []
if ENV['MRBC'] && runtime.compiler? && !ENV['PU_GENERATED_ONLY']
  flags = ENV.fetch('BC2CPP_CXXFLAGS', '')
  primary = runtime.full || runtime.full_or_build
  builds << ['full-core', primary, ENV.fetch('MRBC'), flags] if primary
  if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
    builds << ['mrb_int 32, full-core', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie']
  end
end
if builds.empty?
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby)'
else
  puts '== fixture on real mruby, interpreted and compiled'
  builds.each do |label, build, mrbc, flags|
    [['unbox', {}], ['kill switch', { 'BC2CPP_NATIVE_PARAM_UNBOX' => '0' }]].each do |mode, env|
      puts "-- #{label}, #{mode}"
      saved = { 'MRBC' => ENV.fetch('MRBC'), 'BC2CPP_CXXFLAGS' => ENV.fetch('BC2CPP_CXXFLAGS', nil) }
      ENV['MRBC'] = mrbc
      ENV['BC2CPP_CXXFLAGS'] = flags
      begin
        Dir.mktmpdir do |dir|
          _code, err = generate.call(CLASSES + CALLERS + DRIVER, dir, env: env)
          built, output = runtime.run(dir, err, OWNERS, STANDIN, build: build, full: File.exist?("#{build}/lib/libmruby.a"))
          check.call("#{label}/#{mode}: the fixture compiles and runs against real mruby", built)
          next unless built

          sections = runtime.sections(output)
          interpreted = sections.fetch('interpreted', [])
          compiled = sections.fetch('compiled', [])
          # The old code converted two floats inside one call expression, whose operand order is unspecified (g++ evaluates the
          # last first, so a nil-then-String pair raised the String's error): the kill switch keeps that, so those lines are
          # compared only when the conversions are sequenced.
          unordered = mode == 'unbox' ? nil : /\A(trans|Color\.new)\[/
          strip = ->(lines) { lines.reject { |l| l.start_with?('  dispatches') || (unordered && l.match?(unordered)) } }
          if strip.call(interpreted) != strip.call(compiled)
            first = strip.call(interpreted).zip(strip.call(compiled)).find { |a, b| a != b }
            puts "    first difference:\n      interpreted #{first&.first.inspect}\n      compiled    #{first&.last.inspect}"
          end
          check.call("#{label}/#{mode}: every call answers, raises (class and message), logs its to_int calls and shows the " \
                     "body the same values as the interpreter (#{strip.call(interpreted).size} lines)",
                     !interpreted.empty? && strip.call(interpreted) == strip.call(compiled))
          lines = strip.call(compiled)
          puts output if ENV['BC2CPP_CHECK_VERBOSE']
          has = ->(re) { lines.any? { |l| l.match?(re) } }
          # The matrix really reached the conversions: a Float truncated, a range error, an object that mrb_as_int refuses.
          check.call('a Float 0.5 reached the body as 0', has.call(/\Ax=\[6\] plain 0\.5 => .*body=RGSS::Rect#x=\(0\);/))
          check.call('1e30 raised a RangeError before the body ran', has.call(/\Ax=\[9\] plain \S+ => raised \w+Error.*body=\z/))
          check.call('nil raised a TypeError before the body ran', has.call(/\Ax=\[13\] plain nil => raised TypeError.*body=\z/))
          check.call('an object with a to_int is not converted by mrb_as_int (no call, TypeError), as mrb_get_args "i"',
                     has.call(/\Ax=\[20\] plain PuObj\(ok\) => raised TypeError.* calls= body=\z/))
          check.call('a frozen receiver raised only after its argument converted (the body ran with 0), and a bad argument won over it',
                     has.call(/\Ax=\[6\] frozen 0\.5 => raised FrozenError.* body=RGSS::Rect#x=\(0\);/) &&
                       has.call(/\Ax=\[13\] frozen nil => raised TypeError/))
          message = ->(re) { lines.find { |l| l.match?(re) }.to_s[/raised \w+: [^=]*?(?= calls=)/] }
          first_bad = message.call(/\Atrans\[21\] /)
          second_bad = message.call(/\Atrans\[29\] /)
          check.call('two bad arguments: the earlier one in argument order is the error raised (nil first vs String first differ)',
                     mode != 'unbox' || (first_bad && second_bad && first_bad != second_bad &&
                       message.call(/\Ainit_size\[21\] /) != message.call(/\Ainit_size\[29\] /)))
          check.call('Bitmap.new of a String keeps the file form: it raises through Bitmap#initialize, not the size form',
                     lines.none? { |l| l.include?('"s"x3') && l.include?('Bitmap.new(') })
          check.call('a wrong argument count raises the interpreter\'s ArgumentError', has.call(/\Aflash1 => raised ArgumentError/))
          next unless mode == 'unbox'

          # The point of the change: no by-name dispatch left in the arms, whatever the argument is.
          arm_cases = compiled.each_cons(2).select { |a, _| a.start_with?('x=[') || a.start_with?('angle=[') || a.start_with?('visible=[') || a.start_with?('flash[') }
          check.call("#{label}: x=, angle=, visible= and flash made no dynamic dispatch for any argument (#{arm_cases.size} calls)",
                     !arm_cases.empty? && arm_cases.all? { |_, b| b == '  dispatches=0' })
          kill_cases = nil
          kill_cases
        end
      ensure
        saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
      end
    end
  end
end

if failures.empty?
  puts 'bc2cpp native param unbox check: PASS'
else
  warn "bc2cpp native param unbox check: #{failures.size} failure(s)"
  exit 1
end
