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
#
# Time: a file's clang dump and its JSON parse dominate (the dump of a source that includes the RGSS headers is ~0.9 GB),
# so each file runs in its own worker (BC2CPP_TABLE_JOBS, default 2: a worker holds one parsed dump), and each file's
# result is cached under CLOSED/analysis/kinds-cache, keyed on the file, its flags, the analyzer's own sources and, for
# the second pass, the external kinds. A cached run re-parses only what changed.

require 'digest'
require 'fileutils'
require_relative 'base_rbs_all'
require_relative 'base_rbs_native'
require_relative 'base_rbs_workers'

module NativeFnKinds
  JOBS_ENV = 'BC2CPP_TABLE_JOBS'
  DEFAULT_JOBS = 2
  PATCH_LIST = File.join(BaseRbsAll::ROOT, 'scripts', 'mruby', 'standalone_prep.bash')

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

  # The mruby patches standalone_prep.bash applies to 3rd/mruby, by name. The sources must carry them: the closed build
  # compiles the patched tree, and an unpatched tree parses differently (symbol.c's table, profiler.cxx's counters).
  def mruby_patch_names
    text = File.read(PATCH_LIST, encoding: 'UTF-8')
    listed = text[/for p in (.*?); do/m, 1] or raise "no mruby patch list in #{PATCH_LIST}"
    listed.delete('\\').split
  end

  # The patches that are not applied. The test is the one apply_mruby_patch.bash makes (GNU patch, reverse dry run): a
  # patch that applies in reverse is in the tree, offsets and fuzz included.
  def missing_patches
    mruby = BaseRbsAll::MRUBY_ROOT
    mruby_patch_names.reject do |name|
      patch = File.join(BaseRbsAll::ROOT, 'patches', "#{name}.patch")
      system('patch', '-p1', '-R', '-N', '--dry-run', '-s', in: patch, chdir: mruby, out: File::NULL, err: File::NULL)
    end
  end

  # Digest of the analyzer's own sources: a change to the analysis invalidates every cached result.
  def analyzer_digest
    files = Dir[File.join(BaseRbsAll::ROOT, 'tools', 'bc2cpp', 'native_*.rb')].sort +
            [File.join(BaseRbsAll::ROOT, 'scripts', 'bc2cpp', 'base_rbs_native.rb')]
    Digest::SHA256.hexdigest(files.map { |file| Digest::SHA256.file(file).hexdigest }.join)
  end

  # One file's (kinds, self-index) under the given external kinds: the clang dump, read once.
  def analyze_file(path, flags, external)
    own_self = {}
    kinds = BaseRbsNative.ast_function_kinds(path, flags, external, own_self)
    [kinds, own_self]
  end

  # One pass over every source. Results come from the cache where it holds them; the rest run in workers. Returns
  # [kinds, self_indexes], merged in path order (the first non-nil kind of a name wins).
  def pass(files, external, cache_dir:, jobs:)
    external_digest = external.empty? ? '' : Digest::SHA256.hexdigest(external.sort.to_s)
    base = [analyzer_digest, external_digest]
    keys = files.map do |path, flags|
      Digest::SHA256.hexdigest([*base, path, Digest::SHA256.file(path).hexdigest, flags.join("\0")].join("\n"))
    end
    results = Array.new(files.size)
    todo = files.each_index.reject do |index|
      next false unless cache_dir && File.file?(File.join(cache_dir, keys[index]))

      results[index] = Marshal.load(File.binread(File.join(cache_dir, keys[index]))) # rubocop:disable Security/MarshalLoad
    end
    # The largest dumps first, so the workers finish together.
    todo = todo.sort_by { |index| -File.size(files[index][0]) }
    computed = BaseRbsWorkers.map(todo.map { |index| [index, *files[index]] }, jobs: jobs) do |index, path, flags|
      [index, analyze_file(path, flags, external)]
    end
    computed.each do |index, result|
      results[index] = result
      # A file clang could not parse returns no kinds; it is not cached, so its warning shows again next time.
      next unless cache_dir && !result.first.empty?

      File.binwrite(File.join(cache_dir, keys[index]), Marshal.dump(result))
    end
    kinds = {}
    selves = {}
    results.each do |file_kinds, own_self|
      file_kinds.each { |fn, kind| kinds[fn] = kind if kinds[fn].nil? }
      own_self.each { |fn, index| selves[fn] = index unless selves.key?(fn) }
    end
    [kinds, selves]
  end

  def jobs
    Integer(ENV.fetch(JOBS_ENV, DEFAULT_JOBS))
  end

  def run(closed_build, cache_dir:)
    missing = missing_patches
    unless missing.empty?
      raise "mruby patches not applied: #{missing.join(', ')} (run scripts/bc2cpp/closed_build.bash, which applies them)"
    end

    FileUtils.mkdir_p(cache_dir)
    files = sources(closed_build)
    first_kinds, first_selves = pass(files, {}, cache_dir: cache_dir, jobs: jobs)
    external = first_kinds.reject { |_fn, kind| kind.nil? }
    # A function returning its own self parameter is the receiver's class wherever it is called (see
    # NativeAstReturns' identity rule), so a second-pass caller sees it as `self:N` for argument N.
    first_selves.each { |fn, index| external[fn] = "self:#{index}" if external[fn] == 'self' }
    second_kinds, second_selves = pass(files, external, cache_dir: cache_dir, jobs: jobs)
    second_kinds.sort.map do |fn, kind|
      index = second_selves[fn]
      [fn, kind.nil? ? 'unproven' : kind, index.nil? ? '' : index].join("\t")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  closed_build = ARGV.shift or abort 'usage: native_fn_kinds.rb CLOSED_BUILD_DIR'
  closed_build = File.expand_path(closed_build)
  puts NativeFnKinds.run(closed_build, cache_dir: File.join(closed_build, 'analysis', 'kinds-cache'))
end
