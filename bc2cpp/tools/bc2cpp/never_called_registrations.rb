# frozen_string_literal: true

# Turns bc2cpp.rb's own "== never called ==" diagnostic (Step 6h, near the
# bottom of that file -- "a real candidate for deletion -- not proof of it")
# into an actual, safely-scoped list of *registered* method entries this
# project can stop registering: the intersection of "compiled and currently
# registered" with "zero evidence of any call site anywhere in this
# program's own bytecode or NATIVE_SRCS", further restricted to owners a
# missed call site genuinely cannot hide behind.
#
# That restriction is the whole point of this file, and it is not the same
# scope bc2cpp.rb's own diagnostic covers -- that diagnostic's own comment
# already explains why: RGSS's own Sprite/Window/Plane/Bitmap/Audio/
# Graphics/Input classes (mruby-rgss-compiled) ARE the public scripting API
# a downstream game's own bundled "stock scripts" call, invisible to any
# static analysis this tool can run -- a "never called" name there is the
# expected shape of a public API surface, not evidence of dead code. Only
# RPG2000/2003's own internal engine classes (Game::/RPG2k::/RPG2k3::/LCF::)
# have no such external-script layer at all -- every real call site to one
# of those has to originate from this project's own checked-in mrblib or
# NATIVE_SRCS, both of which bc2cpp.rb's own reachability scan already
# covers. mruby-lcf-compiled and mruby-rgss-compiled also each own a couple
# of general-purpose core classes (StringIO, bare Array) pulled in for
# cross-gem devirtualization reasons -- those are excluded by the same
# namespace check, not by gem name, since a name-based check would wrongly
# clear them just for sharing a gem with genuinely-internal classes.
#
# Separately, a wired-embedding owner (BC2CPP_WIRED_EMBEDDINGS) can never be
# safe to unregister regardless of call evidence: that mechanism's own
# soundness depends on EVERY compiled entry point of the class being
# installed together (see compiled_gems.rb's own EMBED_WIRED comment) -- an
# interpreted fallback for just one method reads the ordinary iv_tbl while
# every compiled sibling writes the RData struct instead, and sees nil.
#
# `.singleton`-owned entries are excluded too, conservatively: this file
# does not attempt the DEFS/SCLASS span-finding strip_wio_bc2cpp_stubs.rb's
# own comment already flags as out of scope for a related mechanism.
require 'open3'
require 'set'
require 'shellwords'
require 'tmpdir'
require_relative 'compiled_gems'

