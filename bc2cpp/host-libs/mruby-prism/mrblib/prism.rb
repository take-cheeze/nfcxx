# frozen_string_literal: true

# Prism.parse for mruby: the same entry point CRuby's prism gem has. The C core parses the source and serializes the
# AST (Prism::Native.parse_serialized); the Ruby half (tools/build_mrblib.rb) decodes it into Prism::Node objects.
module Prism
  # Prism.lex: the tokens (each a [token, lex state] pair in value), comments and errors of a source, as the prism gem's
  # lex reports them. The C core serializes them (Native.lex_serialized); Serialize.load_lex decodes them.
  def self.lex(source, **_options)
    source = source.dup
    serialized = Native.lex_serialized(source).force_encoding(Encoding::BINARY)
    Serialize.load_lex(source, serialized, false)
  end

  # filepath: and the other options name diagnostics and the like, which this parse does not produce; they are accepted.
  def self.parse(source, **_options)
    source = source.dup
    serialized = Native.parse_serialized(source).force_encoding(Encoding::BINARY)
    Serialize.load_parse(source, serialized, false)
  end
end

module Prism
  # The pinned fork is v1.9.0 (host-libs/mruby-prism/mrbgem.rake); bc2cpp keys its caches on this version.
  VERSION = '1.9.0' unless const_defined?(:VERSION)
end
