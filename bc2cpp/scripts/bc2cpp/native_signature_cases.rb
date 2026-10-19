# frozen_string_literal: true

require 'rbs'
require_relative 'native_core_direct_sigs'
require_relative 'native_rgss_direct_sigs'

module NativeSignatureCases
  def self.run(check)
    [[NativeCoreDirectSigs, 'scripts/bc2cpp/native_core_direct_sigs.rb'],
     [NativeRgssDirectSigs, 'scripts/bc2cpp/native_rgss_direct_sigs.rb']].each do |generator, script|
      current = File.exist?(generator::PATH) ? File.read(generator::PATH) : nil
      check.call("#{generator::PATH} matches its table; regenerate with ruby #{script}", current == generator.render)
      next unless current

      begin
        RBS::Parser.parse_signature(RBS::Buffer.new(name: File.basename(generator::PATH), content: current))
        check.call("#{generator::PATH} parses as RBS", true)
      rescue RBS::ParsingError => e
        check.call("#{generator::PATH} does not parse: #{e.message}", false)
      end
    end
  end
end
