# Shellwords: split, join and escape, with CRuby's rules for POSIX shells. split raises ArgumentError on an
# unmatched quote or a trailing backslash.
module Shellwords
  def self.escape(str)
    str = str.to_s
    return "''" if str.empty?

    str.gsub(/[^A-Za-z0-9_\-.,:+\/@\n]/) { |char| "\\#{char}" }.gsub("\n", "'\n'")
  end

  def self.split(line)
    words = []
    field = nil
    chars = line.to_s.chars
    i = 0
    while i < chars.size
      char = chars[i]
      if char =~ /\s/
        words << field if field
        field = nil
      else
        field ||= +""
        case char
        when "\\"
          raise ArgumentError, "Unmatched quote: #{line.inspect}" if i + 1 >= chars.size

          i += 1
          field << chars[i]
        when "'"
          close = i + 1
          close += 1 while close < chars.size && chars[close] != "'"
          close = nil if close >= chars.size
          raise ArgumentError, "Unmatched quote: #{line.inspect}" unless close

          field << chars[(i + 1)...close].join
          i = close
        when "\""
          i += 1
          while i < chars.size && chars[i] != "\""
            if chars[i] == "\\" && i + 1 < chars.size && ["\"", "\\", "$", "`"].include?(chars[i + 1])
              i += 1
            end
            field << chars[i]
            i += 1
          end
          raise ArgumentError, "Unmatched quote: #{line.inspect}" if i >= chars.size
        else
          field << char
        end
      end
      i += 1
    end
    words << field if field
    words
  end

  def self.join(array)
    array.map { |arg| escape(arg) }.join(" ")
  end

  def self.shellsplit(line)
    split(line)
  end

  def self.shelljoin(array)
    join(array)
  end
end

class String
  def shellescape
    Shellwords.escape(self)
  end

  def shellsplit
    Shellwords.split(self)
  end
end

class Array
  def shelljoin
    Shellwords.join(self)
  end
end

MRubyRequire.provide('shellwords') { defined?(Shellwords) } if defined?(MRubyRequire)
