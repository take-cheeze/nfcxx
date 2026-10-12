#!/usr/bin/env ruby
# encoding: UTF-8
# Check TYPED_SLOT_INTERPRETED_ACCESS: a typed embedded ivar (mrb_int, mrb_bool,
# mrb_sym) is a raw C field. So
#  - a typed ivar touched by a method that stays interpreted is demoted to a
#    plain :value slot (the interpreter then reads and writes it as an
#    mrb_value without paying the descriptor's boxing and type check);
#  - the descriptor table lists every slot with its kind, so the runtime boxes
#    a typed value for the ivar API and the GC marks :value slots only
#    (docs/adr/0261; scripts/bc2cpp/typed_reflection_check.rb runs it).
# A raw 0x10 read as an mrb_value made mrb_gc_mark dereference address 0x10,
# and a raw Integer read by the interpreter crashed optcarrot's PPU.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/typed_slot_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~'RUBY'
  class Clock
    def initialize
      @ticks = 0
      @count = 0
    end

    def bump
      @count = 1
    end

    # Fiber.new with a block is refused by bc2cpp, so this stays interpreted.
    def spin
      f = Fiber.new do
        @ticks = 1
        Fiber.yield
      end
      f.resume
    end
  end
RUBY

Dir.mktmpdir do |dir|
  path = File.join(dir, 'clock.rb')
  File.write(path, FIXTURE)
  ireps, root_label = compile_ireps(path, 'bc2cpp_typed_slot', dir)
  registry, superclass_of = build_registry(ireps, root_label)
  typed = IvarLayout.analyze(ireps, registry)
  layout = IvarLayout.all(ireps, registry).to_h do |klass, ivars|
    [klass, ivars.to_h { |name, fallback| [name, typed.dig(klass, name) || fallback] }]
  end
  check.call('fixture: both ivars are proven typed before the demotion',
             layout.dig('Clock', 'ticks') == :fixnum && layout.dig('Clock', 'count') == :fixnum)

  gen = CodeGen.new(ireps, registry, layout, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new)
  spin = registry.fetch('spin').find { |d| d.owner == 'Clock' }
  check.call('fixture: Clock#spin does not compile', !gen.compiles_clean?(spin.irep))
  check.call('an ivar touched by an interpreted method becomes a :value slot',
             gen.embed_type('Clock', 'ticks') == :value)
  check.call('an ivar only compiled methods touch stays typed', gen.embed_type('Clock', 'count') == :fixnum)

  structs = gen.emit_structs
  slots = structs[/Clock_ivar_slots\[\] = \{\n(.*?)\n\};/m, 1].to_s
  check.call('the descriptor lists the :value slot',
             slots.include?('{ "@ticks", offsetof(Clock_ivars, ivar_ticks), MRB_DATA_IVAR_VALUE }'))
  check.call('the descriptor lists the typed slot with its kind',
             slots.include?('{ "@count", offsetof(Clock_ivars, ivar_count), MRB_DATA_IVAR_INT }'))
  check.call('the descriptor count matches', structs.include?('Clock_ivar_slots, 2, sizeof'))
end

puts '-- descriptor consumers: slot table, payload size, initial values, reflection'
REFLECT_FIXTURE = <<~'RUBY'
  class Mixed
    def initialize
      @count = 0
      @name = "n"
    end

    def bump
      @count = 1
    end

    # Reflection reaches @count through the runtime ivar API, not the payload.
    def reflect
      instance_variable_get(:@count)
    end

    def copy
      dup
    end

    def label
      "#{@name}#{@count}"
    end
  end

  class OnlyTyped
    def initialize
      @hits = 0
      @armed = true
    end

    def hit
      @hits = 1
    end
  end
RUBY

