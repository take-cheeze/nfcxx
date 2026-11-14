# frozen_string_literal: true

# The interpreter and the two gems whose output bc2cpp's scans and generation read: Prism builds the syntax trees,
# RBS the signatures. A cache key that stands for their output includes these versions (ScanCache, IrepCache, the
# self-generation fingerprint in tools/self_compile/artifacts.rb).
module Toolchain
  module_function

  # [RUBY_DESCRIPTION, Prism::VERSION, RBS::VERSION or nil]. RBS is loaded so its version is known in every process
  # that computes a key; a key without it would keep a result computed under another RBS. Without the gem, nil.
  def versions
    @versions ||= begin
      require 'prism'
      rbs = begin
        require 'rbs'
        RBS::VERSION
      rescue LoadError
        nil
      end
      # mruby (the self-compiled compiler) has no RUBY_DESCRIPTION; its key is a fixed name, which still changes with the
      # Ruby that compiled the tools, since the tool sources are keyed separately.
      [defined?(RUBY_DESCRIPTION) ? RUBY_DESCRIPTION : 'mruby', Prism::VERSION, rbs].freeze
    end
  end
end
