# frozen_string_literal: true

# Turns bc2cpp.rb's "== never called ==" diagnostic (a candidate for deletion,
# not proof of it) into the registered entries this project can stop
# registering: compiled and registered, with no call site in the program's
# bytecode or NATIVE_SRCS, and owned by a class a missed call site cannot hide
# behind.
#
# Only the RPG2000/2003 engine namespaces (Game::/RPG2k::/RPG2k3::/LCF::)
# qualify: RGSS classes are the public scripting API a game's own scripts
# call, invisible to static analysis. The check is by namespace, not by gem,
# so core classes owned by a compiled gem (StringIO, Array) stay excluded.
#
# A wired-embedding owner (BC2CPP_WIRED_EMBEDDINGS) is never safe to
# unregister: every compiled entry of the class must be installed together
# (see compiled_gems.rb's EMBED_WIRED comment), or an interpreted fallback
# reads the ordinary iv_tbl and sees nil.
#
# `.singleton` owners are excluded too, conservatively (no DEFS/SCLASS
# span-finding, as in strip_wio_bc2cpp_stubs.rb).
require 'open3'
require 'set'
require 'shellwords'
require 'tmpdir'
require_relative 'compiled_gems'

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
    this_gem = BC2CPP_COMPILED_GEMS.fetch(gem_name) do
      raise "never_called_registrations: no such compiled gem #{gem_name.inspect} in " \
            'tools/bc2cpp/compiled_gems.rb'
    end
    other_gems = BC2CPP_COMPILED_GEMS.reject { |name, _| name == gem_name }
    closed_world_srcs = closed_world_mrblib_srcs(repo_root)
    # The canonical, target-independent native source set (as in
    # wio_registered_methods.rb and bc2cpp_wired_embedding_check.rb): every target
    # shares one register.cxx per gem, so a target-specific set would make one
    # target's "never called" verdict unsound for the others.
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

  # owner/name/entry/arity/visibility for every compiled entry point, parsed
  # from bc2cpp.rb's "== compiled entry points ==" section (same regex as
  # wio_registered_methods.rb).
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

  # See the header comment: a namespace check plus the wired-embedding and
  # `.singleton` exclusions.
  def safe_to_unregister?(owner)
    return false if owner.end_with?('.singleton')
    return false if BC2CPP_WIRED_EMBEDDINGS.include?(owner)

    owner.match?(SAFE_UNREGISTER_OWNER_RE)
  end

  # Every compiled entry point of `gem_name` that is never called and whose
  # owner passes safe_to_unregister?, whether or not register.cxx still
  # registers it. scripts/bc2cpp_prune_never_called_registrations.rb and
  # scripts/bc2cpp_never_called_registrations_check.rb cross-check it against
  # the real register.cxx.
  def prunable_entries(gem_name, repo_root, mrbc)
    stderr = run_bc2cpp(gem_name, repo_root, mrbc)
    compiled = parse_compiled_entries(stderr)
    never_called = parse_never_called_names(stderr)
    compiled.select { |m| never_called.include?("#{m[:owner]}##{m[:name]}") && safe_to_unregister?(m[:owner]) }
  end

  # The register.cxx line a `mrb_define_method`/`mrb_define_private_method` call
  # for `entry` spans, anchored on the unique generated entry symbol (never the
  # method name, which repeats across owners). `mrb_define_class_method` is
  # excluded: safe_to_unregister? already drops every `.singleton` owner.
  def registration_line_pattern(entry)
    /^[ \t]*mrb_define_(?:private_)?method\(\s*M\s*,\s*\w+\s*,\s*"[^"]*"\s*,\s*#{Regexp.escape(entry)}\s*,[^;]*\);\n/
  end

  # Whether `entry` still has a registration line in `register_src` -- the
  # ground truth the prune script and check use, since `prunable_entries` only
  # says "compiles and nothing calls it".
  def registered_in_source?(register_src, entry)
    register_src.match?(registration_line_pattern(entry))
  end

  # The C++ entry-point identifiers any `mrb_define_(private_|class_)?method`
  # or generated `bc2cpp_define_private_class_method` call installs, across
  # the gem's hand register.cxx and bc2cpp.rb's own generated
  # bc2cpp_register_owner_methods -- the same shape
  # scripts/bc2cpp_wired_embedding_check.rb matches. A name argument may be
  # a string literal or a macro/variable; the function is always the fourth.
  # Comments are dropped first: register.cxx quotes calls in prose.
  INSTALL_CALL = /(?:mrb_define_(?:private_|class_)?method|bc2cpp_define_private_class_method)\(\s*M\s*,\s*[^,]+,\s*(?:"[^"]*"|\S+)\s*,\s*(\w+)\s*,/m

  def installed_entries(*sources)
    sources.flat_map do |src|
      src.gsub(%r{/\*.*?\*/}m, '').gsub(%r{//[^\n]*}, '').scan(INSTALL_CALL).flatten
    end.to_set
  end
end
