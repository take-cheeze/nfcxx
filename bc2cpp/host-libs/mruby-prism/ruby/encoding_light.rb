# frozen_string_literal: true

# The light encoding layer Prism's Ruby half needs on mruby. It is prepended to the generated Prism sources by
# tools/build_mrblib.rb.
#
# The encoding of a string is the mruby-encoding gem's: a flag on the string object itself (MRB_STR_BINARY). A string
# is UTF-8 unless the flag is set, which is what `force_encoding("BINARY")` does. Nothing is kept on the side, so a
# string's encoding is as long-lived as the string.
#
# On top of that, this file adds what Prism compares against: the other encoding names as constants (no string
# has them, so comparisons with them are false, as they are for a UTF-8 or binary string), Encoding.find by name,
# and the UTF-8 inspect of non-ASCII strings as \uXXXX (CRuby's output under a non-UTF-8 locale).

RUBY_ENGINE = "mruby" unless defined?(RUBY_ENGINE)

module Encoding
  UTF_16LE = "UTF-16LE"
  UTF_16BE = "UTF-16BE"
  UTF_32LE = "UTF-32LE"
  UTF_32BE = "UTF-32BE"
  US_ASCII = "US-ASCII"
  ISO_8859_1 = "ISO-8859-1"
  WINDOWS_31J = "WINDOWS-31J"
  EUC_JP = "EUC-JP"
  SHIFT_JIS = "SHIFT_JIS"
  UTF_16 = "UTF-16"
  UTF_32 = "UTF-32"

  # The canonical name of a known encoding, as the mruby-encoding gem spells them (UTF-8 and ASCII-8BIT).
  def self.find(name)
    name = name.to_s
    upcased = name.upcase
    return "ASCII-8BIT" if upcased == "BINARY" || upcased == "ASCII-8BIT"
    return "UTF-8" if upcased == "UTF-8"
    return upcased if ["US-ASCII", "UTF-16LE", "UTF-16BE", "UTF-32LE", "UTF-32BE", "ISO-8859-1", "WINDOWS-31J",
                       "EUC-JP", "SHIFT_JIS", "UTF-16", "UTF-32"].include?(upcased)

    raise ArgumentError, "unknown encoding name - #{name}"
  end
end

class String
  # A loop over the bytes, not `bytes.all?`: the Array of every byte of a large source is past mruby's array size limit.
  def ascii_only?
    each_byte { |byte| return false if byte >= 128 }
    true
  end

  unless method_defined?(:b)
    def b
      dup.force_encoding(Encoding::BINARY)
    end
  end

  alias __light_core_inspect inspect

  def inspect
    return __light_core_inspect unless encoding == Encoding::UTF_8 && !ascii_only?

    out = +'"'
    data = bytes
    i = 0
    while i < data.size
      byte = data[i]
      if byte < 128
        out << __light_escape_ascii(byte, data[i + 1])
        i += 1
      else
        length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC2 ? 2 : 0
        codepoint = __light_codepoint(data, i, length)
        if codepoint
          out << (codepoint > 0xFFFF ? format("\\u{%X}", codepoint) : format("\\u%04X", codepoint))
          i += length
        else
          out << format("\\x%02X", byte)
          i += 1
        end
      end
    end
    out << '"'
  end

  def __light_escape_ascii(byte, following)
    case byte
    when 0x22 then '\\"'
    when 0x5C then '\\\\'
    when 0x0A then '\\n'
    when 0x09 then '\\t'
    when 0x0D then '\\r'
    when 0x1B then '\\e'
    when 0x07 then '\\a'
    when 0x08 then '\\b'
    when 0x0C then '\\f'
    when 0x0B then '\\v'
    when 0x23 then (following == 0x7B || following == 0x24 || following == 0x40) ? '\\#' : '#'
    when 0x7F then '\\x7F'
    else
      byte < 0x20 ? format("\\u%04X", byte) : byte.chr
    end
  end

  def __light_codepoint(data, i, length)
    return nil if length == 0 || i + length > data.size

    codepoint = data[i] & (0xFF >> (length + 1))
    (1...length).each do |k|
      continuation = data[i + k]
      return nil unless continuation & 0xC0 == 0x80

      codepoint = (codepoint << 6) | (continuation & 0x3F)
    end
    return nil if length == 3 && (codepoint < 0x800 || (codepoint >= 0xD800 && codepoint <= 0xDFFF))
    return nil if length == 4 && (codepoint < 0x10000 || codepoint > 0x10FFFF)

    codepoint
  end
end
