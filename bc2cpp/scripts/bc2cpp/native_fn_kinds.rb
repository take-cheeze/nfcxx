#!/usr/bin/env ruby
# frozen_string_literal: true

# The return kind of every function in the native sources the closed world reads, for NativeReturnClasses
# (BC2CPP_NATIVE_FN_KINDS). Each source is read by clang with the include paths its gem gets (BaseRbsAll.source_flags),
# so the closed build's generated headers (presym IDs, shinonome.hxx) and the analysis overlay (analysis_headers.rb) are
# visible. A file clang still cannot parse is listed on stderr and keeps only the regex kinds.
#
#   ruby scripts/bc2cpp/native_fn_kinds.rb CLOSED_BUILD_DIR > fn_kinds.tsv
#
# Output: one `fn<TAB>kind<TAB>self-index` row per function. kind is a class name, `self` (the receiver), or
# `unproven`. Two passes: the second sees the kinds of functions of other files, so a helper defined in another
# source resolves (NativeAstReturns' `external`).

require_relative 'base_rbs_all'

module NativeFnKinds
  module_function

  # [path, flags] for every source the table covers: the base generator's sources (the repo's gems, the mruby core
  # gems and CORE_NATIVE), the core library's own C, and the closed world's NATIVE_SRCS. A source named twice keeps its
  # first flags.
  def sources(closed_build)
    base = BaseRbsAll::CORE_NATIVE.values.flatten.map { |rel| File.join(BaseRbsAll::ROOT, rel) }
    base += Dir[File.join(BaseRbsAll::MRUBY_ROOT, 'src', '*.c')]
    BaseRbsAll.gems.each { |gem_dir| base += BaseRbsAll.native_sources(gem_dir) }
    (base + BaseRbsAll.closed_native_sources).uniq.sort.map { |path| [path, BaseRbsAll.source_flags(path, closed_build)] }
  end

  # One pass over every source. external: kinds of functions of other files. Returns [kinds, self_indexes].
  def pass(files, external)
    kinds = {}
    selves = {}
    files.each do |path, flags|
      own_self = {}
      BaseRbsNative.ast_function_kinds(path, flags, external, own_self).each do |fn, kind|
        kinds[fn] = kind if kinds[fn].nil?
        selves[fn] = own_self[fn] if own_self.key?(fn) && !selves.key?(fn)
      end
    end
    [kinds, selves]
  end

  def run(closed_build)
    files = sources(closed_build)
    first_kinds, first_selves = pass(files, {})
    external = first_kinds.reject { |_fn, kind| kind.nil? }
    # A function returning its own self parameter is the receiver's class wherever it is called (see
    # NativeAstReturns' identity rule), so a second-pass caller sees it as `self:N` for argument N.
    first_selves.each { |fn, index| external[fn] = "self:#{index}" if external[fn] == 'self' }
    second_kinds, second_selves = pass(files, external)
    second_kinds.sort.map do |fn, kind|
      index = second_selves[fn]
      [fn, kind.nil? ? 'unproven' : kind, index.nil? ? '' : index].join("\t")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  closed_build = ARGV.shift or abort 'usage: native_fn_kinds.rb CLOSED_BUILD_DIR'
  puts NativeFnKinds.run(File.expand_path(closed_build))
end
