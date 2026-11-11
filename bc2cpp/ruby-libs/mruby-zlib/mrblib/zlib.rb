# frozen_string_literal: true

# Zlib for the mruby build: only Zlib.crc32, the CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320) that
# CRuby's zlib computes. Compression and inflate are not provided.
module Zlib
  CRC32_TABLE = (0..255).map do |n|
    c = n
    8.times { c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
    c
  end.freeze

  # Zlib.crc32(string = nil, crc = 0): the CRC-32 of string, continued from a previous crc. A nil string gives 0, as in CRuby.
  def self.crc32(string = nil, crc = 0)
    return 0 if string.nil?

    c = (crc & 0xFFFFFFFF) ^ 0xFFFFFFFF
    string.each_byte { |b| c = CRC32_TABLE[(c ^ b) & 0xFF] ^ (c >> 8) }
    c ^ 0xFFFFFFFF
  end
end
