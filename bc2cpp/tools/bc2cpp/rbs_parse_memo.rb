# frozen_string_literal: true

# The declarations of one RBS text, parsed once per process. Several loaders read the same signature file (each under
# its own display name, which lands in its diagnostics), and parsing is the largest per-process cost of a signature
# load. The key holds the name as well as the text, so a call sees exactly the AST it would have parsed itself.
# A parse that fails raises and stores nothing, so the caller's rescue sees the same error each time.
module RbsParseMemo
  module_function

  def decls(name, content)
    require 'rbs'
    (@decls ||= {})[[name, content]] ||= begin
      _buf, _dirs, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: name, content: content))
      decls
    end
  end
end
