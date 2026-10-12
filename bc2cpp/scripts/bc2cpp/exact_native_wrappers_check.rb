#!/usr/bin/env ruby
# frozen_string_literal: true

# Check EXACT_NATIVE_WRAPPER (docs/adr/0307): a send of an RGSS wrapper (Bitmap#clear/fill_rect/blt/
# stretch_blt/copy_blt/draw_text/text_size, Sprite#bitmap=/opacity=/tone=/update/dispose,
# Window#tone=/openness=, Viewport#tone=) whose receiver the exact-class flow proves to be exactly
# that native class calls the wrapper body with no class test and no dispatch; a nil-or-class receiver
# takes one nil test first (NILABLE_RECEIVER).
#
# 1. Generated code (needs MRBC): positives lose their class test and their dispatch; the call
#    text equals the one of the guarded arm; every withdrawal condition (a second class, a
#    parameter, an attr_writer, reflection, a subclass, a singleton maker, a Ruby override or
#    define_method of the name, the kill switches, the open world) keeps the guard.
# 2. Behaviour on real mruby with a stand-in for the rgss:: bodies (the real ones need SDL): compiled
#    answers and the calls the bodies receive equal the interpreter's, with zero dispatches on the
#    exact methods. Run it on a full-core and a core-only mruby, and with BC2CPP_CXXFLAGS="-DMRB_32BIT
#    -DMRB_INT32" on a 32-bit mrb_int build.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/exact_native_wrappers_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

CLASSES = <<~RUBY
  module RGSS
    class Bitmap; def initialize(*); end; end
    class Sprite; def initialize(*); end; end
    class Window; def initialize(*); end; end
    class Viewport; def initialize(*); end; end
  end
  class ExSub < RGSS::Bitmap; end
  # A Ruby definer of `width` next to the natives makes it a POLY chain, whose proven-dead tail is a nomethod.
  class ExThing; def width; 3; end; end
RUBY

HOST = <<~RUBY
  class ExHost
    attr_writer :written

    def initialize
      @bmp = RGSS::Bitmap.new(4, 4)
      @src = RGSS::Bitmap.new(2, 2)
      @spr = RGSS::Sprite.new
      @win = RGSS::Window.new
      @vp = RGSS::Viewport.new
      @maybe = nil
      @mixed = RGSS::Sprite.new
      @param = RGSS::Bitmap.new(1, 1)
      @written = RGSS::Bitmap.new(1, 1)
      @refl = RGSS::Bitmap.new(1, 1)
    end

    # -- exact: ivars every constructor assigns a fresh native instance, never stored again
    def clear_it; @bmp.clear; end
    def fill_it; @bmp.fill_rect(1, 2, 3, 4, 5); end
    def blt4; @bmp.blt(1, 2, @src, 3); end
    def blt5; @bmp.blt(1, 2, @src, 3, 99); end
    def stretch3; @bmp.stretch_blt(1, @src, 2); end
    def stretch4; @bmp.stretch_blt(1, @src, 2, 77); end
    def copy_it; @bmp.copy_blt(1, 2, @src, 3); end
    def text5; @bmp.draw_text(1, 2, 3, 4, 'hi'); end
    def text2; @bmp.draw_text(1, 'yo'); end
    def text_sz; @bmp.text_size('hi'); end
    def set_bmp; @spr.bitmap = @bmp; end
    def set_op; @spr.opacity = 7; end
    def tone_spr; @spr.tone = 1; end
    def tone_win; @win.tone = 2; end
    def tone_vp; @vp.tone = 3; end
    def open_win; @win.openness = 128; end
    def upd_spr; @spr.update; end
    def disp_spr; @spr.dispose; end
    def local_fill
      b = RGSS::Bitmap.new(2, 2)
      b.fill_rect(5, 6, 7, 8, 9)
    end

    # -- nil or exactly one class: one nil test, then the unguarded call
    def setup; @maybe = RGSS::Bitmap.new(3, 3); end
    def maybe_clear; @maybe.clear; end
    def maybe_fill; @maybe.fill_rect(1, 1, 1, 1, 1); end
    # `width` has an arm for Bitmap and one for Rect, so the plain code already has no dispatch left to shed:
    # only the exact mark of the unguarded call makes the nil test worth it (codegen_nilable_receiver.rb).
    def maybe_width; @maybe.width; end
    def width_it; @bmp.width; end
    # NEG: an arity the wrapper does not take keeps the send (the interpreter's own answer).
    def bad_arity; @bmp.fill_rect(1, 2); end

    # -- NEG: the same calls on receivers the flow cannot prove (guard and dispatch kept)
    def arg_clear(b); b.clear; end
    def arg_fill(b); b.fill_rect(1, 2, 3, 4, 5); end
    def arg_blt4(b, s); b.blt(1, 2, s, 3); end
    def arg_blt5(b, s); b.blt(1, 2, s, 3, 99); end
    def arg_stretch3(b, s); b.stretch_blt(1, s, 2); end
    def arg_stretch4(b, s); b.stretch_blt(1, s, 2, 77); end
    def arg_copy(b, s); b.copy_blt(1, 2, s, 3); end
    def arg_text5(b); b.draw_text(1, 2, 3, 4, 'hi'); end
    def arg_text2(b); b.draw_text(1, 'yo'); end
    def arg_text_sz(b); b.text_size('hi'); end
    def arg_set_bmp(s, b); s.bitmap = b; end
    def arg_set_op(s); s.opacity = 7; end
    def arg_tone_spr(s); s.tone = 1; end
    def arg_tone_win(w); w.tone = 2; end
    def arg_tone_vp(v); v.tone = 3; end
    def arg_open_win(w); w.openness = 128; end
    def arg_upd_spr(s); s.update; end
    def arg_disp_spr(s); s.dispose; end

    def swap; @mixed = RGSS::Viewport.new; end
    def read_mixed; @mixed.tone = 1; end
    def put(b); @param = b; end
    def read_param; @param.clear; end
    def read_written; @written.clear; end
    def poke; instance_variable_set(:@refl, RGSS::Sprite.new); end
    def read_refl; @refl.clear; end
  end
