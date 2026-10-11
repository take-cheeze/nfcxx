# frozen_string_literal: true

# Expands only the benchmark's fixed upstream opcode table; upstream files stay intact.
module OptcarrotCPUDispatch
  SPLAT = 'send(*DISPATCH[@opcode])'

  def self.transform(source)
    require_relative '../../3rd/optcarrot/lib/optcarrot'
    validate_wrappers
    table = Optcarrot::CPU::DISPATCH
    raise 'expected all 256 CPU opcodes' unless table.size == 256 && table.all? { |entry| entry.is_a?(Array) }
    raise 'expected exactly one CPU dispatch splat' unless source.scan(SPLAT).size == 1

    groups = table.each_with_index.group_by { |entry, _opcode| entry }
    lines = ['case @opcode']
    groups.each do |entry, pairs|
      lines << "when #{pairs.map { |_args, opcode| opcode }.join(', ')}"
      lines.concat(calls(entry).map { |call| "  #{call}" })
    end
    lines << 'else raise "invalid opcode dispatch"'
    lines << 'end'
    source.sub(SPLAT, lines.join("\n          "))
  end

  # The expansion copies these wrapper operations; reject upstream drift instead
  # of silently retaining an obsolete CPU instruction sequence.
  def self.validate_wrappers
    source = File.read(File.expand_path('../../3rd/optcarrot/lib/optcarrot/cpu.rb', __dir__))
    expected = {
      r_op: 'send(mode, true, false); send(instr)',
      w_op: 'send(mode, false, true); send(instr); send(store)',
      rw_op: 'send(mode, true, true); send(instr); send(store)',
      a_op: '@clk += CLK_2; @data = @_a; send(instr); @_a = @data',
      no_op: '@_pc += ops; @clk += ticks * RP2A03_CC',
    }
    expected.each do |name, body|
      match = source.match(/^    def #{name}\([^\n]*\)\n(.*?)^    end$/m)
      actual = match && match[1].lines.map(&:strip).reject(&:empty?).join('; ')
      raise "upstream CPU wrapper #{name} changed" unless actual == body
    end
  end

  def self.calls(entry)
    kind, instr, mode, store = entry
    entry.each do |arg|
      next if arg.is_a?(Integer)
      raise "invalid CPU dispatch argument #{arg.inspect}" unless arg.is_a?(Symbol) && arg.to_s.match?(/\A[a-z_]\w*\z/)
    end
    case kind
    when :r_op, :w_op, :rw_op
      raise 'invalid addressing operation' unless entry.size == (kind == :r_op ? 3 : 4)
      calls = ["#{mode}(#{kind != :w_op}, #{kind != :r_op})", instr.to_s]
      calls << store.to_s unless kind == :r_op
      calls
    when :a_op
      raise 'invalid accumulator operation' unless entry.size == 2
      ['@clk += CLK_2', '@data = @_a', instr.to_s, '@_a = @data']
    when :no_op
      raise 'invalid no-op operation' unless entry.size == 4 && mode.is_a?(Integer) && store.is_a?(Integer)
      ["@_pc += #{mode}", "@clk += #{store} * RP2A03_CC"]
    else
      raise 'invalid direct operation' unless entry.size == 1
      [kind.to_s]
    end
  end
end
