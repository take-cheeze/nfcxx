# frozen_string_literal: true

# Runs bc2cpp.rb the way each compiled gem's mrbgem.rake does and parses its
# "== compiled entry points ==" and "== never called ==" diagnostics, for the
# registration proof (static_dispatch_registrations.rb).
#
# SAFE_UNREGISTER_OWNER_RE: only the RPG2000/2003 engine namespaces
# (Game::/RPG2k::/RPG2k3::/LCF::) qualify for the open list. RGSS classes are
# the public scripting API a game's own scripts call, invisible to static
# analysis. The check is by namespace, not by gem, so core classes owned by a
# compiled gem (StringIO, Array) stay excluded.
require 'open3'
require 'set'
require 'shellwords'
require 'tmpdir'
require 'fileutils'
require_relative 'compiled_gems'
require_relative 'shared_generation'
require_relative 'closed_world_env'
require_relative 'static_dispatch_lists'

module NeverCalledRegistrations
  SAFE_UNREGISTER_OWNER_RE = /\A(?:Game|RPG2k3?|LCF)(?:::|\z)/

  module_function

  # Runs the exact bc2cpp.rb invocation `gem_name`'s mrbgem.rake performs and
  # returns its stderr (both the "== compiled entry points ==" and the
  # "== never called ==" sections).
  def run_bc2cpp(gem_name, repo_root, mrbc)
    run_bc2cpp_full(gem_name, repo_root, mrbc)[1]
  end

  # Same run as `run_bc2cpp`, returning [generated C++ (stdout), stderr].
  def run_bc2cpp_full(gem_name, repo_root, mrbc)
    run_bc2cpp_full_many([gem_name], repo_root, mrbc).fetch(gem_name)
  end

  # run_bc2cpp_full for several gems: { gem_name => [stdout, stderr] }. The runs differ only in which owners they
  # emit, so they share one analysis: what each returns is what its own run returns.
  # lists_path: the static dispatch lists the probe generates with (static_dispatch_lists.rb): the proof feeds each
  # pass the previous pass's output, and 'none' is the first pass.
  def run_bc2cpp_full_many(gem_names, repo_root, mrbc, lists_path: 'none')
    return {} if gem_names.empty?

    gem_names.each do |gem_name|
      next if BC2CPP_COMPILED_GEMS.key?(gem_name)

      raise "never_called_registrations: no such compiled gem #{gem_name.inspect} in tools/bc2cpp/compiled_gems.rb"
    end
    closed_world_srcs = closed_world_mrblib_srcs(repo_root, core_gems: :canonical)
    # The canonical, target-independent native source set (as in
    # the wired-embedding registration above): every target
    # shares one generated registration per gem, so a target-specific set would make one
    # target's "never called" verdict unsound for the others.
    native_srcs = Dir["#{repo_root}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{repo_root}/3rd/mruby") +
                  external_gem_native_srcs(repo_root)
    # The Ruby half of the same outside world, as every *-compiled mrbgem.rake passes it (foreign_mrblib_srcs is
    # target-independent too). Without it the analyses that need both halves (INTEGER_CONSTANT_PROOF, the
    # RBS_CHECKED_PARAMS caller scan) see a different program than the build compiles.
    foreign_ruby_srcs = foreign_mrblib_srcs(repo_root)

    bc2cpp = File.expand_path('bc2cpp.rb', __dir__)
    Dir.mktmpdir('bc2cpp_never_called_probe') do |tmp|
      common = {
        'MRBC' => mrbc,
        'NATIVE_SRCS' => Shellwords.join(native_srcs),
        'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_ruby_srcs),
        'SKIP_UNSUPPORTED' => '1',
        StaticDispatchLists::PATH_ENV => lists_path,
      }
      units = gem_names.map do |gem_name|
        dir = FileUtils.mkdir_p(File.join(tmp, gem_name)).first
        {
          'OUT_SYMBOL' => 'never_called_probe',
          'OUT_DIR' => dir,
          'ONLY_OWNERS' => BC2CPP_COMPILED_GEMS.fetch(gem_name)[:owners].join(','),
          'OTHER_OWNERS' => BC2CPP_COMPILED_GEMS.reject { |name, _| name == gem_name }.values.flat_map { |g| g[:owners] }.join(','),
        }
      end
      results = SharedGeneration.run(tool: bc2cpp, srcs: closed_world_srcs, common_env: bc2cpp_closed_world_probe_env(common, repo_root), unit_envs: units,
                                      extra_args: ['--annotated'])
      gem_names.zip(results).to_h do |gem_name, (out, err, status)|
        unless status.success?
          warn err
          raise "never_called_registrations: #{gem_name}'s own bc2cpp.rb run failed (see stderr above)"
        end
        [gem_name, [out, err]]
      end
    end
  end

  # owner/name/entry/arity/visibility for every compiled entry point, parsed
  # from bc2cpp.rb's "== compiled entry points ==" section.
  def parse_compiled_entries(stderr)
    section = stderr.split('== compiled entry points ==', 2)[1]
    return [] unless section

    section = section.split(/\n== /, 2)[0]
    section.each_line.filter_map do |line|
      m = line.match(/^\s+(\S+) \/ \S+\s+\((\S+)#([^,]+), arity (\d+)\)(.*)$/)
      next unless m

      entry, owner, name, arity, rest = m.captures
      visibility =
        if rest.include?('[private')
          :private
        elsif rest.include?('[protected')
          :protected
        else
          :public
        end
      { entry: entry, owner: owner, name: name, arity: arity.to_i, visibility: visibility }
    end
  end

  # The "Owner#name" set bc2cpp.rb's own "== never called ==" section
  # lists -- zero evidence in this program's own bytecode or NATIVE_SRCS.
  def parse_never_called_names(stderr)
    section = stderr.split(/== never called \(\d+ of \d+ compiled entry points[^\n]*\n/, 2)[1]
    return Set.new unless section

    section = section.split(/\n== /, 2)[0]
    section.each_line.filter_map { |l| l.chomp[/\A {2}(\S+)\z/, 1] }.reject { |n| n == '(none)' }.to_set
  end
end
