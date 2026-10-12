# frozen_string_literal: true

def self.__bc2cpp_tile_lut
  [0x0, 0x4, 0x8, 0xc].map do |attr|
    (0..7).map do |j|
      (0...0x10000).map do |i|
        clr = i[15 - j] * 2 + i[7 - j]
        clr != 0 ? attr | clr : 0
      end
    end.transpose
    # Super dirty hack: This Array#transpose reduces page-faults.
    # It might generate cache-friendly memory layout...
  end
end