RUBY

OWNERS = %w[ExHost ExThing].freeze
EXACT = %w[clear_it fill_it blt4 blt5 stretch3 stretch4 copy_it text5 text2 text_sz set_bmp set_op tone_spr tone_win tone_vp
           open_win upd_spr disp_spr width_it local_fill].freeze
# exact method => its guarded twin on an argument receiver
TWIN = { 'clear_it' => 'arg_clear', 'fill_it' => 'arg_fill', 'blt4' => 'arg_blt4', 'blt5' => 'arg_blt5',
         'stretch3' => 'arg_stretch3', 'stretch4' => 'arg_stretch4', 'copy_it' => 'arg_copy', 'text5' => 'arg_text5',
         'text2' => 'arg_text2', 'text_sz' => 'arg_text_sz', 'set_bmp' => 'arg_set_bmp', 'set_op' => 'arg_set_op',
         'tone_spr' => 'arg_tone_spr', 'tone_win' => 'arg_tone_win', 'tone_vp' => 'arg_tone_vp',
         'open_win' => 'arg_open_win', 'upd_spr' => 'arg_upd_spr', 'disp_spr' => 'arg_disp_spr' }.freeze

body_of = lambda do |code, owner, fn|
  code[/^mrb_value #{owner}_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
live_of = ->(code, owner, fn) { body_of.call(code, owner, fn).lines.reject { |l| l.lstrip.start_with?('//') }.join }
exact = lambda do |code, owner, fn|
  body = body_of.call(code, owner, fn)
  live = live_of.call(code, owner, fn)
  body.match?(/EXACT_NATIVE_WRAPPER|NATIVE_EXACT_DIRECT/) && !live.include?('bc2cpp_send(') && !live.include?('mrb_funcall') &&
    !live.include?('mrb_obj_class(M, r')
end
guarded = lambda do |code, owner, fn|
  body = body_of.call(code, owner, fn)
  !body.empty? && !body.include?('EXACT_NATIVE_WRAPPER') && live_of.call(code, owner, fn).include?('bc2cpp_send(')
end
nilable = lambda do |code, owner, fn|
  body = body_of.call(code, owner, fn)
  body.include?('NILABLE_RECEIVER') && body.match?(/EXACT_NATIVE_WRAPPER|NATIVE_EXACT_DIRECT/) && !live_of.call(code, owner, fn).include?('bc2cpp_send(')
end
# The wrapper call, registers and layout stripped: what the guarded arm and the unguarded arm must agree on.
wrapper_call = lambda do |code, owner, fn|
  live_of.call(code, owner, fn).gsub(/\s+/, ' ')[/rgss::(?!native_)\w+\(M, [^;]*\);/].to_s.gsub(/\br\d+\b/, 'R')
end

generate = lambda do |source, dir, closed: true, env: {}, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(source, dir, closed: closed, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

# -- 1. generated code -----------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, err = generate.call(CLASSES + HOST, dir)

    (EXACT - %w[local_fill]).each do |fn|
      check.call("ExHost##{fn}: a flow-proven native receiver takes the wrapper body with no class test and no send",
                 exact.call(code, 'ExHost', fn))
    end
    # The constructor's own argument-tag else is not this change's (ADR 0307, what was not built).
    check.call('ExHost#local_fill: a constructor local takes the wrapper body with no class test',
               body_of.call(code, 'ExHost', 'local_fill').include?('EXACT_NATIVE_WRAPPER :fill_rect') &&
                 !live_of.call(code, 'ExHost', 'local_fill').include?('mrb_obj_class(M, r'))
    TWIN.each do |fn, twin|
      check.call("ExHost##{twin}: an argument receiver keeps the class test and the send",
                 guarded.call(code, 'ExHost', twin) && body_of.call(code, 'ExHost', twin).include?('mrb_obj_class(M, r'))
      # Window#tone=/openness= and Viewport#tone= have a guarded arm only for a hint-traced receiver, so
      # an argument twin takes another arm; their bodies are the hint arm's (compile_send).
      next if %w[tone_win tone_vp open_win].include?(fn)
      next unless (twin_call = wrapper_call.call(code, 'ExHost', twin)) && !twin_call.empty?

      check.call("ExHost##{fn}: the unguarded call is the guarded arm's call (#{twin_call[/rgss::\w+/]})",
                 wrapper_call.call(code, 'ExHost', fn) == twin_call)
    end
    { 'tone_win' => 'window_tone_set_direct', 'tone_vp' => 'viewport_tone_set_direct',
      'open_win' => 'window_openness_set_direct' }.each do |fn, function|
      check.call("ExHost##{fn}: calls rgss::#{function}", live_of.call(code, 'ExHost', fn).include?("rgss::#{function}(M, r"))
    end
    check.call('ExHost#width_it: a zero-argument wrapper of an exact receiver is unguarded', exact.call(code, 'ExHost', 'width_it'))
    check.call('ExHost#bad_arity: a call of another arity than the wrapper takes keeps the guard and send',
               guarded.call(code, 'ExHost', 'bad_arity'))
    # NILABLE_RECEIVER weighs the nil test by dispatches shed, or by an exact mark when the plain code has
    # none left (a proven-dead nomethod tail: the wio world's `width`/`height`); the world here cannot make
    # that tail dead, so the mark is checked on its own.
    tool = File.expand_path(ENV.fetch('BC2CPP_TOOL', 'tools/bc2cpp/bc2cpp.rb'), File.expand_path('../..', __dir__))
    nilable_source = File.read(File.join(File.dirname(tool), 'codegen_nilable_receiver.rb'))
    exact_mark = nilable_source[/EXACT_MARK = (%r\{.*?\}\S*)/, 1]
    note = code[/^\s*\/\/ EXACT_NATIVE_WRAPPER :\S+ .*$/]
    check.call("NILABLE_RECEIVER's exact marks name the unguarded wrapper call (the nil test is kept when it is all that is left)",
               exact_mark && note && eval(exact_mark).match?(note)) # rubocop:disable Security/Eval
    %w[maybe_clear maybe_fill maybe_width].each do |fn|
      check.call("ExHost##{fn}: nil-or-Bitmap takes one nil test, then the unguarded body", nilable.call(code, 'ExHost', fn))
    end
    check.call('the nil arm is the NIL_RECEIVER helper, not a send',
               body_of.call(code, 'ExHost', 'maybe_clear').include?('bc2cpp_nil_receiver(M,'))

    { 'read_mixed' => 'two classes (Sprite, Viewport)', 'read_param' => 'a parameter is stored into it',
      'read_written' => 'an attr_writer reaches it', 'read_refl' => 'instance_variable_set(:@refl)' }.each do |fn, why|
      check.call("NEG ExHost##{fn}: #{why} keeps the guard", guarded.call(code, 'ExHost', fn))
    end

    variants = {
      'a subclass instance is stored in the ivar' => { extra: "class ExHost\n  def sub; @bmp = ExSub.new(1, 1); end\nend\n" },
      'a parameter is stored in the ivar' => { extra: "class ExHost\n  def put_bmp(b); @bmp = b; end\nend\n" },
      'an instance_variable_set with a computed name' => { global: true,
                                                           extra: "class ExHost\n  def wild(n, v); instance_variable_set(n, v); end\nend\n" },
      'a singleton maker (a def on an object)' => { global: true,
                                                    extra: "class ExHost\n  def maker; a = [1]; def a.other(*); 1; end; a; end\nend\n" },
      'an allocate' => { extra: "class ExHost\n  def raw; self.class.allocate; end\nend\n", nilable: true },
      'a native source that spells @bmp' => { native: [['ew_native.cxx', "void ew_touch(mrb_state* M, mrb_value o) { mrb_iv_set(M, o, mrb_intern_lit(M, \"@bmp\"), mrb_nil_value()); }\n"]] },
      'a Ruby override of Bitmap#clear' => { extra: "class RGSS::Bitmap\n  def clear; :ruby; end\nend\n", only: %w[clear_it] },
      'a define_method of Bitmap#fill_rect' => { extra: "class RGSS::Bitmap\n  define_method(:fill_rect) { |*a| :dyn }\nend\n",
                                                only: %w[fill_it] }
    }
    variants.each do |what, spec|
      d = File.join(dir, what.gsub(/\W+/, '_'))
      Dir.mkdir(d)
      vcode, = generate.call(CLASSES + HOST + spec.fetch(:extra, ''), d, **spec.slice(:native, :foreign))
      verdict = if spec[:only]
                  spec[:only].all? { |fn| guarded.call(vcode, 'ExHost', fn) }
                elsif spec[:nilable]
                  nilable.call(vcode, 'ExHost', 'clear_it')
                elsif spec.key?(:global)
                  !exact.call(vcode, 'ExHost', 'clear_it') && !exact.call(vcode, 'ExHost', 'set_bmp')
                else
                  !exact.call(vcode, 'ExHost', 'clear_it') && !exact.call(vcode, 'ExHost', 'fill_it')
                end
      check.call("#{what}: #{spec[:nilable] ? 'clear_it is nil-or-Bitmap' : 'withdrawn as the model says'}", verdict)
    end
    check.call('control: the subclass-free fixture keeps the exact proof on set_bmp (Sprite ivar)', exact.call(code, 'ExHost', 'set_bmp'))

    Dir.mktmpdir do |off_dir|
      off_code, = generate.call(CLASSES + HOST, off_dir, env: { 'BC2CPP_EXACT_NATIVE_WRAPPERS' => '0' })
      check.call('the kill switch (BC2CPP_EXACT_NATIVE_WRAPPERS=0): every exact method keeps its guard and send',
                 !off_code.include?('EXACT_NATIVE_WRAPPER') &&
                   %w[clear_it fill_it blt4 stretch3 copy_it text5 text_sz set_bmp set_op].all? { |fn| guarded.call(off_code, 'ExHost', fn) })
    end
    Dir.mktmpdir do |pools_dir|
      pools_code, = generate.call(CLASSES + HOST, pools_dir, env: { 'BC2CPP_CLASS_POOLS' => '0' })
      check.call('BC2CPP_CLASS_POOLS=0: ivar receivers keep their guard, a constructor local stays exact',
                 guarded.call(pools_code, 'ExHost', 'clear_it') &&
                   body_of.call(pools_code, 'ExHost', 'local_fill').include?('EXACT_NATIVE_WRAPPER :fill_rect'))
    end
    Dir.mktmpdir do |strict_dir|
      marshal = "class ExHost\n  def roundtrip(o); Marshal.load(Marshal.dump(o)); end\nend\n"
      default_code, = generate.call(CLASSES + HOST + marshal, strict_dir)
      Dir.mktmpdir do |d2|
        strict_code, = generate.call(CLASSES + HOST + marshal, d2, env: { 'BC2CPP_CLASS_POOLS' => 'strict' })
        check.call('a world that can reach Marshal: the default models hostile bytes as outside, =strict withdraws the pools',
                   exact.call(default_code, 'ExHost', 'clear_it') && !exact.call(strict_code, 'ExHost', 'clear_it'))
      end
    end
    Dir.mktmpdir do |open_dir|
      open_code, = generate.call(CLASSES + HOST, open_dir, closed: false)
      check.call('the open world proves nothing: no unguarded wrapper call',
                 !open_code.include?('EXACT_NATIVE_WRAPPER'))
    end
    check.call('stderr names no failed pool for the exact ivars', err.include?('CLASSIVAR ExHost#@bmp (RGSS::Bitmap)'))
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 2. behaviour ----------------------------------------------------------------------

# [label, build dir, host mrbc, extra compiler flags]: the full-core build, the core-only one when named
# too, and a 32-bit `mrb_int` one (BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32, scripts/bc2cpp/width_build.rb int32).
builds = []
if ENV['MRBC'] && runtime.compiler?
  flags = ENV.fetch('BC2CPP_CXXFLAGS', '')
  primary = runtime.full || runtime.core || runtime.full_or_build
  builds << [runtime.full ? 'full-core' : 'core-only', primary, ENV.fetch('MRBC'), flags] if primary
  builds << ['core-only', runtime.core, ENV.fetch('MRBC'), flags] if runtime.full && runtime.core
  if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
    builds << ['mrb_int 32, full-core', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie']
  end
end
if !builds.empty? && !ENV['EW_GENERATED_ONLY']
  puts '== fixture on real mruby, interpreted and compiled'
  # A stand-in for mruby-rgss's wrapper bodies: they record the receiver class, the method and the
  # arguments it was called with, so the compiled direct call and the interpreted dispatch to the
  # binding are compared on what the body would have seen.
  body = <<~'CPP'
    #include <string>
    static mrb_state* ew_M = nullptr;
    static std::string ew_log;
    static std::string ew_show(mrb_state* M, mrb_value v) {
      if (mrb_integer_p(v) || mrb_string_p(v) || mrb_symbol_p(v) || mrb_nil_p(v)) {
        mrb_value s = mrb_inspect(M, v);
        return std::string(RSTRING_PTR(s), RSTRING_LEN(s));
      }
      return std::string("<") + mrb_obj_classname(M, v) + ">";
    }
    static mrb_value ew_record(mrb_state* M, mrb_value self, const char* name, mrb_int argc, const mrb_value* argv) {
      ew_log += std::string(mrb_obj_classname(M, self)) + "#" + name + "(";
      for (mrb_int i = 0; i < argc; ++i) ew_log += (i ? "," : "") + ew_show(M, argv[i]);
      ew_log += ");";
      return mrb_symbol_value(mrb_intern_cstr(M, name));
    }
    static RClass* ew_class(const char* name) { return mrb_class_get_under(ew_M, mrb_module_get(ew_M, "RGSS"), name); }
    namespace rgss {
    RClass* native_bitmap_class(void) { return ew_class("Bitmap"); }
    RClass* native_sprite_class(void) { return ew_class("Sprite"); }
    RClass* native_window_class(void) { return ew_class("Window"); }
    RClass* native_viewport_class(void) { return ew_class("Viewport"); }
    mrb_value bitmap_new_direct(mrb_state* M, RClass* klass, mrb_int, mrb_int) { return mrb_obj_new(M, klass, 0, nullptr); }
    mrb_value sprite_new_direct(mrb_state* M, RClass* klass, mrb_value) { return mrb_obj_new(M, klass, 0, nullptr); }
    mrb_value bitmap_clear_direct(mrb_state* M, mrb_value self) { return ew_record(M, self, "clear", 0, nullptr); }
    RClass* native_rect_class(void) { return ew_class("Bitmap"); }
    mrb_value bitmap_width_direct(mrb_state* M, mrb_value self) { return ew_record(M, self, "width", 0, nullptr); }
    mrb_value rect_width_direct(mrb_state* M, mrb_value self) { return ew_record(M, self, "width", 0, nullptr); }
    mrb_value bitmap_fill_rect_direct(mrb_state* M, mrb_value self, mrb_value x, mrb_value y, mrb_value w, mrb_value h,
                                      mrb_value c) {
      mrb_value a[] = { x, y, w, h, c };
      return ew_record(M, self, "fill_rect", 5, a);
    }
    mrb_value bitmap_blt_direct(mrb_state* M, mrb_value self, mrb_value x, mrb_value y, mrb_value s, mrb_value r,
                                mrb_value o, mrb_bool given) {
      mrb_value a[] = { x, y, s, r, o };
      return ew_record(M, self, "blt", given ? 5 : 4, a);
    }
    mrb_value bitmap_stretch_blt_direct(mrb_state* M, mrb_value self, mrb_value d, mrb_value s, mrb_value r,
                                        mrb_value o, mrb_bool given) {
      mrb_value a[] = { d, s, r, o };
      return ew_record(M, self, "stretch_blt", given ? 4 : 3, a);
    }
    mrb_value bitmap_draw_text_direct(mrb_state* M, mrb_value self, mrb_int argc, const mrb_value* argv) {
      return ew_record(M, self, "draw_text", argc, argv);
    }
    mrb_value bitmap_copy_blt_direct(mrb_state* M, mrb_value self, mrb_value x, mrb_value y, mrb_value s, mrb_value r) {
      mrb_value a[] = { x, y, s, r };
      return ew_record(M, self, "copy_blt", 4, a);
    }
    mrb_value bitmap_text_size_direct(mrb_state* M, mrb_value self, mrb_value t) { return ew_record(M, self, "text_size", 1, &t); }
    mrb_value sprite_bitmap_set_direct(mrb_state* M, mrb_value self, mrb_value b) { return ew_record(M, self, "bitmap=", 1, &b); }
    mrb_value sprite_opacity_set_direct(mrb_state* M, mrb_value self, mrb_value v) { return ew_record(M, self, "opacity=", 1, &v); }
    mrb_value sprite_tone_set_direct(mrb_state* M, mrb_value self, mrb_value v) { return ew_record(M, self, "tone=", 1, &v); }
    mrb_value window_tone_set_direct(mrb_state* M, mrb_value self, mrb_value v) { return ew_record(M, self, "tone=", 1, &v); }
    mrb_value viewport_tone_set_direct(mrb_state* M, mrb_value self, mrb_value v) { return ew_record(M, self, "tone=", 1, &v); }
    mrb_value window_openness_set_direct(mrb_state* M, mrb_value self, mrb_value v) { return ew_record(M, self, "openness=", 1, &v); }
    // The guarded arms of the argument twins name these too; the scenario never reaches a Plane or Tilemap.
    RClass* native_plane_class(void) { return ew_class("Bitmap"); }
    RClass* native_tilemap_class(void) { return ew_class("Bitmap"); }
    mrb_value tilemap_dispose_direct(mrb_state* M, mrb_value self) { return ew_record(M, self, "dispose", 0, nullptr); }
    mrb_value window_set_openness_direct(mrb_state* M, mrb_value self, mrb_int v) {
      mrb_value a = mrb_fixnum_value(v);
      return ew_record(M, self, "openness=", 1, &a);
    }
    mrb_value viewport_update_direct(mrb_state* M, mrb_value self) { return ew_record(M, self, "update", 0, nullptr); }
    mrb_value window_update_direct(mrb_state* M, mrb_value self) { return ew_record(M, self, "update", 0, nullptr); }
    mrb_value sprite_update_direct(mrb_state* M, mrb_value self) { return ew_record(M, self, "update", 0, nullptr); }
    mrb_value dispose_direct(mrb_state* M, mrb_value self) { return ew_record(M, self, "dispose", 0, nullptr); }
    }  // namespace rgss
    // The binding the interpreter reaches by dispatch, and the compiled code's fallback.
    static mrb_value ew_binding(mrb_state* M, mrb_value self) {
      const mrb_value* argv;
      mrb_int argc;
      mrb_get_args(M, "*", &argv, &argc);
      return ew_record(M, self, mrb_sym_name(M, mrb_get_mid(M)), argc, argv);
    }
    static void ew_define(mrb_state* M, const char* klass, std::initializer_list<const char*> names) {
      for (const char* n : names) mrb_define_method(M, mrb_class_get_under(M, mrb_module_get(M, "RGSS"), klass), n, ew_binding, MRB_ARGS_ANY());
    }
    static void ew_call(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc = 0,
                        const mrb_value* argv = nullptr) {
      dispatches = 0;
      mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
      int made = dispatches;
      if (M->exc) {
        mrb_value e = mrb_obj_value(M->exc);
        M->exc = nullptr;
        std::printf("%s => raised %s\n", label, mrb_obj_classname(M, e));
      } else {
        std::printf("%s => %s\n", label, ew_show(M, r).c_str());
      }
      if (compiled) std::printf("  dispatches=%d\n", made);
      std::printf("  log %s\n", ew_log.c_str());
      ew_log.clear();
    }
    static int scenario(mrb_state* M) {
      ew_M = M;
      ew_define(M, "Bitmap", { "width", "clear", "fill_rect", "blt", "stretch_blt", "copy_blt", "draw_text", "text_size" });
      ew_define(M, "Sprite", { "bitmap=", "opacity=", "tone=", "update", "dispose" });
      ew_define(M, "Window", { "tone=", "openness=" });
      ew_define(M, "Viewport", { "tone=" });
      mrb_value host = mrb_obj_new(M, mrb_class_get(M, "ExHost"), 0, nullptr);
      ew_log.clear();
      auto fresh = [&](const char* k) { return mrb_obj_new(M, ew_class(k), 0, nullptr); };
      mrb_value bmp = fresh("Bitmap"), src = fresh("Bitmap"), spr = fresh("Sprite"), win = fresh("Window"), vp = fresh("Viewport");
      static const char* exact[] = { "clear_it", "fill_it", "blt4", "blt5", "stretch3", "stretch4", "copy_it", "text5", "text2",
                                     "text_sz", "width_it", "set_bmp", "set_op", "tone_spr", "tone_win", "tone_vp", "open_win",
                                     "upd_spr", "disp_spr", "local_fill" };
      for (const char* fn : exact) ew_call(M, fn, host, fn);
      ew_call(M, "maybe_clear before setup", host, "maybe_clear");
      ew_call(M, "maybe_fill before setup", host, "maybe_fill");
      ew_call(M, "maybe_width before setup", host, "maybe_width");
      ew_call(M, "bad_arity", host, "bad_arity");
      ew_call(M, "setup", host, "setup");
      ew_call(M, "maybe_clear", host, "maybe_clear");
      ew_call(M, "maybe_fill", host, "maybe_fill");
      ew_call(M, "maybe_width", host, "maybe_width");
      mrb_value one[1], two[2];
      one[0] = bmp; ew_call(M, "arg_clear", host, "arg_clear", 1, one);
      ew_call(M, "arg_fill", host, "arg_fill", 1, one);
      ew_call(M, "arg_text5", host, "arg_text5", 1, one);
      ew_call(M, "arg_text2", host, "arg_text2", 1, one);
      ew_call(M, "arg_text_sz", host, "arg_text_sz", 1, one);
      two[0] = bmp; two[1] = src;
      ew_call(M, "arg_blt4", host, "arg_blt4", 2, two);
      ew_call(M, "arg_blt5", host, "arg_blt5", 2, two);
      ew_call(M, "arg_stretch3", host, "arg_stretch3", 2, two);
      ew_call(M, "arg_stretch4", host, "arg_stretch4", 2, two);
      ew_call(M, "arg_copy", host, "arg_copy", 2, two);
      two[0] = spr; two[1] = bmp;
      ew_call(M, "arg_set_bmp", host, "arg_set_bmp", 2, two);
      one[0] = spr;
      ew_call(M, "arg_set_op", host, "arg_set_op", 1, one);
      ew_call(M, "arg_tone_spr", host, "arg_tone_spr", 1, one);
      ew_call(M, "arg_upd_spr", host, "arg_upd_spr", 1, one);
      ew_call(M, "arg_disp_spr", host, "arg_disp_spr", 1, one);
      one[0] = win;
      ew_call(M, "arg_tone_win", host, "arg_tone_win", 1, one);
      ew_call(M, "arg_open_win", host, "arg_open_win", 1, one);
      one[0] = vp;
      ew_call(M, "arg_tone_vp", host, "arg_tone_vp", 1, one);
      // The wrong class where a Bitmap is expected: the guarded arm dispatches and raises like the interpreter.
      one[0] = spr;
      ew_call(M, "arg_clear on a Sprite", host, "arg_clear", 1, one);
      ew_call(M, "read_mixed", host, "read_mixed");
      ew_call(M, "swap", host, "swap");
      ew_call(M, "read_mixed after swap", host, "read_mixed");
      one[0] = fresh("Bitmap");
      ew_call(M, "put", host, "put", 1, one);
      ew_call(M, "read_param", host, "read_param");
      ew_call(M, "written=", host, "written=", 1, one);
      ew_call(M, "read_written", host, "read_written");
      return 0;
    }
  CPP
  builds.each do |label, build, mrbc, flags|
    puts "-- #{label}"
    saved = { 'MRBC' => ENV.fetch('MRBC'), 'BC2CPP_CXXFLAGS' => ENV.fetch('BC2CPP_CXXFLAGS', nil) }
    ENV['MRBC'] = mrbc
    ENV['BC2CPP_CXXFLAGS'] = flags
    Dir.mktmpdir do |dir|
      _code, err = generate.call(CLASSES + HOST, dir)
      full = File.exist?("#{build}/lib/libmruby.a")
      built, output = runtime.run(dir, err, OWNERS, body, build: build, full: full)
      check.call("#{label}: the fixture compiles and runs against real mruby", built)
      if built
        sections = runtime.sections(output)
        interpreted = sections.fetch('interpreted', []).reject { |l| l.start_with?('  dispatches') }
        compiled = sections.fetch('compiled', []).reject { |l| l.start_with?('  dispatches') }
        puts output if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
        check.call("every method answers, logs and raises what the interpreter does (#{interpreted.size} lines)",
                   !interpreted.empty? && interpreted == compiled)
        check.call('the wrapper bodies saw the arguments (blt opacity default, draw_text array, tone on three classes)',
                   compiled.include?('  log RGSS::Bitmap#blt(1,2,<RGSS::Bitmap>,3);') &&
                     compiled.include?('  log RGSS::Bitmap#blt(1,2,<RGSS::Bitmap>,3,99);') &&
                     compiled.include?('  log RGSS::Bitmap#draw_text(1,2,3,4,"hi");') &&
                     compiled.include?('  log RGSS::Sprite#tone=(1);') && compiled.include?('  log RGSS::Window#tone=(2);') &&
                     compiled.include?('  log RGSS::Viewport#tone=(3);'))
        # A core-only mruby (no mrblib) reports another exception class on both sides, so there the pin is the
        # interpreter's own line, and that it raised; full-core pins NoMethodError.
        core_only = label.start_with?('core-only')
        raised_line = lambda do |label_text, pinned|
          actual = compiled.find { |l| l.start_with?("#{label_text} =>") }.to_s
          expected = core_only ? interpreted.find { |l| l.start_with?("#{label_text} =>") }.to_s : pinned
          ok = actual == expected && expected.include?('raised')
          puts "    expected #{expected.inspect}, actual #{actual.inspect}" unless ok
          ok
        end
        nil_ok = raised_line.call('maybe_clear before setup', 'maybe_clear before setup => raised NoMethodError')
        check.call("#{label}: a nil receiver raises where the interpreter does, a set-up one answers",
                   nil_ok && compiled.include?('maybe_clear => :clear'))
        check.call('the two-class ivar reached both classes (a wrong exact proof would log Sprite twice)',
                   compiled.include?('  log RGSS::Sprite#tone=(1);') && compiled.include?('  log RGSS::Viewport#tone=(1);'))
        sprite_ok = raised_line.call('arg_clear on a Sprite', 'arg_clear on a Sprite => raised NoMethodError')
        check.call("#{label}: a Sprite where a Bitmap was passed raises through dispatch", sprite_ok)
        check.call('the parameter and the attr_writer writes are seen',
                   compiled.count('read_param => :clear') == 1 && compiled.count('read_written => :clear') == 1)

        compiled_lines = sections.fetch('compiled', [])
        zero = EXACT.all? do |fn|
          at = compiled_lines.index { |l| l.start_with?("#{fn} => ") }
          at && compiled_lines[at + 1] == '  dispatches=0'
        end
        check.call('every exact method made zero dynamic dispatches', zero)
      end
    end
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
end

if failures.empty?
  puts 'bc2cpp exact native wrappers check: PASS'
else
  warn "bc2cpp exact native wrappers check: #{failures.size} failure(s)"
  exit 1
end
