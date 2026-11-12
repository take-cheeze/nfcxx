#!/usr/bin/env ruby
# frozen_string_literal: true

# UNDEF_LEFT_OUT (CoreNativeCandidates.undef_candidates): a core undef entry (mrb_undef_*) the closed build removes after
# init, because nothing but undef calls looks its name up.
#
#   - the scan: an undef call's name is collected and blanked; NativeOwnerMap records the undef with its owner;
#   - the proof: a name only undef calls reach is reported, one another native looks up or a core Ruby irep holds is
#     not; a listing of methods, a computed-name owner or a dynamic name keeps every undef;
#   - the lists: a file without core_undef_left_out reads it as empty;
#   - the run (full-core mruby, when one is available): bc2cpp_left_out_undef, the codegen template's own text, removes
#     only the owner's own undef entry; a program that does not look the name up prints the same with the entry as
#     without it, while the inherited method shows only once the entry is gone.
#
# Usage: ruby scripts/bc2cpp/undef_left_out_check.rb

require_relative '../../tools/bc2cpp/world_root'
require 'set'
require 'fileutils'
require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/native_owner_map'
require_relative '../../tools/bc2cpp/core_native_candidates'
require_relative '../../tools/bc2cpp/static_dispatch_lists'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

suite = FixtureCheck.new('undef_left_out_check')
sdr = StaticDispatchRegistrations

text = <<~C
  mrb_undef_class_method_id(mrb, integer, MRB_SYM(new));
  mrb_undef_method(mrb, cls, "module_function");
  mrb_undef_method_id(mrb, c, name);
C
found = Set.new
blanked = sdr.blank_undef_names(text, found)
suite.check('an undef call names its literal and MRB_SYM names', found == Set['new', 'module_function'])
suite.check('those names are blanked, a computed one stays', !blanked.include?('MRB_SYM(new)') && !blanked.include?('"module_function"') &&
                                                            blanked.include?('mrb_undef_method_id(mrb, c, name)'))

Dir.mktmpdir('undef-left-out') do |dir|
  undef_c = File.join(dir, '3rd/mruby/src/undefs.c')
  user_c = File.join(dir, '3rd/mruby/src/user.c')
  FileUtils.mkdir_p(File.dirname(undef_c))
  File.write(undef_c, <<~C)
    void init(mrb_state *mrb) {
      struct RClass *integer = mrb_define_class(mrb, "Integer", mrb->numeric_class);
      struct RClass *cls = mrb->class_class;
      mrb_undef_class_method_id(mrb, integer, MRB_SYM(new));
      mrb_undef_method_id(mrb, cls, MRB_SYM(module_function));
    }
  C
  File.write(user_c, "mrb_value f(mrb_state *mrb, mrb_value c) { return mrb_funcall_argv(mrb, c, MRB_SYM(new), 0, NULL); }\n")
  map = NativeOwnerMap.build([undef_c, user_c])
  suite.check('NativeOwnerMap records each undef with its owner',
              map.undefs.sort == [['Class', 'module_function'], ['Integer.singleton', 'new']])

  names, _fragments, undef_only = CoreNativeCandidates.reachable({}, [undef_c, user_c], [])
  suite.check('a name only undef calls reach is reported', undef_only == Set['module_function'])
  suite.check('one another native looks up is not', !undef_only.include?('new'))
  suite.check('an undef call still counts as a lookup for everything else', names.superset?(Set['new', 'module_function']))

  irep = Struct.new(:syms)
  core = [{ ireps: { 'top' => irep.new([]), 'top/1' => irep.new(%i[module_function]) } }]
  suite.check('a name a core Ruby irep holds (a nested one too) is not reported',
              CoreNativeCandidates.core_mentions?(core, 'module_function') && !CoreNativeCandidates.core_mentions?(core, 'new'))

  keys = CoreNativeCandidates.undef_candidates(map, names, Set.new, undef_only)
  suite.check('the undef only undef calls reach is a candidate, the looked-up one is not', keys == ['Class#module_function'])
  suite.check('a listing of methods keeps every undef',
              CoreNativeCandidates.undef_candidates(map, names | Set['instance_methods'], Set.new, undef_only).empty?)
  computed = map.dup.tap { |m| m.computed = Set['Class'] }
  suite.check('an owner with a computed-name registration keeps its undefs',
              CoreNativeCandidates.undef_candidates(computed, names, Set.new, undef_only).empty?)
end

