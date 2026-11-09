#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../tools/bc2cpp/native_inventory'

inputs, output = ARGV
abort 'usage: ruby scripts/bc2cpp/native_inventory.rb INPUT_UNITS.json OUTPUT.json' unless inputs && output && ARGV.size == 2
NativeInventory.export(JSON.parse(File.read(inputs)), output)
