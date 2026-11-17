#!/usr/bin/env ruby
# The backend's compiler environment (stage B3 of docs/notes/driver-body-port.md, restructure step 3), ported from the bash case
# in nfcxx: NFCXX_CC is the gcc-cc wrapper for the gcc and Path B backends. Path B needs a freestanding program's host (x86-64 and
# aarch64 Linux, arm64 macOS) and a built QBE. An unknown backend is refused. Checked against the bash by tests/driver-backend-env/run.sh.
#
#   ruby scripts/nfcxx-backend-env.rb plan backend=NAME freestanding=0|1 pb_fs_host=0|1 root=ROOT
#       prints the export statement for the driver to eval, or the refusal on standard error with status 2.

require "shellwords"

module NfcxxBackendEnv
  module_function

  class Refusal < StandardError; end

  def plan(opts)
    backend = opts.fetch("backend")
    freestanding = opts.fetch("freestanding") != "0"
    pb_fs = opts.fetch("pb_fs_host") == "1"
    root = opts.fetch("root")
    cc = "export NFCXX_CC=#{Shellwords.escape("#{root}/scripts/gcc-cc.rb")}"
    case backend
    when "pathb"
      if freestanding && !pb_fs
        raise Refusal, "nfcxx: Path B (--backend=pathb) compiles freestanding programs on x86-64 and aarch64 Linux and arm64 macOS only"
      end
      qbe = "#{root}/build/qbe/qbe"
      raise Refusal, "nfcxx: QBE not built; run scripts/setup-qbe.sh" unless File.executable?(qbe)
      cc
    when "gcc" then cc
    else raise Refusal, "nfcxx: unknown backend '#{backend}'"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-backend-env: plan KEY=VALUE... (got #{cmd.inspect})" unless cmd == "plan"
  begin
    puts NfcxxBackendEnv.plan(rest.to_h { |kv| kv.split("=", 2) })
  rescue NfcxxBackendEnv::Refusal => e
    warn e.message
    exit 2
  end
end
