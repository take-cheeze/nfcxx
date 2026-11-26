#!/usr/bin/env ruby
# frozen_string_literal: true

# Import RBS signatures for the gems a Gemfile.lock names, into a directory with one folder per gem:
#
#   ruby tools/rbs-import/rbs_import.rb --lock Gemfile.lock --out bc2cpp/sig --collection DIR [--only NAME,...]
#
# For each locked gem (name and version), the signatures come from the first source that has them:
#   1. the installed gem's own sig/ directory (Gem::Specification, so the gem must be installed);
#   2. a ruby/gem_rbs_collection checkout (--collection): gems/<name>/<major.minor>/, or the nearest
#      lower version folder when the exact one is missing (each folder has a manifest.yaml).
# Test directories (_test) and non-.rbs files are not copied, except the collection's manifest.yaml.
# Gems with no signatures in either source are reported, not failed: most gems ship none.

require 'fileutils'
require 'optparse'
require 'rubygems'

module RbsImport
  module_function

  # [name, version] pairs from the GEM section of a Gemfile.lock (the "specs:" entries at four spaces).
  def locked_gems(lock_path)
    gems = []
    File.foreach(lock_path) do |line|
      next unless (m = line.match(/\A {4}([A-Za-z0-9_.\-]+) \(([^)\s]+)\)\s*\z/))

      # the platform suffix (e.g. ffi (1.17.4-x86_64-linux-gnu)) is part of the file name, not the version
      version = m[2].sub(/-(x86_64|arm64|aarch64|x86|universal|java)-.*\z/, '')
      gems << [m[1], version]
    end
    gems.uniq
  end

  def installed_sig_dir(name, version)
    spec = Gem::Specification.find_by_name(name, version)
    dir = File.join(spec.full_gem_path, 'sig')
    File.directory?(dir) ? dir : nil
  rescue Gem::MissingSpecError, Gem::LoadError
    nil
  end

  # The folder of the collection for this gem: the exact major.minor, else the highest folder not above it.
  def collection_dir(collection, name, version)
    base = File.join(collection, 'gems', name)
    return nil unless File.directory?(base)

    wanted = Gem::Version.new(version.split('.').first(2).join('.'))
    candidates = Dir.children(base).select { |d| File.directory?(File.join(base, d)) && d.match?(/\A\d+(\.\d+)*\z/) }
    best = candidates.map { |d| [Gem::Version.new(d), d] }.select { |v, _| v <= wanted }.max_by(&:first)
    best && File.join(base, best[1])
  end

  # Copy the .rbs files under src into dest (relative paths kept), skipping _test trees.
  def copy_rbs(src, dest)
    count = 0
    Dir.glob('**/*.rbs', base: src).each do |rel|
      next if rel.split('/').include?('_test')

      target = File.join(dest, rel)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(File.join(src, rel), target)
      count += 1
    end
    manifest = File.join(src, 'manifest.yaml')
    FileUtils.cp(manifest, File.join(dest, 'manifest.yaml')) if File.file?(manifest)
    count
  end

  def import(lock:, out:, collection:, only: nil)
    report = []
    locked_gems(lock).each do |name, version|
      next if only && !only.include?(name)

      src, origin = [[installed_sig_dir(name, version), 'installed gem'],
                     [collection && collection_dir(collection, name, version), 'gem_rbs_collection']]
                    .find { |dir, _| dir }
      unless src
        report << [name, version, 0, 'none']
        next
      end
      dest = File.join(out, name)
      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(dest)
      report << [name, version, copy_rbs(src, dest), origin]
    end
    report
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {}
  OptionParser.new do |o|
    o.banner = 'usage: rbs_import.rb --lock Gemfile.lock --out DIR [--collection DIR] [--only NAME,...]'
    o.on('--lock PATH') { |v| opts[:lock] = v }
    o.on('--out DIR') { |v| opts[:out] = v }
    o.on('--collection DIR') { |v| opts[:collection] = v }
    o.on('--only NAMES') { |v| opts[:only] = v.split(',') }
  end.parse!
  abort 'rbs_import: --lock and --out are required' unless opts[:lock] && opts[:out]

  report = RbsImport.import(lock: opts[:lock], out: opts[:out], collection: opts[:collection], only: opts[:only])
  report.each { |name, version, count, origin| puts format('%-28s %-12s %4d files  %s', name, version, count, origin) }
  puts "imported #{report.count { |_, _, c, _| c.positive? }} of #{report.size} locked gems"
end
