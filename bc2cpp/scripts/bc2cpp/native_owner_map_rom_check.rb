#!/usr/bin/env ruby
# frozen_string_literal: true

# NativeOwnerMap on an engine gem's ROM method tables (the form mruby-rgss registers its natives in): the class comes
# through a function parameter, a class object's table is a singleton, a table is kept apart from the heap
# registrations a left-out removal may delete, and mruby's own sources are read as before.
#
#   ruby scripts/bc2cpp/native_owner_map_rom_check.rb

require 'fileutils'
require 'tmpdir'
require_relative '../../tools/bc2cpp/world_root'
require_relative '../../tools/bc2cpp/native_owner_map'
require_relative '../../tools/bc2cpp/native_singletons'
require_relative '../../tools/bc2cpp/touch_scan'
require_relative '../../tools/bc2cpp/closed_world'

failures = []
check = lambda do |name, ok|
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end

ENGINE = <<~'C'
  static const mrb_func_t shared_tmpl = data_init_copy<Rect>;
  static void define_rect(mrb_state* M, RClass* rect) {
    static const mrb_mt_entry rect_methods[] = {
      MRB_MT_ENTRY(rect_init, MRB_SYM(initialize), MRB_ARGS_OPT(4) | MRB_MT_PRIVATE)
      MRB_MT_ENTRY(rect_empty_p, MRB_SYM_Q(empty), MRB_ARGS_NONE())
      MRB_MT_ENTRY(shared_tmpl, MRB_SYM(initialize_copy), MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)
    };
    MRB_MT_INIT_ROM(M, rect, rect_methods);
    static const mrb_mt_entry rect_class_methods[] = {
      MRB_MT_ENTRY(rect_load, MRB_SYM(_load), MRB_ARGS_REQ(1))
    };
    MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(rect)), rect_class_methods);
  }
  void init(mrb_state* M) {
    RClass* rgss = mrb_module_get(M, "RGSS");
    RClass* rect = mrb_define_class_under(M, rgss, "Rect", M->object_class);
    define_rect(M, rect);
    mrb_define_method(M, rect, "heap_only", rect_heap, MRB_ARGS_NONE());
  }
C

Dir.mktmpdir do |dir|
  engine = File.join(dir, 'mruby-rgss/src/lib.cxx')
  FileUtils.mkdir_p(File.dirname(engine))
  File.write(engine, ENGINE)
  map = NativeOwnerMap.build([engine])

  check.call('a table installed through a class parameter is the parameter-bound class',
             map.rom.include?(['RGSS::Rect', 'empty?', 'rect_empty_p']))
  check.call("a class object's table is the singleton", map.rom.include?(['RGSS::Rect.singleton', '_load', 'rect_load']))
  check.call('an alias constant is the entry function', map.rom.include?(['RGSS::Rect', 'initialize_copy', 'shared_tmpl']))
  check.call('ROM entries are listed by name and owner',
             map.by_name['empty?'] == Set['RGSS::Rect'] && map.by_name['_load'] == Set['RGSS::Rect.singleton'])
  check.call('only an instance table is an instance entry',
             map.instance.include?(['RGSS::Rect', 'empty?', false]) && map.instance.none? { |_o, n, _c| n == '_load' })
  check.call('a ROM entry is no heap registration (a left-out removal would add a tombstone)',
             map.registrations.map { |_o, n, _f| n } == ['heap_only'])
  check.call('definitions are the registrations and the ROM entries',
             map.definitions.map { |_o, n, _f| n }.sort == %w[_load empty? heap_only initialize initialize_copy])
  check.call('no entry is left unattributed', !map.by_name.values.any? { |owners| owners.include?(NativeOwnerMap::UNKNOWN) })
  inline = File.join(dir, 'mruby-rgss/src/inline.cxx')
  File.write(inline, <<~'C')
    void init(mrb_state* M) {
      RClass* rgss = mrb_define_module(M, "RGSS");
      RClass* gfx = mrb_define_module_under(M, rgss, "Graphics");
      static const mrb_mt_entry gfx_fns[] = { MRB_MT_ENTRY(gfx_snap, MRB_SYM(snap), MRB_ARGS_NONE()) };
      MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(gfx)), gfx_fns);
      static const mrb_mt_entry gfx_inst[] = { MRB_MT_ENTRY(gfx_open, MRB_SYM(open), MRB_ARGS_NONE()) };
      MRB_MT_INIT_ROM(M, gfx, gfx_inst);
    }
  C
  check.call("NativeSingletons reads a class object's table as the singleton registration",
             NativeSingletons.unique_singleton?('snap', 'RGSS::Graphics', [inline]))
  check.call('NativeSingletons does not read an instance entry as a singleton registration',
             !NativeSingletons.unique_singleton?('open', 'RGSS::Graphics', [inline]))
  facts = TouchScan.native_facts(NativeDirect.strip_comments(ENGINE))
  check.call("a class object's table is no singleton-class touch event", facts.none? { |kind, *| kind.to_s.start_with?('singleton_class') })
end

Dir.mktmpdir do |dir|
  core = File.join(dir, '3rd/mruby/src/thing.c')
  FileUtils.mkdir_p(File.dirname(core))
  File.write(core, <<~'C')
    static const mrb_mt_entry thing_rom_entries[] = {
      MRB_MT_ENTRY(thing_one, MRB_SYM(one), MRB_ARGS_NONE())
    };
    void mrb_init_thing(mrb_state *mrb)
    {
      struct RClass *k = mrb_define_class_id(mrb, MRB_SYM(Thing), mrb->object_class);
      MRB_MT_INIT_ROM(mrb, k, thing_rom_entries);
    }
  C
  map = NativeOwnerMap.build([core])
  check.call("mruby's own tables add no ROM rows (NativeRomOwners reads them)", map.rom.empty?)
  check.call("mruby's own tables keep their owner", map.by_name['one'] == Set['Thing'])
end

# A ROM entry's MRB_SYM(blt) names a method: a `mrb_sym blt` local dispatched through is still one spelled name, so the
# source does not open every module's includers.
local_sym = <<~'C'
  void draw(mrb_state* M, mrb_value canvas) {
    const mrb_sym blt = mrb_intern_lit(M, "blt");
    mrb_funcall_argv(M, canvas, blt, 0, nullptr);
  }
  static const mrb_mt_entry bmp_methods[] = {
    MRB_MT_ENTRY(bmp_blt, MRB_SYM(blt), MRB_ARGS_NONE())
  };
C
check.call('a local method name is resolved beside a ROM entry of the same name',
           ClosedWorld.native_local_symbols(local_sym) == { 'blt' => ['blt'] })

if failures.empty?
  puts 'bc2cpp native owner map rom check: PASS'
else
  warn "bc2cpp native owner map rom check: #{failures.size} failure(s)"
  exit 1
end
