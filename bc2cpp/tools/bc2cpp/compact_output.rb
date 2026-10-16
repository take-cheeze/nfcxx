# frozen_string_literal: true

require 'stringio'

# The generated C++ without its `//` diagnostic comments: bc2cpp.rb's default stdout. A caller that reads the
# comments (the proof and dispatch markers the checks match) passes ANNOTATED_FLAG.
ANNOTATED_FLAG = '--annotated'

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

  # The comments kept in compact output: one structural line per generated function, which
  # scripts/bc2cpp/hot_profile.rb reads from a build's *_gen.cpp to map callgrind functions to Ruby methods
  # and their required (keyword-call) callees.
  KEEP = %r{\A//(?: \S+#\S+ \(compiled from irep | \S+#\S+ -- synthesized attr_(?:reader|writer) override| \S+ :\S+ -> \S+#\S+ \(keyword call)}.freeze

  def self.rewrite(code)
    code.gsub(TOKENS) do |token|
      next token unless token.start_with?('//')

      token.match?(KEEP) ? token : "\n" * token.count("\n")
    end
  end
end
