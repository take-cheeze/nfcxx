#!/usr/bin/env ruby
# frozen_string_literal: true

# Base RBS for every mrbgem in the repository: base_rbs.rb over each gem's mrblib, and base_rbs_native.rb over its
# hand-written C / C++ sources. The native include paths are the gem's own (`cxx.include_paths` / `cc.include_paths`
# in its mrbgem.rake, with `#{dir}` expanded), plus the mruby headers and the closed build's generated headers.
#
#   ruby scripts/bc2cpp/base_rbs_all.rb [--jobs N] OUT_DIR [CLOSED_BUILD_DIR]
#
# Output: OUT_DIR/<gem>/ruby/*.rbs and OUT_DIR/<gem>/native.rbs. A gem whose native sources fail to preprocess is listed
# and skipped; the others still run. Nothing is written under sig/: these are base stubs, not compiler inputs.

require 'fileutils'
require 'open3'
require 'set'
require 'optparse'
require_relative 'base_rbs'
require_relative 'base_rbs_native'

module BaseRbsAll
  ROOT = File.expand_path('../..', __dir__)
  MRUBY_ROOT = File.join(ROOT, '3rd', 'mruby')
  MRUBY_TOKEN = '#{MRUBY_ROOT}'
  GEM_RAKE = %r{(?:cxx|cc)\.include_paths[^\n]*}.freeze
  INCLUDE_LITERAL = /"([^"]*)"/.freeze
  CORE_GEM = /conf\.gem core: ['"]([^'"]+)['"]/.freeze
  PATH_GEM = /conf\.gem ['"]([^'"]+)['"]/.freeze
  MRUBY_PATH = /\A#{Regexp.escape(MRUBY_TOKEN)}/.freeze

  module_function

  # Every gem the build config builds: the repo's own gems (`*/mrbgem.rake`), the mruby core gems named by `conf.gem
  # core:` (3rd/mruby/mrbgems), and the path gems `conf.gem "#{MRUBY_ROOT}/../..."` names. The `*-compiled` gems hold
  # bc2cpp's generated register files, which are outputs, not sources to describe.
  def gems
    repo = Dir[File.join(ROOT, '*', 'mrbgem.rake')].map { |rake| File.dirname(rake) }
    (repo + build_config_gems).reject { |dir| File.basename(dir).end_with?('-compiled') }.uniq.sort
  end

  # The gem directories build_config.rb names, with `#{MRUBY_ROOT}` expanded. A name that does not resolve to a
  # directory is listed on stderr rather than dropped.
  def build_config_gems
    text = File.read(File.join(ROOT, 'build_config.rb'), encoding: 'UTF-8')
    core = text.scan(CORE_GEM).flatten.map { |name| File.join(MRUBY_ROOT, 'mrbgems', name) }
    paths = text.scan(PATH_GEM).flatten.grep(MRUBY_PATH).map { |lit| File.expand_path(lit.sub(MRUBY_TOKEN, MRUBY_ROOT)) }
    (core + paths).filter_map do |dir|
      next dir if File.directory?(dir)

      warn "base_rbs_all: build config gem #{dir} is not a directory; skipped"
      nil
    end
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

  # mruby's own core gems keep their C under `core/` (mruby-bigint, mruby-compiler); the repo's gems use `src/`.
  def native_sources(gem_dir)
    %w[src core].flat_map { |dir| Dir[File.join(gem_dir, dir, '**', '*.{c,cc,cpp,cxx}')] }.sort
  end

  def ruby_sources(gem_dir)
    Dir[File.join(gem_dir, 'mrblib', '**', '*.rb')].sort
  end

  # Shared third-party headers the gems include, and the closed build's generated headers for this gem.
  # mruby's own native sources outside every gem: error.c defines the exception hierarchy (ADR-free; the classes are
  # native registrations with superclasses, which the base section declares as `class X < Y`).
  CORE_NATIVE = { 'mruby-core' => ['3rd/mruby/src/error.c'] }.freeze
  # mruby's Ruby-defined exception classes: NameError, NoMethodError and StopIteration. The closed world leaves this file
  # out of its compiled set (compiled_gems.rb, BC2CPP_CORE_MRBLIB_EXCLUDED), so only the declarations describe it.
  CORE_RUBY = ['3rd/mruby/mrblib/10error.rb'].freeze

  def core_flags(closed_build)
    base = %w[3rd/mruby/include 3rd/uni-algo/include 3rd/lvgl 3rd/stb include].map { |d| "-I#{File.join(ROOT, d)}" }
    closed_build ? base + ["-I#{closed_build}/include"] : base
  end

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

  def run(out_dir, closed_build, jobs: BaseRbsWorkers::DEFAULT_JOBS)
    report = []
    path, = BaseRbs.run(File.join(out_dir, 'mruby-core', 'ruby'), CORE_RUBY.map { |rel| File.join(ROOT, rel) })
    # Only the class headers: the closed world does not compile these methods, so a declared method is not in the
    # program and the type check rejects it (TC1003). The headers carry the superclass the hierarchy needs.
    Dir[File.join(out_dir, 'mruby-core', 'ruby', '*.rbs')].each do |file|
      File.write(file, File.read(file).lines.reject { |line| line.start_with?('  ') }.join)
    end
    report << ['mruby-core ruby', 'ok', CORE_RUBY.size, 0, path]
    CORE_NATIVE.each do |name, rels|
      srcs = rels.map { |rel| File.join(ROOT, rel) }
      gem_out = File.join(out_dir, name)
      FileUtils.mkdir_p(gem_out)
      path, skipped = BaseRbsNative.run(gem_out, srcs, core_flags(closed_build), jobs: jobs)
      report << [name, 'ok', srcs.size, skipped.size, path]
    end
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
        path, skipped = BaseRbsNative.run(gem_out, natives, flags_for(gem_dir, closed_build), jobs: jobs)
        report << [name, 'ok', natives.size, skipped.size, path]
      rescue RuntimeError => e
        report << [name, 'native failed', natives.size, e.message.lines.first.to_s.strip]
      end
    end
    report
  end
end

if $PROGRAM_NAME == __FILE__
  jobs = BaseRbsWorkers::DEFAULT_JOBS
  parser = OptionParser.new do |opts|
    opts.banner = 'usage: base_rbs_all.rb [--jobs N] OUT_DIR [CLOSED_BUILD_DIR]'
    opts.on('-j N', '--jobs N', Integer, 'Native file workers (default: at most 2; 1 runs serially)') { |n| jobs = n }
  end
  begin
    parser.parse!(ARGV)
    raise OptionParser::InvalidArgument, 'jobs must be positive' unless jobs.positive?
  rescue OptionParser::ParseError => e
    abort "#{e.message}\n#{parser}"
  end
  abort parser.to_s unless (1..2).cover?(ARGV.size)

  report = BaseRbsAll.run(ARGV[0], ARGV[1], jobs: jobs)
  report.each { |row| puts row.join("\t") }
end