lists = StaticDispatchLists.parse(JSON.generate(StaticDispatchLists::REQUIRED_KEYS.to_h { |k| [k, []] }.merge('digest' => 'x')))
suite.check('lists without core_undef_left_out read it as empty', lists.core_undef_left_out.empty?)

# The helpers as the generated code has them (codegen_emit.rb's template), compiled without the verify branch.
template = File.read(File.expand_path('../../tools/bc2cpp/codegen_emit.rb', __dir__))
helper = template[%r{^( *)// UNDEF_LEFT_OUT: removes.*?\n\1\[\[maybe_unused\]\] static void bc2cpp_left_out_undef.*?\n\1\}\n}m]
suite.check('the codegen template defines bc2cpp_left_out_undef', !helper.nil?)

runtime = Bc2cppFixtureRuntime
build = helper && ENV['CC_GENERATED_ONLY'] != '1' && runtime.compiler? ? runtime.full_or_build : nil
if build
  Dir.mktmpdir('undef-left-out-run') do |dir|
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      #include <mruby/class.h>
      #include <mruby/compile.h>
      #include <mruby/proc.h>
      #include <mruby/string.h>
      #include <cstdio>
      static void bc2cpp_left_out(mrb_state*, struct RClass*, const char*, mrb_bool) {}
      #{helper.gsub(/^#{helper[/\A */]}/, '')}
      static void run(mrb_state* M, const char* label, const char* code) {
        mrb_value v = mrb_load_string(M, code);
        if (M->exc) {
          std::printf("%s => raised %s\\n", label, mrb_obj_classname(M, mrb_obj_value(M->exc)));
          M->exc = nullptr;
          return;
        }
        mrb_value s = mrb_inspect(M, v);
        std::printf("%s => %.*s\\n", label, (int)RSTRING_LEN(s), RSTRING_PTR(s));
      }
      static struct RClass* cls(mrb_state* M, const char* name) { return mrb_class_get(M, name); }
      int main() {
        mrb_state* M = mrb_open();
        run(M, "setup", "class P; def m; 1; end; end; class C < P; undef_method :m; end; class D < P; end; class E < P; end;"
                       "class P2; def m; 2; end; undef_method :m; end; class F < P2; end; nil");
        std::puts("== kept");
        run(M, "program", "[C.new.class, D.new.m, C.new.respond_to?(:class)]");
        run(M, "C#m", "C.new.m");
        bc2cpp_left_out_undef(M, cls(M, "C"), "m", FALSE);
        bc2cpp_left_out_undef(M, cls(M, "D"), "m", FALSE);
        bc2cpp_left_out_undef(M, cls(M, "E"), "nothing", FALSE);
        bc2cpp_left_out_undef(M, cls(M, "F"), "m", FALSE);
        std::puts("== removed");
        run(M, "program", "[C.new.class, D.new.m, C.new.respond_to?(:class)]");
        run(M, "C#m", "C.new.m");
        run(M, "F#m", "F.new.m");
        mrb_close(M);
        return 0;
      }
    CPP
    flags = runtime.library_defines(build)
    exe = File.join(dir, 'main')
    out, status = Open3.capture2e('g++', '-std=gnu++17', *flags, "-I#{build}/include", File.join(dir, 'main.cpp'),
                                  File.join(build, 'lib/libmruby.a'), '-lm', '-o', exe)
    suite.check('the helper compiles against a full-core mruby', status.success?)
    warn out unless status.success?
    if status.success?
      out, = Open3.capture2e(exe)
      kept, removed = out.split("== removed\n")
      kept = kept.to_s.split("== kept\n").last.to_s
      program = ->(part) { part.lines.grep(/\Aprogram => /).first }
      suite.check('a program that does not look the name up prints the same with the undef as without it',
                  program.call(kept).to_s.include?('[C, 1, true]') && program.call(kept) == program.call(removed.to_s))
      suite.check('with the undef the name raises NoMethodError', kept.include?('C#m => raised NoMethodError'))
      suite.check('once removed the inherited method shows', removed.to_s.include?('C#m => 1'))
      suite.check('an own definition and an absent name are left alone (no NameError)', removed.to_s.include?('program => [C, 1, true]'))
      suite.check('an undef on an ancestor is not the owner\'s own and stays', removed.to_s.include?('F#m => raised NoMethodError'))
      warn out unless out.include?('C#m => 1') && out.include?('program => [C, 1, true]')
    end
  end
else
  puts '  SKIP run: no full-core mruby build or compiler'
end

suite.finish!
