# frozen_string_literal: true

require 'prism'

module OptcarrotPPUCore
  OPTIONS = %i[clock_specialization fastpath batch_render_pixels].freeze
  ORIGINAL_RUN = <<~RUBY.chomp
    def run
      @fiber ||= Fiber.new do
        main_loop
        :done
      end

      debug_logging(@scanline, @hclk, @hclk_target) if @conf.loglevel >= 3

      make_sure_invariants

      @hclk_target = (@vclk + @hclk) * RP2C02_CC unless @fiber.resume
    end
  RUBY

  def self.transform(source)
    require_relative '../../3rd/optcarrot/lib/optcarrot'
    path = File.expand_path('../../3rd/optcarrot/lib/optcarrot/ppu.rb', __dir__)
    raise 'PPU generator input differs from upstream source' unless source == File.read(path)

    entry = run_entry(source)
    original = ORIGINAL_RUN.lines.map.with_index { |line, index| index.zero? || line.strip.empty? ? line : "    #{line}" }.join
    raise 'upstream PPU run method changed' unless entry.location.slice == original

    generated = Optcarrot::PPU::OptimizedCodeBuilder.new(0, OPTIONS).build
    raise 'unexpected PPU generated entry' unless generated.start_with?("def self.run\n")

    # An ordinary instance method makes the fixed core statically visible to bc2cpp.
    generated = generated.sub("def self.run\n", "def run\n  debug_logging(@scanline, @hclk, @hclk_target) if @conf.loglevel >= 3\n")
    replacement = generated.chomp.lines.map.with_index { |line, index| index.zero? || line.strip.empty? ? line : "    #{line}" }.join
    replace_entry(source, entry, replacement)
  end

  def self.replace_entry(source, entry, replacement)
    source.byteslice(0, entry.location.start_offset) + replacement + source.byteslice(entry.location.end_offset..)
  end

  def self.run_entry(source)
    parsed = Prism.parse(source)
    raise 'invalid upstream PPU syntax' unless parsed.success?

    namespaces = parsed.value.statements.body.grep(Prism::ModuleNode).select { |node| node.constant_path.slice == 'Optcarrot' }
    classes = namespaces.flat_map { |node| Array(node.body&.body).grep(Prism::ClassNode) }.select { |node| node.constant_path.slice == 'PPU' }
    methods = classes.flat_map { |node| Array(node.body&.body).grep(Prism::DefNode) }.select { |node| node.name == :run && node.receiver.nil? }
    raise 'expected exactly one upstream PPU run method' unless methods.size == 1

    methods.first
  end
end
