#!/usr/bin/env ruby
# frozen_string_literal: true

# The return kind of every function in the native sources the base generator describes, for NativeReturnClasses
# (BC2CPP_NATIVE_FN_KINDS). Each source is read by clang with the same include paths base_rbs_all.rb uses, so the
# closed build's generated headers (presym IDs, shinonome.hxx) are visible; a file clang still cannot parse is listed
# on stderr and keeps only the regex kinds.
#
#   ruby scripts/bc2cpp/native_fn_kinds.rb CLOSED_BUILD_DIR > fn_kinds.tsv
#
# Output: one `fn<TAB>kind<TAB>self-index` row per function. kind is a class name, `self` (the receiver), or
# `unproven`. Two passes: the second sees the kinds of functions of other files, so a helper defined in another
# source resolves (NativeAstReturns' `external`).

require_relative 'base_rbs_all'

module NativeFnKinds
  module_function

  def sources(closed_build)
    core = BaseRbsAll::CORE_NATIVE.map do |name, rels|
      [rels.map { |rel| File.join(BaseRbsAll::ROOT, rel) }, BaseRbsAll.core_flags(closed_build)]
    end
    gems = BaseRbsAll.gems.filter_map do |gem_dir|
      natives = BaseRbsAll.native_sources(gem_dir)
      next if natives.empty?

      [natives, BaseRbsAll.flags_for(gem_dir, closed_build)]
    end
    core + gems
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
    files = sources(closed_build).flat_map { |paths, flags| paths.map { |path| [path, flags] } }
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
