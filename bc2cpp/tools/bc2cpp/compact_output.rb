# frozen_string_literal: true

require 'stringio'

module CompactOutput
  # Keep literal tokens and block comments opaque; diagnostic line comments
  # can contain arbitrary Ruby source, including C++ quote/comment markers.
  TOKENS = /R"([^ ()\\\t\r\n]{0,16})\(.*?\)\1"|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\/\*.*?\*\/|\/\/(?:\\\r?\n|[^\n])*/m.freeze

  # Register before instrumentation: exit handlers run in reverse order, so
  # diagnostic markers remain available until every instrumenter finishes.
  def self.capture_stdout
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    at_exit do
      $stdout = original
      original.write(rewrite(buffer.string)) unless $!
    end
  end

  def self.rewrite(code)
    code.gsub(TOKENS) do |token|
      token.start_with?('//') ? "\n" * token.count("\n") : token
    end
  end
end
