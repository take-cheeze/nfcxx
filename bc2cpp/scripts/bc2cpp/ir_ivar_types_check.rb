#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
TOOLS = ENV['BC2CPP_TOOLS_DIR'] || File.join(ROOT, 'tools/bc2cpp')
$LOAD_PATH.unshift(TOOLS)
require 'ir_ivar_types'
require 'numeric_flow'

failures = []
check = lambda do |label, condition|
  puts "#{condition ? 'ok' : 'FAIL'} #{label}"
  failures << label unless condition
end

# A fake settled compiler isolates admission gates from producer analysis.
fake_class = Class.new do
  attr_accessor :assured
  def numeric_family(owner) = owner
  def numeric_ivar_assured?(_owner, _name) = assured
  def numeric_irep_owner = {}
  def bytecode_ir_mask_classes(mask)
    return nil if mask.anybits?(NumericFlow::OTHER | NumericFlow::EXC | NumericFlow::CHECKED)

    classes = Set.new
    classes << :Integer if mask.anybits?(NumericFlow::INT)
    classes << :String if mask.anybits?(NumericFlow::STR)
    classes << :NilClass if mask.anybits?(NumericFlow::NIL)
    classes.empty? ? nil : classes
  end
end
gen = fake_class.new
group = Struct.new(:structural, :readers).new(false, [])
world = Struct.new(:exact_instances_singleton_free?).new(true)
gen.instance_variable_set(:@class_pools_on, true)
gen.instance_variable_set(:@foreign_method_names, Set.new)
gen.instance_variable_set(:@native_results_ready, true)
gen.instance_variable_set(:@rc_scoped_ready, true)
gen.instance_variable_set(:@closed_world, world)
gen.instance_variable_set(:@numeric_ivar_groups, { ['Example', 'slot'] => group })
pools = { ['Example', 'slot'] => NumericFlow::INT | NumericFlow::STR }
gen.instance_variable_set(:@class_ivar_pools, pools)
check.call('all-store union includes uninitialized nil', IrIvarTypes.classes(gen, 'Example', 'slot') == Set[:Integer, :String, :NilClass])
gen.assured = true
check.call('constructor assurance excludes uninitialized nil', IrIvarTypes.classes(gen, 'Example', 'slot') == Set[:Integer, :String])
[NumericFlow::OTHER, NumericFlow::EXC, NumericFlow::CHECKED].each do |poison|
  pools[['Example', 'slot']] = NumericFlow::INT | poison
  check.call("unproven pool bits #{poison} refuse", IrIvarTypes.classes(gen, 'Example', 'slot').nil?)
end
pools[['Example', 'slot']] = NumericFlow::INT
group.structural = true
check.call('foreign/reflection structural poison refuses', IrIvarTypes.classes(gen, 'Example', 'slot').nil?)
group.structural = false
pools.delete(['Example', 'slot'])
check.call('a dropped pool never falls back to a single store', IrIvarTypes.classes(gen, 'Example', 'slot').nil?)
pools[['Example', 'slot']] = NumericFlow::INT
gen.instance_variable_set(:@native_results_ready, false)
check.call('unsettled compiler refuses', IrIvarTypes.classes(gen, 'Example', 'slot').nil?)
gen.instance_variable_set(:@native_results_ready, true)
world[0] = false
check.call('singleton-mutated or open world refuses', IrIvarTypes.classes(gen, 'Example', 'slot').nil?)
world[0] = true
gen.instance_variable_set(:@numeric_ivar_disabled, true)
check.call('disabled ivar admission refuses', IrIvarTypes.classes(gen, 'Example', 'slot').nil?)
gen.instance_variable_set(:@numeric_ivar_disabled, false)
gen.instance_variable_set(:@class_pools_on, false)
check.call('disabled class pools refuse', IrIvarTypes.classes(gen, 'Example', 'slot').nil?)

source = <<~RUBY
  class IrPoolField
    def initialize(flag)
      @union_field = flag ? 1 : "one"
      @before_field = @constructed_field
      @constructed_field = flag ? 5 : "yes"
    end
    def later(flag)
      @nullable_field = flag ? 2 : "two"
    end
    def opaque_writer(value)
      @opaque_field = value
    end
    def known_writer
      @opaque_field = 3
      @reflected_field = 4
    end
    def reflective_writer
      instance_variable_set(:@reflected_field, "four")
    end
    def read_fields
      [@union_field, @nullable_field, @constructed_field, @opaque_field, @reflected_field]
    end
  end
  IrPoolField.new(true).later(false)
RUBY
Dir.mktmpdir('ir-ivar-types-check') do |dir|
  File.write(File.join(dir, 'fields.rb'), source)
  Dir.mkdir(File.join(dir, 'sig'))
  command = [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/type_check.rb'), '--format', 'json', '--no-sends', '--sig', File.join(dir, 'sig'), '--files', 'fields.rb']
  reports = {}
  %w[1 0].each do |mode|
    env = { 'BC2CPP_TOOLS_DIR' => TOOLS, 'BC2CPP_IR_IVAR_TYPES' => mode }
    out, err, status = Open3.capture3(env, *command, chdir: dir)
    abort "ivar analysis failed: #{err}\n#{out}" unless status.success?

    reports[mode] = JSON.parse(out)['ivars'].to_h { |row| [row['name'], row] }
  end
  row = reports['1']['@union_field']
  check.call('real settled field union is independently reported', row && row['type'] == 'Integer | String' && row['source'] == 'inferred:ivar-class-pool')
  check.call('field assigned after construction preserves nil', reports['1']['@nullable_field']['type'].split(' | ').to_set == Set['Integer', 'String', 'nil'])
  check.call('initializer read preserves nil even with assignment assurance', reports['1']['@constructed_field']['type'].include?('nil'))
  check.call('one opaque write poisons the entire field', reports['1']['@opaque_field']['type'].nil?)
  check.call('reflective write does not become an independent pool proof', reports['1']['@reflected_field']['source'] != 'inferred:ivar-class-pool')
  check.call('opt-out preserves previous unresolved union row', reports['0']['@union_field']['type'].nil?)
end

abort "#{failures.length} ivar-type checks failed" unless failures.empty?
puts 'ir ivar types: all checks passed'
