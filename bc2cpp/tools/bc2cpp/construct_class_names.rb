# frozen_string_literal: true

# LEXICAL_CONSTRUCT_RESOLUTION (see dispatch_targets.rb's
# lexically_resolve_construct_target): the set of fully-qualified class and
# module names the closed world DEFINES.
#
# This is deliberately a different question from UniqueClassNames, which asks
# whether a BARE name has exactly one binding anywhere. Here the caller has
# already restricted the search to one lexical scope, so what is needed is only
# "does `P::N` exist" -- a fact about the program, not an inference about which
# one a lookup would reach. A name defined twice in the same scope still exists;
# lexical lookup order selects the innermost matching path before top-level.
#
# Built from the same CLASS/MODULE walk UniqueClassNames uses
# (bytecode_class_paths), then extended only with fully-qualified native paths
# that UniqueClassNames proves stable. A statement whose bytecode outer scope
# cannot be recovered is recorded as :unknown and EXCLUDED, since a name that
# might not exist must not be resolved.
module ConstructClassNames
  class << self
    # full path => true
    attr_accessor :table
  end

  module_function

  def analyze(ireps, root_label, native_unique_paths = [])
    paths = UniqueClassNames.bytecode_class_paths(ireps, root_label)
    out = {}
    paths.each_value do |fulls|
      fulls.each do |full|
        out[full] = true if full.is_a?(String)
      end
    end
    # UNIQUE_CLASS_NAME has already proved these native bindings have one
    # stable identity across native, bytecode, and foreign Ruby sources.
    Array(native_unique_paths).each do |full|
      out[full] = true if full.is_a?(String) && full.include?('::')
    end
    out
  end
end
