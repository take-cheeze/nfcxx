#!/usr/bin/env ruby
# encoding: UTF-8
# Check NATIVE_DIRECT (docs/adr/0253): sends to RGSS natives with a frame-
# independent entry point (include/rgss_construct.hxx) get exact-class arms in
# the else of the call site's guard chain, and, in a closed world where those
# arms name every native class answering the name, the chain's fallback is the
# proven-dead nomethod raise instead of a by-name dispatch.
#
#   - the tables: every NativeDirect entry is declared with the right arity,
#     defined in lib.cxx, called by its binding, and registered on that class;
#   - the registration parser attributes lib.cxx's registrations to classes and
#     declines a name it cannot fully account for;
#   - generated code: arms, argument type guards that dispatch on a mismatch,
#     the lifted nomethod fallback, and every reason that lift is refused
#     (subclass, Ruby override, wrong arity, name defined elsewhere).
require 'fileutils'
require 'open3'
require 'set'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/native_direct'
require_relative '../../tools/bc2cpp/closed_world'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# -- tables ---------------------------------------------------------------------

# The entry points and bindings live in lib.cxx and, since ADR 0281, the audio and tts sources.
lib = Dir[File.join(root, 'mruby-rgss/src/*.cxx')].sort.map { |path| File.read(path) }.join("\n")
header = File.read(File.join(root, 'include/rgss_construct.hxx')) + File.read(File.join(root, 'include/rgss_native_direct.hxx'))
rgss_srcs = Dir[File.join(root, 'mruby-rgss/src/*.cxx')]