Dir.mktmpdir do |dir|
  path = File.join(dir, 'mixed.rb')
  File.write(path, REFLECT_FIXTURE)
  ireps, root_label = compile_ireps(path, 'bc2cpp_typed_slot_reflect', dir)
  registry, superclass_of = build_registry(ireps, root_label)
  typed = IvarLayout.analyze(ireps, registry)
  layout = IvarLayout.all(ireps, registry).to_h do |klass, ivars|
    [klass, ivars.to_h { |name, fallback| [name, typed.dig(klass, name) || fallback] }]
  end
  gen = CodeGen.new(ireps, registry, layout, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new)
  check.call('fixture: Mixed has typed and boxed ivars',
             gen.embed_type('Mixed', 'count') == :fixnum && gen.embed_type('Mixed', 'name') == :value)
  check.call('fixture: OnlyTyped has no boxed ivar',
             gen.embed_type('OnlyTyped', 'hits') == :fixnum && gen.embed_type('OnlyTyped', 'armed') == :bool)

  structs = gen.emit_structs
  mixed = structs[/struct Mixed_ivars \{\n(.*?)\n\};/m, 1].to_s
  check.call('the payload keeps a raw field for a typed ivar', mixed.include?('mrb_int ivar_count;'))
  check.call('the payload keeps an mrb_value for a boxed ivar', mixed.include?('mrb_value ivar_name;'))
  mixed_slots = structs[/Mixed_ivar_slots\[\] = \{\n(.*?)\n\};/m, 1].to_s
  check.call('a boxed slot is addressed by offsetof into the payload',
             mixed_slots.include?('{ "@name", offsetof(Mixed_ivars, ivar_name), MRB_DATA_IVAR_VALUE }'))
  check.call('a typed ivar read through reflection is in the table, with its kind',
             mixed_slots.include?('{ "@count", offsetof(Mixed_ivars, ivar_count), MRB_DATA_IVAR_INT }'))
  check.call('the copy size covers the typed fields too',
             structs.include?('Mixed_ivar_slots, 2, sizeof(Mixed_ivars)'))

  only_slots = structs[/OnlyTyped_ivar_slots\[\] = \{\n(.*?)\n\};/m, 1].to_s
  check.call('an all-typed owner carries a descriptor listing its typed slots',
             structs.include?('OnlyTyped_ivar_slots, 2, sizeof(OnlyTyped_ivars)') &&
               only_slots.include?('MRB_DATA_IVAR_INT }') && only_slots.include?('MRB_DATA_IVAR_BOOL }'))
  check.call('the payload free function tolerates a NULL payload',
             structs.match?(/static void Mixed_ivars_free\(mrb_state\* mrb, void\* p\) \{\n  if \(!p\) return;/))

  # RDATA_IVAR_HASH: the emitted index must find every listed slot the way
  # rdata_ivar_find (patches/mruby-rdata-ivar-slots.patch) probes it.
  fnv = lambda do |name|
    name.each_byte.reduce(2_166_136_261) { |h, byte| ((h ^ byte) * 16_777_619) & 0xffff_ffff }
  end
  probe = lambda do |table, names, name|
    pos = fnv.call(name) & (table.size - 1)
    until table[pos] == 0xFFFF
      return table[pos] if names[table[pos]] == name

      pos = (pos + 1) & (table.size - 1)
    end
    nil
  end
  patch = File.read(File.join(__dir__, '../../patches/mruby-rdata-ivar-slots.patch'))
  check.call('the patch hashes with the constants the generator uses',
             patch.include?('2166136261u') && patch.include?('16777619u'))
  crowded = (0...40).map { |i| "@slot#{i}" }
  table = gen.rdata_ivar_hash(crowded)
  check.call('the index is at most half full', table.count { |e| e != 0xFFFF } * 2 <= table.size)
  check.call('every slot of a crowded table is found at its own index',
             crowded.each_with_index.all? { |name, i| probe.call(table, crowded, name) == i })
  check.call('a name that is not a slot is not found', probe.call(table, crowded, '@other').nil?)
  check.call('the emitted type carries the hash table and its mask',
             structs.include?('Mixed_ivar_slots, 2, sizeof(Mixed_ivars), Mixed_ivar_hash, 3 };') &&
             structs.include?('static const uint16_t Mixed_ivar_hash[] = {') &&
             structs.include?('OnlyTyped_ivar_slots, 2, sizeof(OnlyTyped_ivars), OnlyTyped_ivar_hash, 3 };'))

  init = registry.fetch('initialize').find { |d| d.owner == 'Mixed' }
  init_code = gen.compile_method(init.irep)[:code]
  check.call('a boxed field starts undef, so GC marking and reads see an unset ivar',
             init_code.include?('embedded->ivar_name = mrb_undef_value();'))
  check.call('a typed field starts zeroed and is never given a boxed value',
             init_code.include?('embedded->ivar_count = {};'))
  check.call('initialize installs the payload and its descriptor type',
             init_code.include?('mrb_data_init(self, embedded, &Mixed_ivars_type);'))
end

puts '-- probe compiles must not leave lazily created state behind'
Dir.mktmpdir do |dir|
  path = File.join(dir, 'plain.rb')
  File.write(path, "class Plain\n  def go; 1; end\nend\n")
  ireps, root_label = compile_ireps(path, 'bc2cpp_probe_state', dir)
  registry, superclass_of = build_registry(ireps, root_label)
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new)
  gen.instance_variable_set(:@clean_cache, { 'kept' => true })
  gen.send(:without_probe_side_effects) do
    gen.instance_variable_set(:@lazy_probe_state, [1])
    gen.instance_variable_set(:@const_lookup_helper_used, true)
    gen.instance_variable_get(:@clean_cache)['probe'] = false
  end
  check.call('an ivar first created by the probe is removed again', !gen.instance_variable_defined?(:@lazy_probe_state))
  check.call('a flag the probe set is rolled back', !gen.const_lookup_helper_used?)
  check.call('the memoized clean answers survive the probe',
             gen.instance_variable_get(:@clean_cache) == { 'kept' => true, 'probe' => false })
end

puts '-- rgss:: wrappers need mruby-rgss/src in the build'
Dir.mktmpdir do |dir|
  path = File.join(dir, 'plain.rb')
  File.write(path, "class Plain\n  def go; 1; end\nend\n")
  ireps, root_label = compile_ireps(path, 'bc2cpp_rgss_gate', dir)
  registry, superclass_of = build_registry(ireps, root_label)
  # Array#clear from mruby core registers the same name as RGSS::Bitmap#clear.
  registry['clear'] << MethodDef.new(name: 'clear', owner: '<native>', irep: nil, visibility: :public)
  build = lambda do |sources|
    CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new,
                nil, nil, { 'clear' => sources })
  end
  check.call('core-only natives do not select the RGSS Bitmap#clear wrapper',
             !build.call(['3rd/mruby/src/array.c']).native_wrapper_owner_safe?('clear', 'RGSS::Bitmap'))
  check.call('an mruby-rgss/src registration does',
             build.call(['mruby-rgss/src/lib.cxx']).native_wrapper_owner_safe?('clear', 'RGSS::Bitmap'))
end

abort "#{failures.size} check(s) failed" unless failures.empty?
puts 'ok'