module NeverCalledRegistrations
  SAFE_UNREGISTER_OWNER_RE = /\A(?:Game|RPG2k3?|LCF)(?:::|\z)/

  module_function

  # Runs the *exact same* bc2cpp.rb invocation that `gem_name`'s own
  # mrbgem.rake performs for its real ONLY_OWNERS/OTHER_OWNERS/NATIVE_SRCS/
  # closed-world source set (mirroring wio_registered_methods.rb's own
  # probe, which this file's own callers replace) and returns its raw
  # stderr -- both the "== compiled entry points ==" and the "== never
  # called ==" sections live in that same stream.
  def run_bc2cpp(gem_name, repo_root, mrbc)
    run_bc2cpp_full(gem_name, repo_root, mrbc)[1]
  end

  # Same run as `run_bc2cpp`, returning [generated C++ (stdout), stderr].
  def run_bc2cpp_full(gem_name, repo_root, mrbc)
    this_gem = BC2CPP_COMPILED_GEMS.fetch(gem_name) do
      raise "never_called_registrations: no such compiled gem #{gem_name.inspect} in " \
            'tools/bc2cpp/compiled_gems.rb'
    end
    other_gems = BC2CPP_COMPILED_GEMS.reject { |name, _| name == gem_name }
    closed_world_srcs = closed_world_mrblib_srcs(repo_root)
    # Same canonical, target-independent native source set
    # wio_registered_methods.rb and scripts/bc2cpp_wired_embedding_check.rb
    # already use for this exact purpose -- see compiled_gems.rb's own
    # core_native_srcs/external_gem_native_srcs comments for why this list
    # never varies by platform (wio/desktop/wasm all share one
    # register.cxx per gem, so a target-specific native source set would
    # make one target's "never called" verdict unsound for the others).
    native_srcs = Dir["#{repo_root}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{repo_root}/3rd/mruby") +
                  external_gem_native_srcs(repo_root)

    bc2cpp = File.expand_path('bc2cpp.rb', __dir__)
    Dir.mktmpdir('bc2cpp_never_called_probe') do |tmp|
      env = {
        'MRBC' => mrbc,
        'OUT_SYMBOL' => 'never_called_probe',
        'OUT_DIR' => tmp,
        'ONLY_OWNERS' => this_gem[:owners].join(','),
        'OTHER_OWNERS' => other_gems.values.flat_map { |g| g[:owners] }.join(','),
        'NATIVE_SRCS' => Shellwords.join(native_srcs),
        'SKIP_UNSUPPORTED' => '1',
      }
      cmd = [RbConfig.ruby, bc2cpp, *closed_world_srcs]
      out, err, status = Open3.capture3(env, *cmd)
      unless status.success?
        warn err
        raise "never_called_registrations: #{gem_name}'s own bc2cpp.rb run failed (see stderr above)"
      end
      [out, err]
    end
  end

  # owner/name/entry/arity/visibility for every real compiled entry point,
  # parsed from bc2cpp.rb's own "== compiled entry points ==" section --
  # same regex shape as wio_registered_methods.rb's own parse (this is the
  # one other trustworthy source of that fact; see that file's own comment
  # for why neither file re-derives it by hand).
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

  # See this file's own header comment for the full reasoning: a namespace
  # check (not a gem-name check, since mruby-lcf-compiled/mruby-rgss-
  # compiled each also own general-purpose core classes) plus the wired-
  # embedding and `.singleton` exclusions.
  def safe_to_unregister?(owner)
    return false if owner.end_with?('.singleton')
    return false if BC2CPP_WIRED_EMBEDDINGS.include?(owner)

    owner.match?(SAFE_UNREGISTER_OWNER_RE)
  end

  # Every compiled entry point of `gem_name` that is both never-called (per
  # bc2cpp.rb's own whole-program scan) and owned by a class this file's own
  # safety rule clears -- a real candidate to stop registering, whether or
  # not register.cxx still has a line for it today. See
  # scripts/bc2cpp_prune_never_called_registrations.rb (which cross-checks
  # this against the real register.cxx before removing anything) and
  # scripts/bc2cpp_never_called_registrations_check.rb (which does the same
  # cross-check to decide whether there is really a regression to report).
  def prunable_entries(gem_name, repo_root, mrbc)
    stderr = run_bc2cpp(gem_name, repo_root, mrbc)
    compiled = parse_compiled_entries(stderr)
    never_called = parse_never_called_names(stderr)
    compiled.select { |m| never_called.include?("#{m[:owner]}##{m[:name]}") && safe_to_unregister?(m[:owner]) }
  end

  # The exact register.cxx line a real `mrb_define_method`/
  # `mrb_define_private_method` call for `entry` spans -- anchored on the
  # real, unique generated entry symbol (never the method name, which can
  # repeat across owners) so a match can never touch the wrong owner's
  # line. `mrb_define_class_method` is deliberately excluded:
  # `safe_to_unregister?` already drops every `.singleton` owner, so no
  # real entry this file ever calls prunable should use it.
  def registration_line_pattern(entry)
    /^[ \t]*mrb_define_(?:private_)?method\(\s*M\s*,\s*\w+\s*,\s*"[^"]*"\s*,\s*#{Regexp.escape(entry)}\s*,[^;]*\);\n/
  end

  # Whether `entry` still has a real registration line in `register_src`
  # (a register.cxx's own text) -- the ground truth
  # scripts/bc2cpp_prune_never_called_registrations.rb removes and
  # scripts/bc2cpp_never_called_registrations_check.rb re-checks against,
  # since `prunable_entries` above only answers "bc2cpp.rb could compile
  # this and nothing calls it", not "register.cxx still registers it
  # today".
  def registered_in_source?(register_src, entry)
    register_src.match?(registration_line_pattern(entry))
  end
end
