#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require 'open3'
require 'shellwords'
require_relative '../../tools/optcarrot_probe/ppu_lut'
require_relative '../../tools/optcarrot_probe/ir_tile_lut'

root = File.expand_path('../..', __dir__)
Dir.mktmpdir('ppu-ir-lut') do |temp|
  reference_path = File.join(root, 'tools/bc2cpp/fixtures/tile_lut.rb')
  ireps, = compile_ireps([reference_path], 'reference', temp)
  reference = ireps.values.find { |irep| irep.enter && irep.enter.enter_fields.first.zero? }
  raise 'canonical IR declined' unless BytecodeIR::TileLUT.build(reference, reference)
  raise 'missing reference accepted' if BytecodeIR::TileLUT.build(reference, nil)
  leaf = ireps.values.find { |irep| irep.reps.empty? }
  old_pool = leaf.pool
  leaf.pool = old_pool + ['changed']
  pristine, = compile_ireps([reference_path], 'pristine', temp)
  expected = pristine.values.find { |irep| irep.enter && irep.enter.enter_fields.first.zero? }
  raise 'changed pool accepted' if BytecodeIR::TileLUT.build(reference, expected)
  leaf.pool = old_pool
  block = reference.instructions.find { |insn| insn.typed.any? { |operand| operand.kind == :irep } }
  operands = block.typed
  block.typed = operands.map { |operand| OperandSchema::Operand.new(operand.kind, operand.kind == :irep ? 1 : operand.value) }
  raise 'changed block index accepted' if BytecodeIR::TileLUT.build(reference, expected)
  block.typed = operands

  source = "class PPU\n#{OptcarrotPPULUT::ORIGINAL.lines.map { |line| "    #{line}" }.join}\nend"
  extracted = OptcarrotPPULUT.extract(source)
  emitted, capture = OptcarrotIRTileLUT.prepare(extracted, temp)
  explicit_source = File.join(temp, 'explicit_source.rb')
  File.write(explicit_source, extracted)
  child = 'result = OptcarrotIRTileLUT.prepare(File.read(ARGV[0]), ARGV[1], mrbc: ARGV[2]); puts result.first.size'
  out, err, status = Open3.capture3({ 'MRBC' => nil }, RbConfig.ruby,
                                  '-r', File.join(root, 'tools/optcarrot_probe/ir_tile_lut'),
                                  '-e', child, explicit_source, temp, MRBC)
  raise "explicit compiler with MRBC unset failed: #{out}#{err}" unless status.success? && err.empty? && out.to_i.positive?
  altered = extracted.sub('(0..7)', '(0..8)')
  begin
    OptcarrotIRTileLUT.prepare(altered, temp)
    raise 'changed bytecode accepted'
  rescue RuntimeError => e
    raise unless e.message == 'expected exactly one decoded tile LUT generator'
  end

  build = ENV['MRUBY_BUILD']
  if build
    raise "MRUBY_BUILD has no compatible library: #{build}" unless File.file?(File.join(build, 'lib/libmruby.a'))

    script = <<~RUBY_SCRIPT
      #{File.read(File.join(root, 'tools/optcarrot_probe/shim_integer_aref.rb'))}
      module Optcarrot
        class PPU
          #{File.read(reference_path)}
        end
      end
      PPU = Optcarrot::PPU
      class << PPU
        alias __test_original __bc2cpp_tile_lut
        def __bc2cpp_tile_lut
          []
        end
      end
      raise 'changed runtime generator accepted' if OptcarrotProbe.install_tile_lut!(PPU)
      class << PPU
        alias __bc2cpp_tile_lut __test_original
      end
      raise 'alias-backed runtime generator accepted' if OptcarrotProbe.install_tile_lut!(PPU)
      module Optcarrot
        class PPU
          #{File.read(reference_path)}
        end
      end
      class OtherPPU
        #{File.read(reference_path)}
      end
      raise 'wrong target accepted' if OptcarrotProbe.install_tile_lut!(OtherPPU)
      raise 'native installation refused' unless OptcarrotProbe.install_tile_lut!(PPU)
      actual = PPU.__bc2cpp_tile_lut
      expected = PPU.instance_eval do
        #{OptcarrotPPULUT::ORIGINAL}
      end
      raise 'full table equality failed' unless actual == expected
      ids = {}
      actual.each do |table|
        table.each do |row|
          raise 'shared mutable rows' if ids.key?(row.object_id)
          ids[row.object_id] = true
        end
      end
      raise 'row count changed' unless ids.size == 262144
      actual[0][0][0] = -1
      raise 'mutation leaked across attrs' unless actual[1][0][0] == 0
      raise 'mutation leaked across patterns' unless actual[0][1] == expected[0][1]
      class Array
        def map
          raise 'test redefinition'
        end
      end
      raise 'changed core method accepted' if OptcarrotProbe.install_tile_lut!(PPU)
      begin
        PPU.__bc2cpp_tile_lut
        raise 'runtime fallback was bypassed'
      rescue RuntimeError => e
        raise unless e.message == 'test redefinition'
      end
      puts 'native full equality, independent rows, mutation and guard refusal: PASS'
    RUBY_SCRIPT
    script_path = File.join(temp, 'check.rb')
    File.write(script_path, script)
    host = File.join(temp, 'host.cpp')
    File.write(host, <<~CPP)
      #include <mruby.h>
      #include <mruby/array.h>
      #include <mruby/class.h>
      #include <mruby/proc.h>
      #include <mruby/irep.h>
      #include <mruby/compile.h>
      #include <cstring>
      #include <cstdio>
      #{emitted}
      int main(int argc, char** argv) {
        mrb_state* M = mrb_open();
        if (!M || M->exc) return 2;
        struct RClass* mod = mrb_define_module(M, "OptcarrotProbe");
        #{capture}
        FILE* input = fopen(argv[1], "r");
        if (!input) return 3;
        mrb_load_file(M, input);
        fclose(input);
        int failed = M->exc != nullptr;
        if (failed) mrb_print_error(M);
        mrb_close(M);
        return failed;
      }
    CPP
    flags_path = File.join(build, 'lib/libmruby.flags.mak')
    flags = File.read(flags_path).lines.filter_map { |line| line.split(' =', 2).map(&:strip) if line.include?(' = ') }.to_h
    binary = File.join(temp, 'host')
    command = Shellwords.split(ENV.fetch('CXX', 'c++')) + ['-std=c++17', "-I#{File.join(build, 'include')}"] +
              Shellwords.split(flags.fetch('MRUBY_CXXFLAGS', '').gsub('$(MRUBY_PACKAGE_DIR)', build)) + [host, File.join(build, 'lib/libmruby.a')] +
              Shellwords.split(flags.fetch('MRUBY_LDFLAGS', '').gsub('$(MRUBY_PACKAGE_DIR)', build)) + Shellwords.split(flags.fetch('MRUBY_LIBS', '-lm')) + ['-o', binary]
    system(*command, exception: true)
    system(binary, script_path, exception: true)
    builder = File.join(root, 'tools/optcarrot_probe/build_bundle.rb')
    bundle = File.join(temp, 'bundle.rb')
    system({ 'OPTCARROT_IR_LUT' => '1', 'OPTCARROT_ORIGINAL_LUT' => nil, 'OPTCARROT_NO_SHIMS' => nil,
             'OPTCARROT_STATIC_PPU' => nil, 'OPTCARROT_STATIC_DISPATCH' => nil },
           RbConfig.ruby, builder, bundle, exception: true)
    bundled = File.read(bundle)
    raise 'bundle bootstrap point missing' unless bundled.sub!("    TILE_LUT = __bc2cpp_tile_lut", "    raise 'full bundle native installation refused' unless OptcarrotProbe.install_tile_lut!(self)\n    TILE_LUT = __bc2cpp_tile_lut")
    rom = File.join(root, '3rd/optcarrot/examples/Lan_Master.nes')
    File.write(bundle, "ARGV = [#{rom.dump}, '1']\n" + bundled)
    system(binary, bundle, exception: true)
  else
    puts 'Optcarrot PPU IR LUT native check: SKIP (set MRUBY_BUILD to a compatible Optcarrot probe host)'
  end
end
puts 'Optcarrot PPU bytecode IR LUT check: PASS (exact tree, decoded drift and child-reference refusal)'
