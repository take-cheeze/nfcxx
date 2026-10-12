#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require 'rbconfig'
require_relative '../../tools/optcarrot_probe/ppu_lut'

path = File.expand_path('../../3rd/optcarrot/lib/optcarrot/ppu.rb', __dir__)
source = File.read(path)
transformed = OptcarrotPPULUT.transform(source)
original_table = Module.new.module_eval(OptcarrotPPULUT::ORIGINAL)
optimized_table = Module.new.module_eval(OptcarrotPPULUT::REPLACEMENT)
raise 'tile table contents changed' unless original_table == optimized_table
expected = source.sub(OptcarrotPPULUT::ORIGINAL.lines.map { |line| "    #{line}" }.join,
                      OptcarrotPPULUT::REPLACEMENT.lines.map { |line| "    #{line}" }.join)
raise 'unexpected source change' unless transformed == expected
rows = optimized_table.flatten(1)
raise 'tile rows unexpectedly shared' unless rows.map(&:object_id).uniq.size == 4 * 0x10000
optimized_table[0][0][0] = -1
raise 'row mutation affected other attributes' unless optimized_table[1..3].all? { |table| table[0][0] == 0 }
raise 'row mutation affected another pattern' unless optimized_table[0][1] == original_table[0][1]

[source.sub('(0..7)', '(0..8)'), source + source, 'missing generator'].each do |invalid|
  begin
    OptcarrotPPULUT.transform(invalid)
    raise 'invalid generator unexpectedly accepted'
  rescue RuntimeError => e
    raise unless e.message == 'expected exactly one upstream PPU tile table generator'
  end
end
Dir.mktmpdir('optcarrot-lut-check') do |temp|
  builder = File.expand_path('../../tools/optcarrot_probe/build_bundle.rb', __dir__)
  env = { 'OPTCARROT_NO_SHIMS' => nil, 'OPTCARROT_ORIGINAL_LUT' => nil,
          'OPTCARROT_STATIC_DISPATCH' => nil }
  bundles = [{}, { 'OPTCARROT_ORIGINAL_LUT' => '1' }, { 'OPTCARROT_NO_SHIMS' => '1' }].map.with_index do |options, index|
    bundle = File.join(temp, "bundle#{index}.rb")
    system(env.merge(options), RbConfig.ruby, builder, bundle, exception: true)
    File.read(bundle)
  end
  raise 'default bundle missing optimized generator' unless bundles[0].include?(OptcarrotPPULUT::REPLACEMENT.lines.first.strip)
  raise 'original bundle changed generator' unless bundles[1].include?('clr = i[15 - j] * 2 + i[7 - j]')
  raise 'native Ruby bundle changed generator' unless bundles[2].include?('clr = i[15 - j] * 2 + i[7 - j]')
  raise 'original bundle differs outside generator' unless bundles[0] == OptcarrotPPULUT.transform(bundles[1])
end
puts 'Optcarrot PPU LUT check: PASS (all 2,097,152 pixels, shape, row independence, bundle modes and upstream drift)'