declared = header.scan(/mrb_value\s+(\w+)\(([^)]*)\)\s*;/m).to_h { |fn, params| [fn, params.split(',').size] }
NativeDirect::ENTRIES.each do |name, owners|
  owners.each do |owner, entry|
    fn = entry.function
    check.call("#{owner}##{name}: #{fn} is declared with #{2 + entry.kinds.size} parameters",
               declared[fn] == 2 + entry.kinds.size)
    check.call("#{owner}##{name}: #{fn} is defined in lib.cxx", lib.match?(/^mrb_value #{fn}\(mrb_state\* M/))
    # `color` is spelled elsewhere in lib.cxx, so its class set is unproven (and
    # never lifted); the registration itself is still there.
    registered = rgss_srcs.flat_map { |src| NativeDirect.file_registrations(src)[name]&.fetch(:owners) || [] }
    check.call("#{owner}##{name}: #{owner} registers #{name} natively", registered.include?(owner))
    # A hand-written entry is what its binding calls; a split one (ADR 0263) is
    # what the generated forwarder in lib.cxx calls the binding's body from.
    next if entry.kinds.empty?

    check.call("#{fn} is what the #{name} binding calls or forwards to the binding's body",
               lib.include?("rgss::#{fn}(M, self") || lib.match?(/^mrb_value #{fn}\(mrb_state\* M,[^{}]*\{\s*return \w+_native_body\(M, self/m))
  end
end

parsed = NativeDirect.registered_owners('z=', rgss_srcs)
check.call('the parser attributes z= to its five display classes',
           parsed == Set.new(%w[RGSS::Viewport RGSS::Sprite RGSS::Plane RGSS::Tilemap RGSS::Window]))
check.call('a Rect registration made in a function taking the module as a parameter is attributed',
           NativeDirect.registered_owners('width', rgss_srcs) == Set.new(%w[RGSS::Rect RGSS::Bitmap]))
check.call('a class method registers on the singleton, not the class',
           NativeDirect.registered_owners('update', rgss_srcs).include?('RGSS::Graphics.singleton'))
Dir.mktmpdir do |dir|
  file = File.join(dir, 'fake.cxx')
  File.write(file, <<~CXX)
    void init(mrb_state* M) {
      RClass* m = mrb_define_module(M, "Fake");
      RClass* a = mrb_define_class_under(M, m, "A", M->object_class);
      mrb_define_method(M, a, "size", f, MRB_ARGS_NONE());
      mrb_funcall(M, v, "size", 0);
      mrb_define_method(M, a, "width", f, MRB_ARGS_NONE());
    }
  CXX
  check.call('a name also spelled outside a registration is not proven',
             NativeDirect.registered_owners('size', [file]).nil?)
  check.call('a fully accounted name is attributed', NativeDirect.registered_owners('width', [file]) == Set['Fake::A'])
  file = File.join(dir, 'fake2.cxx')
  File.write(file, <<~CXX)
    void init(mrb_state* M, RClass* cls) {
      mrb_define_method(M, cls, "width", f, MRB_ARGS_NONE());
    }
  CXX
  check.call('a class variable the file never defines is not proven', NativeDirect.registered_owners('width', [file]).nil?)
end

# ADR 0281: a module handed to a define function in another file (lib.cxx's gem init calls
# rgss_audio_define) is attributed only while every call site passes the same, resolved module.
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'audio.cxx'), <<~CXX)
    void audio_define(mrb_state* M, RClass* rgss) {
      RClass* audio = mrb_define_module_under(M, rgss, "Audio");
      mrb_define_module_function(M, audio, "_stop", stop, MRB_ARGS_NONE());
    }
  CXX
  File.write(File.join(dir, 'lib.cxx'), <<~CXX)
    void init(mrb_state* M) {
      RClass* m = mrb_define_module(M, "RGSS");
      audio_define(M, m);
    }
  CXX
  audio = File.join(dir, 'audio.cxx')
  check.call('a module passed to a define function in another file is attributed',
             NativeDirect.registered_owners('_stop', [audio]) == Set['RGSS::Audio.singleton'])
  Dir.mktmpdir do |other|
    File.write(File.join(other, 'audio.cxx'), File.read(audio))
    File.write(File.join(other, 'lib.cxx'), <<~CXX)
      void init(mrb_state* M, RClass* unknown) {
        RClass* m = mrb_define_module(M, "RGSS");
        RClass* n = mrb_define_module(M, "Other");
        audio_define(M, m);
        audio_define(M, n);
      }
    CXX
    check.call('two call sites passing different modules leave the registration unproven',
               NativeDirect.registered_owners('_stop', [File.join(other, 'audio.cxx')]).nil?)
  end
  Dir.mktmpdir do |other|
    File.write(File.join(other, 'audio.cxx'), File.read(audio))
    File.write(File.join(other, 'lib.cxx'), <<~CXX)
      void init(mrb_state* M, RClass* unknown) {
        audio_define(M, unknown);
      }
    CXX
    check.call('a call site passing an unresolved class variable leaves the registration unproven',
               NativeDirect.registered_owners('_stop', [File.join(other, 'audio.cxx')]).nil?)
  end
end

# ClosedWorld: which files may clear a class's Ruby definers, and who may subclass.
Dir.mktmpdir do |dir|
  rgss_dir = File.join(dir, 'mruby-rgss/src')
  FileUtils.mkdir_p(rgss_dir)
  plain = File.join(rgss_dir, 'plain.cxx')
  File.write(plain, <<~CXX)
    void init(mrb_state* M) {
      RClass* m = mrb_define_module(M, "RGSS");
      RClass* s = mrb_define_class_under(M, m, "Sprite", M->object_class);
      mrb_define_method(M, s, "x=", f, MRB_ARGS_REQ(1));
    }
  CXX
  decl = ->(name, sup) { { name => [{ super: sup, outer_nil: true }] } }
  make = lambda do |native, decls, ruby = []|
    ClosedWorld.new(ireps: {}, registry: {}, class_decls: decls, walked: Set.new, native_paths: native, ruby_paths: ruby)
  end
  world = make.call([plain], decl.call('Fake', :none))
  check.call('a native file naming x= is the only source of that name', world.native_only_in?('x=', '/mruby-rgss/src/'))
  check.call('no declared class subclasses Sprite', world.native_subclass_free?(['RGSS::Sprite']))
  world = make.call([plain], decl.call('MySprite', 'RGSS::Sprite'))
  check.call('a declared subclass is refused', !world.native_subclass_free?(['RGSS::Sprite']))
  File.write(File.join(dir, 'sub.rb'), "class Elsewhere < ::RGSS::Sprite\nend\n")
  world = make.call([plain], decl.call('Fake', :none), [File.join(dir, 'sub.rb')])
  check.call('an outside Ruby subclass is refused', !world.native_subclass_free?(['RGSS::Sprite']))
  File.write(File.join(dir, 'defs.rb'), "class Elsewhere\n  def x=(v); end\nend\n")
  world = make.call([plain], decl.call('Fake', :none), [File.join(dir, 'defs.rb')])
  check.call('an outside Ruby definition of the name is not native-only', !world.native_only_in?('x=', '/mruby-rgss/src/'))
  other = File.join(dir, 'other.c')
  File.write(other, 'void f(mrb_state* M, RClass* k) { mrb_define_method(M, k, "x=", g, MRB_ARGS_REQ(1)); }')
  world = make.call([plain, other], decl.call('Fake', :none))
  check.call('a registration from another file is not native-only', !world.native_only_in?('x=', '/mruby-rgss/src/'))
  world = make.call([plain], decl.call('Fake', nil))
  check.call('a class with an unresolved superclass could be anything: refused',
             !world.native_subclass_free?(['RGSS::Sprite']))
end

# -- generated code --------------------------------------------------------------

mrbc = ENV['MRBC'] || 'mrbc'
gems = NomethodReviewedProbe.wio_gems(root)
native_srcs = rgss_srcs + core_native_srcs(File.join(root, '3rd/mruby')) + external_gem_native_srcs(root)
generate = lambda do |source, name, closed, extra_env = {}|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'NATIVE_SRCS' => Shellwords.join(native_srcs) }.merge(extra_env)
    if closed
      env.merge!('BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                 'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                 NomethodReviewed::ALLOW_ENV => 'allow')
    end
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', path)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
    out
  end
end
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

WORLD = <<~'RUBY'
  class NdBox
    def z=(v); @z = v; end
    def x=(v); @x = v; end
    def flash(color); @flash = color; end
    def visible; true; end
  end
  class NdCaller
    def set_z(w, v); w.z = v; end
    def set_x(w, v); w.x = v; end
    def set_angle(w, v); w.angle = v; end
    def set_zoom_x(w, v); w.zoom_x = v; end
    def transition_alpha(w, map, progress, vague); w._transition_alpha(map, progress, vague); end
    def set_visible(w, v); w.visible = v; end
    def set_contents(w, v); w.contents = v; end
    def flash_both(w, c); w.flash(c, 4); end
    def flash_short(w, c); w.flash(c); end
    def read_visible(w); w.visible; end
  end
RUBY

SUBCLASS_WORLD = <<~'RUBY'
  class NdBox
    def z=(v); @z = v; end
  end
  class NdMySprite < RGSS::Sprite
  end
  class NdCaller
    def set_z(w, v); w.z = v; end
  end
RUBY

OVERRIDE_WORLD = <<~'RUBY'
  module RGSS
    class Window
      def x=(v); @x = v; end
    end
  end
  class NdCaller
    def set_x(w, v); w.x = v; end
  end
RUBY

open_code = generate.call(WORLD, 'nd_open', false)
closed_code = generate.call(WORLD, 'nd_closed', true)
sub_code = generate.call(SUBCLASS_WORLD, 'nd_sub', true)
override_code = generate.call(OVERRIDE_WORLD, 'nd_override', true)
# BC2CPP_NATIVE_PARAM_UNBOX=0 (ADR 0372) restores the Integer tag test and its by-name else.
legacy_open = generate.call(WORLD, 'nd_open_legacy', false, 'BC2CPP_NATIVE_PARAM_UNBOX' => '0')
legacy_closed = generate.call(WORLD, 'nd_closed_legacy', true, 'BC2CPP_NATIVE_PARAM_UNBOX' => '0')

open_z = body_of.call(open_code, 'NdCaller_set_z')
check.call('an integer setter tries the program chain first, then one arm per native entry point',
           open_z.index('NdBox_z$3d_impl') < open_z.index('rgss::object_z_set_direct(') &&
             open_z.include?('rgss::tilemap_z_set_direct(') &&
             open_z.scan(/bc2cpp_native_class == rgss::native_\w+_class\(\)/).size == 5)
check.call('classes sharing an entry point share an arm',
           open_z.include?('bc2cpp_native_class == rgss::native_viewport_class() || ' \
                           'bc2cpp_native_class == rgss::native_sprite_class()'))
closed_z = body_of.call(closed_code, 'NdCaller_set_z')
check.call('in a closed world an :int argument is converted in place as mrb_get_args "i" does: no tag test, no by-name else (ADR 0372)',
           closed_z.match?(/\{\n\s+mrb_int bc2cpp_pu\d+_0 = mrb_as_int\(M, r\d+\);\n\s+r\d+ = rgss::object_z_set_direct\(M, r\d+, bc2cpp_pu\d+_0\);\n\s+\}\n\s+\} else if/) &&
             !closed_z.include?('mrb_integer_p(') && !closed_z.include?('mrb_integer('))
