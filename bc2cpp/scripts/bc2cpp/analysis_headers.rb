#!/usr/bin/env ruby
# frozen_string_literal: true

# The headers the native return analysis needs and the closed build does not produce: a presym ID header covering every
# symbol the closed world's native sources name, and the Onigmo header mruby-onig-regexp includes.
#
#   ruby scripts/bc2cpp/analysis_headers.rb CLOSED_BUILD_DIR
#
# Writes CLOSED_BUILD_DIR/analysis/include/{mruby/presym/id.h,onigmo.h,oniguruma.h}. Nothing the closed build compiles
# reads these: they are an overlay for the analysis (base_rbs_all.rb and native_fn_kinds.rb put this directory first on
# their include path), so the closed library keeps its own presym numbering.
#
# The IDs are mruby's own: each source is preprocessed with MRB_PRESYM_SCANNING and mruby's presym scanner
# (3rd/mruby/lib/mruby/presym.rb) reads the names, so the header matches what the build would generate for the same
# sources. The closed presym list covers only the gems the closed build compiles; a source the closed world reads from
# outside that list (mruby-onig-regexp, mruby-dir's own symbols) needs this overlay to parse.

require 'fileutils'
require 'open3'
require_relative 'base_rbs_all'
require_relative 'base_rbs_native'

# mruby's presym writer, loaded from the submodule without its build system: the writer's `_pp` progress lines and
# `relative_path` names are build-system helpers this script does not need.
class String
  def relative_path = self
end

module MRuby
  class Presym
    def _pp(*); end
  end
end
require File.join(BaseRbsAll::MRUBY_ROOT, 'lib', 'mruby', 'presym')

module AnalysisHeaders
  ONIGMO_TARBALL = File.join(BaseRbsAll::ROOT, '3rd', 'mruby-onig-regexp', 'onigmo-6.2.0.tar.gz')
  ONIGMO_MEMBER = 'onigmo-6.2.0/onigmo.h'

  module_function

  # The sources the closed world reads: the RGSS natives, the core and external gems' natives (BaseRbsAll).
  def native_sources
    BaseRbsAll.closed_native_sources
  end

  # The presym names every source names, as mruby's scanner reads them from the preprocessed output.
  def scan(sources, closed_build, work_dir)
    presym = MRuby::Presym.new(Struct.new(:build_dir).new(work_dir))
    scan_dir = File.join(work_dir, 'scan')
    FileUtils.mkdir_p(scan_dir)
    files = sources.each_with_index.map do |path, index|
      out = File.join(scan_dir, format('%04d.i', index))
      text = BaseRbsNative.preprocess(path, BaseRbsAll.source_flags(path, closed_build) + ['-DMRB_PRESYM_SCANNING'])
      File.binwrite(out, text)
      out
    end
    presym.scan(files)
  end

  # The closed build's own presym names (its `presym` list). The overlay keeps all of them: a source the closed build
  # does not compile (mruby-compiler's codegen.c, for one) still reads names the closed build interned.
  def closed_names(closed_build)
    MRuby::Presym.new(Struct.new(:build_dir).new(closed_build)).read_list
  end

  def write_onigmo(include_dir)
    onigmo = Open3.capture2('tar', '-xzOf', ONIGMO_TARBALL, ONIGMO_MEMBER)
    status = onigmo.last
    raise "tar failed reading #{ONIGMO_TARBALL}" unless status.success?

    File.binwrite(File.join(include_dir, 'onigmo.h'), onigmo.first)
    # mruby_onig_regexp.c includes <oniguruma.h>, the name the system library installs; the bundled header is onigmo.h.
    File.write(File.join(include_dir, 'oniguruma.h'), "#include \"onigmo.h\"\n")
  end

  def run(closed_build)
    overlay = File.join(closed_build, 'analysis')
    include_dir = File.join(overlay, 'include')
    FileUtils.rm_rf(overlay)
    FileUtils.mkdir_p(include_dir)
    # The Onigmo headers first: the scan preprocesses mruby-onig-regexp, which includes oniguruma.h.
    write_onigmo(include_dir)
    sources = native_sources
    presyms = (closed_names(closed_build) + scan(sources, closed_build, overlay)).uniq.sort_by { |sym| [sym.size, sym] }
    presym = MRuby::Presym.new(Struct.new(:build_dir).new(overlay))
    FileUtils.mkdir_p(presym.header_dir)
    presym.write_id_header(presyms)
    FileUtils.rm_rf(File.join(overlay, 'scan'))
    warn "analysis headers: #{presyms.size} presym IDs from #{sources.size} sources"
    overlay
  end
end

if $PROGRAM_NAME == __FILE__
  closed_build = ARGV.shift or abort 'usage: analysis_headers.rb CLOSED_BUILD_DIR'
  AnalysisHeaders.run(File.expand_path(closed_build))
end
