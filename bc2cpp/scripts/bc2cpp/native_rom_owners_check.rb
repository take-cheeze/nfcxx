#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks tools/bc2cpp/native_rom_owners.rb: the class each MRB_MT_ENTRY table is installed on. Inline fixtures cover
# each binding form the resolver accepts and the forms it must refuse; the last case reads mruby's own numeric.c
# when the submodule is checked out.
#
#   ruby scripts/bc2cpp/native_rom_owners_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/native_rom_owners'

failures = []
check = lambda do |name, ok|
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end

def table(name, owner, install_expr, prelude)
  <<~C
    static const mrb_mt_entry #{name}_rom_entries[] = {
      MRB_MT_ENTRY(fn_one, MRB_SYM(to_s), MRB_ARGS_NONE()),
    };
    void init(mrb_state *mrb)
    {
      #{prelude}
      MRB_MT_INIT_ROM(mrb, #{install_expr}, #{name}_rom_entries);
    }
  C
end

def owner_of_source(source)
  NativeRomOwners.analyze(source)[:tables].values.first[:owner]
end

check.call('define_class_id with a symbol name', owner_of_source(table('x', nil, 'k', 'struct RClass *k = mrb_define_class_id(mrb, MRB_SYM(Thing), mrb->object_class);')) == 'Thing')
check.call('define_class with a string name', owner_of_source(table('x', nil, 'k', 'struct RClass *k = mrb_define_class(mrb, "Other", mrb->object_class);')) == 'Other')
check.call('define_module_id (Kernel-style)', owner_of_source(table('x', nil, 'k', 'k = mrb_define_module_id(mrb, MRB_SYM(Mod));')) == 'Mod')
check.call('chained mrb-> field assignment', owner_of_source(table('x', nil, 'k', 'struct RClass *k = mrb->eX_class = mrb_define_class_id(mrb, MRB_SYM(Ex), mrb->object_class);')) == 'Ex')
check.call('install through mrb_class_get_id', owner_of_source(table('x', nil, 'mrb_class_get_id(mrb, MRB_SYM(Base))', '')) == 'Base')
check.call('core field read (mrb->integer_class)', owner_of_source(table('x', nil, 'k', 'struct RClass *k = mrb->integer_class;')) == 'Integer')
check.call('one-level variable copy', owner_of_source(table('x', nil, 'k', "struct RClass *j = mrb_define_class_id(mrb, MRB_SYM(Copy), mrb->object_class);\n  struct RClass *k = j;")) == 'Copy')
check.call('naming call resolves a boot helper', owner_of_source(table('x', nil, 'k', "k = boot_defclass(mrb, 0);\n  mrb_class_name_class(mrb, NULL, k, MRB_SYM(Named));")) == 'Named')
check.call('unknown source is refused', owner_of_source(table('x', nil, 'k', 'k = make_thing(mrb);')) == NativeRomOwners::UNKNOWN)
check.call('a class defined under an outer class is refused',
           owner_of_source(table('x', nil, 'k', 'struct RClass *k = mrb_define_class_under_id(mrb, outer, MRB_SYM(In), mrb->object_class);')) == NativeRomOwners::UNKNOWN)
check.call('a class defined under a resolved outer class is Outer::Name',
           owner_of_source(table('x', nil, 'k', "struct RClass *o = mrb_define_class_id(mrb, MRB_SYM(Out), mrb->object_class);\n  " \
                                                 'struct RClass *k = mrb_define_class_under_id(mrb, o, MRB_SYM(In), mrb->object_class);')) == 'Out::In')
check.call('a class defined under Object is the top-level name',
           owner_of_source(table('x', nil, 'k', 'struct RClass *k = mrb_define_class_under(mrb, mrb->object_class, "Top", mrb->object_class);')) == 'Top')
check.call("a class object's singleton is Name.singleton",
           owner_of_source(table('x', nil, 'mrb_singleton_class_ptr(mrb, mrb_obj_value(k))',
                                 'struct RClass *k = mrb_define_class_id(mrb, MRB_SYM(Solo), mrb->object_class);')) == 'Solo.singleton')
check.call("a core field's singleton is its class's .singleton",
           owner_of_source(table('x', nil, 'mrb_singleton_class_ptr(mrb, mrb_obj_value(mrb->kernel_module))', '')) == 'Kernel.singleton')
check.call("the main object's singleton is Object, as NativeOwnerMap records main's methods",
           owner_of_source(table('x', nil, 'mrb_singleton_class_ptr(mrb, mrb_obj_value(mrb->top_self))', '')) == 'Object')
check.call('the singleton of an unresolved class is refused',
           owner_of_source(table('x', nil, 'mrb_singleton_class_ptr(mrb, mrb_obj_value(k))', 'k = make_thing(mrb);')) == NativeRomOwners::UNKNOWN)
check.call('the singleton of a computed object is refused',
           owner_of_source(table('x', nil, 'mrb_singleton_class_ptr(mrb, mrb_obj_value(pick(mrb)))', '')) == NativeRomOwners::UNKNOWN)
Dir.mktmpdir('native_rom_owners') do |dir|
  path = File.join(dir, 'solo.c')
  File.write(path, table('x', nil, 'mrb_singleton_class_ptr(mrb, mrb_obj_value(k))',
                         'struct RClass *k = mrb_define_class_id(mrb, MRB_SYM(Solo), mrb->object_class);'))
  map = NativeOwnerMap.build([path])
  check.call('a singleton table names its owner by name', map.by_name['to_s'].to_a == ['Solo.singleton'])
  check.call('a singleton table is not on an instance lookup path', map.instance.none? { |_, name, _| name == 'to_s' })
end
suffixed = "static const mrb_mt_entry s_rom_entries[] = {\n  MRB_MT_ENTRY(f_b, MRB_SYM_B(exit), 0)\n  MRB_MT_ENTRY(f_q, MRB_SYM_Q(empty), 0)\n" \
           "  MRB_MT_ENTRY(f_e, MRB_SYM_E(name), 0)\n  MRB_MT_ENTRY(f_p, MRB_OPSYM(plus), 0)\n};\n"
check.call('suffixed symbols keep their suffix; an operator keeps its presym name',
           NativeRomOwners.analyze(suffixed)[:tables]['s_rom_entries'][:entries] == [%w[f_b exit!], %w[f_q empty?], %w[f_e name=], %w[f_p plus]])
check.call('entries are read with their function and name',
           NativeRomOwners.analyze(table('x', nil, 'k', 'k = mrb_define_class_id(mrb, MRB_SYM(T), mrb->object_class);'))[:tables]['x_rom_entries'][:entries] == [%w[fn_one to_s]])

numeric = File.expand_path('../../3rd/mruby/src/numeric.c', __dir__)
if File.file?(numeric)
  tables = NativeRomOwners.analyze_file(numeric)[:tables]
  check.call('numeric.c: integer_rom_entries is Integer', tables['integer_rom_entries'][:owner] == 'Integer')
  check.call('numeric.c: float_rom_entries is Float', tables['float_rom_entries'][:owner] == 'Float')
  check.call('numeric.c: numeric_rom_entries is Numeric', tables['numeric_rom_entries'][:owner] == 'Numeric')
  socket = File.expand_path('../../3rd/mruby/mrbgems/mruby-socket/src/socket.c', __dir__)
  options = File.file?(socket) && NativeRomOwners.analyze_file(socket)[:tables]['socket_option_rom_entries']
  check.call('socket.c: socket_option_rom_entries is Socket::Option', options && options[:owner] == 'Socket::Option')
  class_tables = NativeRomOwners.analyze_file(File.expand_path('../../3rd/mruby/src/class.c', __dir__))[:tables]
  if class_tables.key?('cls_s_rom_entries')
    check.call('class.c: cls_s_rom_entries is Class.singleton', class_tables['cls_s_rom_entries'][:owner] == 'Class.singleton')
    check.call('class.c: top_self_rom_entries is Object', class_tables['top_self_rom_entries'][:owner] == 'Object')
  end
else
  puts 'skip numeric.c (3rd/mruby not checked out)'
end

if failures.empty?
  puts 'native rom owners: all checks passed'
else
  puts "native rom owners: #{failures.size} failed"
  exit 1
end