check.call('without the closed world nothing proves the name reaches the native: the Integer test and its by-name else stay',
           open_z.match?(/if \(mrb_integer_p\(r\d+\)\) \{\n\s+r\d+ = rgss::object_z_set_direct\(M, r\d+, mrb_integer\(r\d+\)\);\n\s+\} else \{\n\s+r\d+ = bc2cpp_send\(/) &&
             !open_z.include?('mrb_as_int('))
legacy_z = body_of.call(legacy_open, 'NdCaller_set_z')
check.call('BC2CPP_NATIVE_PARAM_UNBOX=0 restores the Integer tag test whose else dispatches to the binding',
           legacy_z.match?(/if \(mrb_integer_p\(r\d+\)\) \{\n\s+r\d+ = rgss::object_z_set_direct\(M, r\d+, mrb_integer\(r\d+\)\);\n\s+\} else \{\n\s+r\d+ = bc2cpp_send\(/) &&
             !legacy_z.include?('mrb_as_int('))
check.call('without the closed world the last resort is still the by-name dispatch',
           open_z.match?(/\} else \{\n\s+r\d+ = bc2cpp_send\([^;]*\);\n\s+\}\n\s+\}\n\s+\}/) && !open_z.include?('bc2cpp_nomethod'))
check.call('a boolean argument is read with mrb_test, as mrb_get_args "b" does',
           body_of.call(open_code, 'NdCaller_set_visible').include?('rgss::object_visible_set_direct(M, r') &&
             body_of.call(open_code, 'NdCaller_set_visible').include?('mrb_test(r'))
float_angle = body_of.call(open_code, 'NdCaller_set_angle')
float_zoom = body_of.call(open_code, 'NdCaller_set_zoom_x')
float_transition = body_of.call(open_code, 'NdCaller_transition_alpha')
check.call('RGSS float arguments use mrb_as_float like mrb_get_args "f" for angle, zoom and transition calls',
           float_angle.include?('rgss::spr_set_angle_direct(M,') && float_angle.include?('mrb_as_float(M, r') &&
             float_zoom.include?('rgss::spr_set_zoom_x_direct(M,') && float_zoom.include?('mrb_as_float(M, r') &&
             float_transition.include?('rgss::bmp_transition_alpha_direct(M,') &&
             float_transition.scan('mrb_as_float(M, r').size == 2)
check.call('two float conversions are statements in argument order, never operands of one call expression (ADR 0372)',
           float_transition.match?(/mrb_float (bc2cpp_pu\d+_1) = mrb_as_float\(M, r\d+\);\n\s+mrb_float (bc2cpp_pu\d+_2) = mrb_as_float\(M, r\d+\);\n\s+r\d+ = rgss::bmp_transition_alpha_direct\(M, r\d+, r\d+, \1, \2\);/))
check.call('float conversion preserves a dynamic fallback for receivers outside the native class arms',
           float_angle.include?('bc2cpp_send(') && !float_angle.include?('mrb_float_p('))
contents = body_of.call(open_code, 'NdCaller_set_contents')
check.call('an untyped argument is passed through with no guard, and a name with no Ruby definer still gets its arm',
           contents.include?('rgss::window_contents_set_direct(M, r') && !contents.include?('mrb_integer_p') &&
             contents.include?('bc2cpp_send('))
flash = body_of.call(closed_code, 'NdCaller_flash_both')
open_flash = body_of.call(open_code, 'NdCaller_flash_both')
check.call('a two-argument entry guards only its integer argument while no closed world proves the name',
           open_flash.match?(/if \(mrb_integer_p\(r\d+\)\) \{\n\s+r\d+ = rgss::sprite_flash_direct\(M, r\d+, r\d+, mrb_integer\(r\d+\)\);/))
check.call('in a closed world it passes its untyped argument straight through and converts only the :int one',
           flash.match?(/mrb_int bc2cpp_pu\d+_1 = mrb_as_int\(M, r\d+\);\n\s+r\d+ = rgss::sprite_flash_direct\(M, r\d+, r\d+, bc2cpp_pu\d+_1\);/) &&
             flash.include?('rgss::viewport_flash_direct(') && !flash.include?('mrb_integer_p('))
legacy_flash = body_of.call(legacy_open, 'NdCaller_flash_both')
check.call('and with the switch off guards only its integer argument',
           legacy_flash.match?(/if \(mrb_integer_p\(r\d+\)\) \{\n\s+r\d+ = rgss::sprite_flash_direct\(M, r\d+, r\d+, mrb_integer\(r\d+\)\);/))
check.call('a call whose arity no native entry point has gets no arm',
           !body_of.call(open_code, 'NdCaller_flash_short').include?('rgss::'))
check.call('a getter arm covers the classes the older tables leave out',
           body_of.call(open_code, 'NdCaller_read_visible').include?('rgss::visible_direct(M, r') &&
             body_of.call(open_code, 'NdCaller_read_visible').include?('rgss::native_tilemap_class()'))

check.call('in a closed world the arms make the final else a proven-dead nomethod',
           closed_z.match?(/\} else \{\n\s+r\d+ = bc2cpp_nomethod\(M, r\d+, \d+, 1, r\d+\); \/\* CLOSED_WORLD nomethod: recv\.z= \*\//) &&
             !closed_z.include?('kept: core_or_native'))
check.call('an :int argument of any type reaches the converting arm; only a receiver outside the arms still dispatches',
           !closed_z.include?('mrb_integer_p(') && closed_z.scan(/mrb_as_int\(M, /).size == 2 && closed_z.scan(/bc2cpp_send\(/).size == 0)
legacy_closed_z = body_of.call(legacy_closed, 'NdCaller_set_z')
check.call('with the switch off the type-mismatch arm still dispatches, so the binding raises the real TypeError',
           legacy_closed_z.scan(/mrb_integer_p\(/).size == 2 && legacy_closed_z.scan(/bc2cpp_send\(/).size == 2)
check.call('a class-only guard chain lifts too: x= names Rect, Sprite and Window',
           body_of.call(closed_code, 'NdCaller_set_x').then do |x|
             x.include?('rgss::rect_x_set_direct(') && x.include?('rgss::object_x_set_direct(') &&
               x.include?('bc2cpp_nomethod(') && !x.include?('kept: core_or_native')
           end)
check.call('with no guard chain there is no closed-world proof, so the dispatch stays',
           body_of.call(closed_code, 'NdCaller_set_contents').include?('bc2cpp_send(') &&
             !body_of.call(closed_code, 'NdCaller_set_contents').include?('bc2cpp_nomethod'))
check.call('a call whose arity no native class has stays kept as before',
           !body_of.call(closed_code, 'NdCaller_flash_short').include?('rgss::'))
check.call('a program subclass of a native class keeps the dispatch (arms stay)',
           body_of.call(sub_code, 'NdCaller_set_z').then do |z|
             z.include?('rgss::object_z_set_direct(') && z.include?('kept: core_or_native') && !z.include?('bc2cpp_nomethod')
           end)
override = body_of.call(override_code, 'NdCaller_set_x')
check.call('a Ruby override on a native class replaces that class\'s arm and rides the chain',
           override.include?('RGSS__Window_x$3d_impl(') && override.include?('rgss::rect_x_set_direct(') &&
             override.include?('rgss::object_x_set_direct(') &&
             !override.match?(/native_window_class\(\)/))
check.call('and its nomethod is proven only because the chain lists the override',
           override.include?('bc2cpp_nomethod('))

puts "\n#{failures.size} check(s) failed" unless failures.empty?
exit(failures.empty? ? 0 : 1)
