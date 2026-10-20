# frozen_string_literal: true

require 'open3'
require 'shellwords'
require 'tmpdir'
require 'fileutils'
require_relative 'compiled_gems'
require_relative 'nomethod_reviewed_probe'

# TYPE_CHECK (docs/adr/0412): runs bc2cpp.rb's analysis for scripts/bc2cpp/type_check.rb and the checks, and returns the
# facts file (type_facts.rb) and the receiver-proof rows it wrote. The generated C++ is discarded; nothing is compiled.
module TypeCheckRun
  Result = Struct.new(:facts_path, :rows_path, :stderr_path, :status, keyword_init: true)

  module_function

  # The environment of a whole-program run. `sources` nil is the engine's own world (the three compiled gems with
  # the mruby core mrblib, as coverage_report.rb runs it); otherwise it is a list of Ruby files that ARE the program,
  # analysed in the same closed world (core natives and mrblib as the outside world) -- a fixture or a project.
  def env(root:, mrbc:, workdir:, sources: nil, sends: true, what_if: false, sig_dirs: nil, display_root: root)
    natives = Dir["#{root}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{root}/3rd/mruby") + external_gem_native_srcs(root)
    env = {
      'MRBC' => mrbc, 'OUT_SYMBOL' => 'type_check', 'OUT_DIR' => workdir, 'SKIP_UNSUPPORTED' => '1',
      'NATIVE_SRCS' => Shellwords.join(natives), 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(root)),
      'BC2CPP_BUILD_NAME' => 'closed', 'BC2CPP_COLLECTION_EXPORTS' => '1',
      'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.closed_gems(root).map { |n, d| "#{n}=#{d}" }),
      'BC2CPP_TYPE_CHECK_ONLY' => '1',
      'BC2CPP_TYPE_FACTS' => File.join(workdir, 'facts.json'), 'BC2CPP_TYPE_FACTS_ROOT' => display_root, 'BC2CPP_SIG_ROOT' => display_root
    }
    if sources
      env['BC2CPP_SELF_REGISTERING'] = '1'
    else
      env['ONLY_OWNERS'] = BC2CPP_COMPILED_GEMS.values.flat_map { |g| g[:owners] }.join(',')
    end
    if sends
      env['BC2CPP_RECEIVER_PROOF_REPORT'] = File.join(workdir, 'rows.tsv')
      env['BC2CPP_RECEIVER_PROOF_NO_WHATIF'] = '1' unless what_if
    end
    env['BC2CPP_SIG_DIRS'] = Array(sig_dirs).join(File::PATH_SEPARATOR) if sig_dirs
    env
  end

  # Runs the analysis; raises with the tail of bc2cpp's stderr when it fails.
  def run(root:, mrbc:, workdir:, sources: nil, sends: true, what_if: false, sig_dirs: nil, extra_env: {}, display_root: root, tools_dir: File.join(root, 'tools/bc2cpp'))
    e = env(root: root, mrbc: mrbc, workdir: workdir, sources: sources, sends: sends, what_if: what_if, sig_dirs: sig_dirs,
            display_root: display_root)
    e.merge!(extra_env)
    srcs = sources ? sources.map { |s| File.expand_path(s) } : closed_world_mrblib_srcs(root)
    err_path = File.join(workdir, 'bc2cpp.stderr')
    bc2cpp = File.join(tools_dir, 'bc2cpp.rb')
    ok = system(e, RbConfig.ruby, bc2cpp, '--annotated', *srcs, out: File::NULL, err: err_path)
    raise "bc2cpp.rb failed (analysis for the type check):\n#{NomethodReviewedProbe.failure_tail(File.read(err_path))}" unless ok

    Result.new(facts_path: e['BC2CPP_TYPE_FACTS'], rows_path: e['BC2CPP_RECEIVER_PROOF_REPORT'], stderr_path: err_path,
               status: 0)
  end
end
