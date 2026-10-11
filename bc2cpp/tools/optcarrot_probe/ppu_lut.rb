# frozen_string_literal: true

module OptcarrotPPULUT
  ORIGINAL = <<~RUBY.chomp
    TILE_LUT = [0x0, 0x4, 0x8, 0xc].map do |attr|
      (0..7).map do |j|
        (0...0x10000).map do |i|
          clr = i[15 - j] * 2 + i[7 - j]
          clr != 0 ? attr | clr : 0
        end
      end.transpose
      # Super dirty hack: This Array#transpose reduces page-faults.
      # It might generate cache-friendly memory layout...
    end
  RUBY
  REPLACEMENT = <<~RUBY.chomp
    TILE_LUT = begin
      pixels = (0...0x10000).map do |i|
        [
          ((i >> 15) & 1) * 2 + ((i >> 7) & 1),
          ((i >> 14) & 1) * 2 + ((i >> 6) & 1),
          ((i >> 13) & 1) * 2 + ((i >> 5) & 1),
          ((i >> 12) & 1) * 2 + ((i >> 4) & 1),
          ((i >> 11) & 1) * 2 + ((i >> 3) & 1),
          ((i >> 10) & 1) * 2 + ((i >> 2) & 1),
          ((i >> 9) & 1) * 2 + ((i >> 1) & 1),
          ((i >> 8) & 1) * 2 + ((i >> 0) & 1),
        ]
      end
      [pixels] + [0x4, 0x8, 0xc].map do |attr|
        pixels.map do |row|
          [
            row[0] == 0 ? 0 : attr | row[0],
            row[1] == 0 ? 0 : attr | row[1],
            row[2] == 0 ? 0 : attr | row[2],
            row[3] == 0 ? 0 : attr | row[3],
            row[4] == 0 ? 0 : attr | row[4],
            row[5] == 0 ? 0 : attr | row[5],
            row[6] == 0 ? 0 : attr | row[6],
            row[7] == 0 ? 0 : attr | row[7],
          ]
        end
      end
    end
  RUBY

  # Exact bounds permit eight fixed pixel expressions. Each attribute owns new
  # rows; color zero stays transparent when attribute bits are added.
  def self.transform(source)
    original = ORIGINAL.lines.map { |line| "    #{line}" }.join
    raise 'expected exactly one upstream PPU tile table generator' unless source.scan(original).size == 1

    source.sub(original, REPLACEMENT.lines.map { |line| "    #{line}" }.join)
  end
end
