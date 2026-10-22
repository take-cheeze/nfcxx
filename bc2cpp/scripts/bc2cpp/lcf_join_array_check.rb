#!/usr/bin/env ruby
# frozen_string_literal: true

# LCF_FILE_FIELDS join (tools/bc2cpp/class_layout.rb, array_join_source?): `@lower = unit[:lower_layer] || []` on an
# exact LCF::MapUnit stores an Array on every path, so ClassLayout must not poison the ivar. The same shape on an
# untyped receiver is the negative: it has no schema fact and must stay poisoned.
#
#   1. the schema join: the ivar is not in the IVAR_POISON_REPORT, and its `size` is the exact ARY_LEN read.
#   2. the untyped join: the ivar stays in the report (element_read).
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/lcf_join_array_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~RUBY
  class JoinMap
    def initialize(unit, w)
      @w = w
      @lower = unit[:lower_layer] || []
    end
    def lower_size; @lower.size; end
  end
  class JoinLoader
    def self.load(io); JoinMap.new(LCF::MapUnit.new(io), 3); end
  end
  class OpaqueMap
    def initialize(source)
      @cells = source[:cells] || []
    end
    def cells_size; @cells.size; end
  end
  class OpaqueLoader
    def self.load(source); OpaqueMap.new(source); end
  end
RUBY

SIG = <<~RBS
  class JoinMap
    def initialize: (LCF::MapUnit, Integer) -> void
  end
  class OpaqueMap
    def initialize: (untyped) -> void
  end
RBS

MRBLIB = File.expand_path('../../mruby-lcf/mrblib', __dir__)
extra = %w[lcf.rb lcf_file.rb schema.rb].map { |f| ["mruby-lcf/mrblib/#{f}", File.read(File.join(MRBLIB, f))] }
owners = %w[JoinMap JoinLoader OpaqueMap OpaqueLoader LCF::File LCF::MapUnit LCF::Array1D LCF::Array2D LCF::Sections]

puts '-- LCF schema join keeps the ivar typed'
Dir.mktmpdir('lcf-join') do |dir|
  sig_dir = File.join(dir, 'sig')
  FileUtils.mkdir_p(sig_dir)
  File.write(File.join(sig_dir, 'join.rbs'), SIG)
  report = File.join(dir, 'poison.tsv')
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  ENV['BC2CPP_IVAR_POISON_REPORT'] = report
  code, _err = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: owners, extra: extra)
  poisoned = File.exist?(report) ? File.read(report).lines.map(&:chomp) : []
  ENV.delete('BC2CPP_IVAR_POISON_REPORT')

  check.call('the generator ran', !code.nil? && !code.empty?)
  # Single quotes: "#@lower" in a double-quoted string interpolates the ivar.
  check.call('JoinMap#@lower is not poisoned', !poisoned.include?('element_read' + "\t" + 'JoinMap#@lower'))
  body = code[/^\/\/ JoinMap#lower_size \(compiled.*?(?=^static mrb_value JoinMap_lower_size)/m].to_s
  check.call('lower_size reads the Array length exactly', body.include?('ARY_LEN('))
  check.call('lower_size does not dispatch', !body.match?(/mrb_funcall|bc2cpp_send|bc2cpp_getidx/))

  puts '-- an untyped receiver keeps the ivar poisoned'
  check.call('OpaqueMap#@cells stays poisoned', poisoned.include?('element_read' + "\t" + 'OpaqueMap#@cells'))
end

if failures.empty?
  puts 'lcf join array check: PASS'
else
  puts "lcf join array check: FAIL (#{failures.size})"
  exit 1
end
