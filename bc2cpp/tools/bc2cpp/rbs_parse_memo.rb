# frozen_string_literal: true

# The declarations of one RBS text, parsed once per process. Several loaders read the same signature file, and parsing
# is the largest per-process cost of a signature load. The key is the text alone: the buffer name only reaches a
# parse error (which is not stored, so each caller still reports its own name), and the loaders read a declaration's
# line and column, never its buffer name. Callers that report a file use their own name in their diagnostics.
module RbsParseMemo
  module_function

  def decls(name, content)
    require 'rbs'
    (@decls ||= {})[content] ||= begin
      _buf, _dirs, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: name, content: content))
      decls
    end
  end
end
