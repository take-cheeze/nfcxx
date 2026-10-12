#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../tools/optcarrot_probe/ppu_core'
require_relative '../../3rd/optcarrot/lib/optcarrot'

path = File.expand_path('../../3rd/optcarrot/lib/optcarrot/ppu.rb', __dir__)
source = File.read(path)
transformed = OptcarrotPPUCore.transform(source)
original_entry = OptcarrotPPUCore.run_entry(source)
entry = OptcarrotPPUCore.run_entry(transformed)
raise 'generated core contains Fiber switching' if entry.location.slice.include?('Fiber')
raise 'source prefix changed' unless source.byteslice(0, original_entry.location.start_offset) == transformed.byteslice(0, entry.location.start_offset)
raise 'source suffix changed' unless source.byteslice(original_entry.location.end_offset..) == transformed.byteslice(entry.location.end_offset..)

fixture = <<~CODE
  # Unicode offsets: 🎮
  text = "def run; :fake; end"
  class Other; def run; :other; end; end
  module Optcarrot
    class PPU
      def self.run; :singleton; end
      def run; :selected; end
      class Nested; def run; :nested; end; end
    end
  end
CODE
raise 'AST selected the wrong method' unless OptcarrotPPUCore.run_entry(fixture).location.slice == 'def run; :selected; end'
rewritten = OptcarrotPPUCore.replace_entry(fixture, OptcarrotPPUCore.run_entry(fixture), 'def run; :rewritten; end')
raise 'AST replacement damaged Unicode or another scope' unless rewritten == fixture.sub('def run; :selected; end', 'def run; :rewritten; end')
['class PPU; end', fixture.sub('def run; :selected; end', 'def run; end; def run; end'), 'module'].each do |invalid|
  begin
    OptcarrotPPUCore.run_entry(invalid)
    raise 'invalid PPU entry accepted'
  rescue RuntimeError => e
    raise unless ['expected exactly one upstream PPU run method', 'invalid upstream PPU syntax'].include?(e.message)
  end
end
begin
  OptcarrotPPUCore.transform(source.sub('Fiber.new', 'Fiber.new(:changed)'))
  raise 'changed upstream source accepted'
rescue RuntimeError => e
  raise unless e.message == 'PPU generator input differs from upstream source'
end

original = Optcarrot::PPU.instance_method(:run)
rom = File.expand_path('../../3rd/optcarrot/examples/Lan_Master.nes', __dir__)
[1, 2, 30, 60, 180, 181, 360].each do |frames|
  snapshots = [false, true].map do |generated|
    if generated
      Optcarrot::PPU.class_eval(entry.location.slice, path, entry.location.start_line)
    else
      Optcarrot::PPU.define_method(:run, original)
    end
    nes = Optcarrot::NES.new(romfile: rom, video: :none, audio: :none, input: :none, frames: frames)
    nes.run
    cpu_fields = %i[@_a @_x @_y @_pc @_sp @clk]
    ppu_fields = %i[@hclk @hclk_target @vclk @scanline @scroll_addr_0_4 @scroll_addr_5_14 @io_addr @io_latch]
    [nes.ppu.output_pixels.dup, nes.apu.output.dup, nes.cpu.ram.dup,
     cpu_fields.map { |name| nes.cpu.instance_variable_get(name) },
     ppu_fields.map { |name| nes.ppu.instance_variable_get(name) }]
  end
  raise "PPU output/state differs at #{frames} frames" unless snapshots[0] == snapshots[1]
end
Optcarrot::PPU.define_method(:run, original)
puts 'Optcarrot synchronous PPU: PASS (AST ranges, drift, full pixels/RAM/registers at seven frame counts)'
