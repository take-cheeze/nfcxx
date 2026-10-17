#!/usr/bin/env ruby
# frozen_string_literal: true

# Base RBS for every mrbgem in the repository: base_rbs.rb over each gem's mrblib, and base_rbs_native.rb over its
# hand-written C / C++ sources. The native include paths are the gem's own (`cxx.include_paths` / `cc.include_paths`
# in its mrbgem.rake, with `#{dir}` expanded), plus the mruby headers and the closed build's generated headers.
#
#   ruby scripts/bc2cpp/base_rbs_all.rb OUT_DIR [CLOSED_BUILD_DIR]
#
# Output: OUT_DIR/<gem>/ruby/*.rbs and OUT_DIR/<gem>/native.rbs. A gem whose native sources fail to preprocess is listed
# and skipped; the others still run. Nothing is written under sig/: these are base stubs, not compiler inputs.

require 'fileutils'
require 'open3'
require 'set'
require_relative 'base_rbs'
require_relative 'base_rbs_native'

module BaseRbsAll
  ROOT = File.expand_path('../..', __dir__)
  GEM_RAKE = %r{(?:cxx|cc)\.include_paths[^\n]*}.freeze
  INCLUDE_LITERAL = /"([^"]*)"/.freeze

  module_function

  # The `*-compiled` gems hold bc2cpp's generated register files, which are outputs, not sources to describe.
  def gems
    Dir[File.join(ROOT, '*', 'mrbgem.rake')].map { |rake| File.dirname(rake) }
                                              .reject { |dir| File.basename(dir).end_with?('-compiled') }.sort
  end

  # The include directories a gem's rake file names, with `#{dir}` (the gem's own directory) expanded.
  def gem_includes(gem_dir)
    rake = File.read(File.join(gem_dir, 'mrbgem.rake'), encoding: 'UTF-8')
    dirs = rake.scan(GEM_RAKE).flat_map { |line| line.scan(INCLUDE_LITERAL).flatten }
    dirs.filter_map do |literal|
      next unless literal.include?('#{dir}')

      path = literal.sub('#{dir}', gem_dir)
      File.expand_path(path) if File.directory?(path)
    end
  end

  def native_sources(gem_dir)
    Dir[File.join(gem_dir, 'src', '**', '*.{c,cc,cpp,cxx}')].sort
  end

  def ruby_sources(gem_dir)
    Dir[File.join(gem_dir, 'mrblib', '**', '*.rb')].sort
  end

  # Shared third-party headers the gems include, and the closed build's generated headers for this gem.
  def flags_for(gem_dir, closed_build)
    name = File.basename(gem_dir)
    base = %w[3rd/mruby/include 3rd/uni-algo/include 3rd/lvgl 3rd/stb include].map { |d| "-I#{File.join(ROOT, d)}" }
    base << "-I#{File.join(gem_dir, 'include')}"
    base += gem_includes(gem_dir).map { |dir| "-I#{dir}" }
    if closed_build
      base << "-I#{closed_build}/include"
      base << "-I#{closed_build}/mrbgems/#{name}"
    end
    base
  end

  def run(out_dir, closed_build)
    report = []
    gems.each do |gem_dir|
      name = File.basename(gem_dir)
      gem_out = File.join(out_dir, name)
      ruby = ruby_sources(gem_dir)
      unless ruby.empty?
        FileUtils.mkdir_p(File.join(gem_out, 'ruby'))
        BaseRbs.run(File.join(gem_out, 'ruby'), ruby)
      end
      natives = native_sources(gem_dir)
      next report << [name, 'ruby only', ruby.size] if natives.empty?

      FileUtils.mkdir_p(gem_out)
      begin
        path, skipped = BaseRbsNative.run(gem_out, natives, flags_for(gem_dir, closed_build))
        report << [name, 'ok', natives.size, skipped.size, path]
      rescue RuntimeError => e
        report << [name, 'native failed', natives.size, e.message.lines.first.to_s.strip]
      end
    end
    report
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'usage: base_rbs_all.rb OUT_DIR [CLOSED_BUILD_DIR]' if ARGV.empty?

  report = BaseRbsAll.run(ARGV[0], ARGV[1])
  report.each { |row| puts row.join("\t") }
end
