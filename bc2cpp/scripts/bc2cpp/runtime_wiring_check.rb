#!/usr/bin/env ruby
# encoding: UTF-8
# Check the runtime wiring bc2cpp emits for the desktop RPGMAKER_BC2CPP build:
#
#   INSTANCE_TT_SETUP  every embedding class gets MRB_TT_DATA from the emitted
#                      setup function (it used to be a hand-kept list that
#                      drifted: 20 classes embedded, 9 wired), and a class that
#                      is not defined yet is skipped and picked up by a later
#                      call.
#   VM_UNWIND_RESTORE  every catch site for the generator's own C++ unwinds
#                      (bc2cpp_block_break / bc2cpp_method_return) restores the
#                      VM's jmp/callinfo state, which mruby's own catch never
#                      does for a foreign exception type.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'cxx'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# --- INSTANCE_TT_SETUP -------------------------------------------------------
layout = {
  'RPG2k' => { '@a' => 'fixnum' },
  'RPG2k::Scene::Menu' => { '@b' => 'fixnum' },
  'Game::Actor' => { '@c' => 'fixnum' },
  'Game::Late' => { '@d' => 'fixnum' },
}
gen = CodeGen.new({}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
# Set directly: drop_unsafe_embeddings would filter a synthetic layout out.
gen.instance_variable_set(:@ivar_layout, layout)
setup = gen.emit_instance_tt_setup
gen.embedding_classes.each do |klass|
  segments = klass.split('::').map { |seg| "\"#{seg}\"" }.join(', ')
  check.call("setup lists #{klass}", setup.include?("{ #{segments}, nullptr }"))
end
check.call('setup never lists a module-only path', !setup.include?('{ "Scene", nullptr }'))

Dir.mktmpdir do |dir|
  harness = File.join(dir, 'tt_harness.cpp')
  File.write(harness, <<~CPP)
    #include <cstdio>
    #include <cstring>
    #include <map>
    #include <string>
    enum { MRB_TT_CLASS = 1, MRB_TT_MODULE = 2, MRB_TT_DATA = 9 };
    struct RClass { int tt; int flags; std::map<std::string, RClass*> consts; };
    #define MRB_SET_INSTANCE_TT(c, tt) ((c)->flags = (tt))
    typedef const char* mrb_sym;
    struct mrb_value { RClass* p; };
    struct mrb_state { RClass* object_class; };
    static mrb_value mrb_obj_value(RClass* c) { return { c }; }
    static mrb_sym mrb_intern_cstr(mrb_state*, const char* s) { return s; }
    static bool mrb_const_defined_at(mrb_state*, mrb_value m, mrb_sym s) { return m.p->consts.count(s) != 0; }
    static mrb_value mrb_const_get(mrb_state*, mrb_value m, mrb_sym s) { return { m.p->consts[s] }; }
    static int mrb_type(mrb_value v) { return v.p->tt; }
    static RClass* mrb_class_ptr(mrb_value v) { return v.p; }
    #{setup}
    static RClass* mk(RClass* parent, const char* name, int tt) {
      RClass* c = new RClass{ tt, 0, {} };
      parent->consts[name] = c;
      return c;
    }
    int main() {
      RClass object = { MRB_TT_CLASS, 0, {} };
      mrb_state M = { &object };
      RClass* rpg2k = mk(&object, "RPG2k", MRB_TT_CLASS);
      RClass* scene = mk(rpg2k, "Scene", MRB_TT_MODULE);
      RClass* menu = mk(scene, "Menu", MRB_TT_CLASS);
      RClass* game = mk(&object, "Game", MRB_TT_MODULE);
      bc2cpp_set_instance_tts(&M);  // Game::Actor and Game::Late are not defined yet
      int first = rpg2k->flags == MRB_TT_DATA && menu->flags == MRB_TT_DATA && scene->flags == 0 && game->flags == 0;
      RClass* actor = mk(game, "Actor", MRB_TT_CLASS);
      bc2cpp_set_instance_tts(&M);  // a later call picks up a class defined in between
      int late = actor->flags == MRB_TT_DATA;
      bc2cpp_set_instance_tts(&M);  // idempotent
      std::printf("%d %d %d\\n", first, late, actor->flags == MRB_TT_DATA && menu->flags == MRB_TT_DATA);
    }
  CPP
  binary = File.join(dir, 'tt_harness')
  built = Bc2cppCxx.system('-std=c++17', '-Wall', '-Werror', harness, '-o', binary)
  check.call('the emitted setup compiles cleanly', built)
  if built
    first, late, again = IO.popen(binary, &:read).split.map { |v| v == '1' }
    check.call('present classes get MRB_TT_DATA and modules are left alone', first)
    check.call('a class defined after the first call is picked up by the next', late)
    check.call('repeated calls are idempotent', again)
  end
end

# --- VM_UNWIND_RESTORE -------------------------------------------------------
SRC = <<~'RUBY'
  class Finder
    def first_big(list)
      list.each { |x| return x if x > 1 }
      nil
    end

    def each_break(list)
      list.each { |x| break x if x > 1 }
    end
  end
RUBY

Dir.mktmpdir do |dir|
  source = File.join(dir, 'unwind.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_unwind', dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  unwind_gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code = registry.values.flatten.filter_map do |md|
    next unless md.irep && md.owner == 'Finder'

    unwind_gen.compile_method(md.irep).fetch(:code)
  end.join("\n")
  check.call('the fixture compiled both unwinding shapes',
             code.include?('catch (bc2cpp_method_return&') && code.include?('catch (bc2cpp_block_break&'))
  check.call('a method-level return catch restores the VM state before returning',
             code.scan(/bc2cpp_vm_restore\(M, bc2cpp_ret_mark\);\n\s+return bc2cpp_ret\.value;/).size == 1 &&
               code.include?('Bc2cppVmMark bc2cpp_ret_mark = bc2cpp_vm_mark(M);'))
  check.call('a break glue restores the VM state before using the value',
             code.scan(/bc2cpp_vm_restore\(M, bc2cpp_brk_mark\);\n\s+r\d+ = bc2cpp_brk\.value;/).size >= 1 &&
               code.include?('Bc2cppVmMark bc2cpp_brk_mark = bc2cpp_vm_mark(M);'))
  check.call('no catch site skips the restore',
             code.scan('catch (bc2cpp_').size == code.scan('bc2cpp_vm_restore(M,').size)
end

# --- ARRAY2_OPERAND_FORM ------------------------------------------------------
# `local = [literal]` is one 3-operand `ARRAY Rd Rs N` instruction in the pinned
# mruby; it used to compile to an empty Array.
ARRAY_SRC = <<~'RUBY'
  class Grid
    def build
      quarters = [[nil, nil], [nil, nil]]
      quarters
    end

    def pair(a, b)
      out = [a, b]
      out
    end
  end
RUBY

Dir.mktmpdir do |dir|
  source = File.join(dir, 'array_operand.rb')
  File.write(source, ARRAY_SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_array_operand', dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  array_gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code_of = lambda do |name|
    md = registry.fetch(name).find { |d| d.owner == 'Grid' }
    array_gen.compile_method(md.irep).fetch(:code)
  end
  build = code_of.call('build')
  check.call('a three-operand ARRAY builds the outer literal from its source registers',
             build.match?(/elems\[\] = \{ r(\d+), r(\d+) \};\n\s+r\d+ = mrb_ary_new_from_values\(M, 2, elems\)/) &&
               build.scan('mrb_ary_new_from_values(M, 2, elems)').size == 3)
  check.call('no non-empty array literal compiles to an empty Array', !build.match?(/r\d+ = mrb_ary_new\(M\);/))
  pair = code_of.call('pair')
  check.call('a local built from two parameters keeps both elements', pair.include?('mrb_ary_new_from_values(M, 2, elems)'))
end

if failures.empty?
  puts 'bc2cpp runtime wiring check: PASS'
else
  warn "bc2cpp runtime wiring check: #{failures.size} failure(s)"
  exit 1
end
