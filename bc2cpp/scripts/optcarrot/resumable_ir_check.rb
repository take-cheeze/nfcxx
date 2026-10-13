#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'tmpdir'

baseline, optimized, rom, *counts = ARGV
abort "usage: #{$PROGRAM_NAME} BASELINE_BINARY OPTIMIZED_BINARY ROM [FRAMES ...]" unless baseline && optimized && rom
binaries = [baseline, optimized].map { |path| File.expand_path(path) }
rom = File.expand_path(rom)
frames = counts.empty? ? [2, 180, 1800] : counts.map { |count| Integer(count, 10) }
raise 'frame counts must be positive' unless frames.all?(&:positive?)
raise 'benchmark binaries or ROM missing' unless (binaries + [rom]).all? { |path| File.file?(path) }

Dir.mktmpdir('optcarrot-resumable-ir-check') do |dir|
  bundle = File.join(dir, 'snapshot.rb')
  builder = File.expand_path('../../tools/optcarrot_probe/build_bundle.rb', __dir__)
  output, status = Open3.capture2e({ 'OPTCARROT_STATIC_DISPATCH' => '1', 'OPTCARROT_STATIC_PPU' => '0' },
                                RbConfig.ruby, builder, bundle)
  raise "bundle failed: #{output}" unless status.success?

  source = File.read(bundle)
  runner = File.read(File.expand_path('../../tools/optcarrot_probe/runner_tail.rb', __dir__))
  raise 'runner insertion point changed' unless source.end_with?(runner)

  source = source.delete_suffix(runner) + <<~'RUBY'
    OptcarrotProbe.install!
    nes = Optcarrot::NES.new(romfile: ARGV[0], video: :none, audio: :none,
                            input: :none, frames: ARGV[1].to_i)
    nes.run
    cpu_fields = %i[@_a @_x @_y @_pc @_sp @clk]
    ppu_fields = %i[@hclk @hclk_target @vclk @scanline @scroll_addr_0_4 @scroll_addr_5_14 @io_addr @io_latch]
    cpu = cpu_fields.map { |name| nes.cpu.instance_variable_get(name) }
    ppu = ppu_fields.map { |name| nes.ppu.instance_variable_get(name) }
    raise 'register reflection returned nil' if (cpu + ppu).any? { |value| value.nil? }
    puts "SNAPSHOT: #{[nes.ppu.output_pixels, nes.apu.output, nes.cpu.ram, cpu, ppu].inspect}"
  RUBY
  File.write(bundle, source)
  frames.each do |count|
    snapshots = binaries.map do |binary|
      output, status = Open3.capture2e(binary, bundle, rom, count.to_s)
      raise "#{binary} failed at #{count} frames: #{output.lines.last(15).join}" unless status.success?

      lines = output.lines.select { |line| line.start_with?('SNAPSHOT: ') }
      raise "#{binary} did not print exactly one snapshot" unless lines.size == 1

      lines.first
    end
    raise "pixels/audio/RAM/registers differ at #{count} frames" unless snapshots.first == snapshots.last

    puts "Optcarrot resumable IR: PASS (#{File.basename(rom)}, #{count} frames, full pixels/audio/RAM/CPU/PPU registers)"
  end
end
