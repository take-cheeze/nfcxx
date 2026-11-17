#!/usr/bin/env ruby
# --target=linux_k1om (stage B3/restructure step 3 of docs/notes/driver-body-port.md), ported from the bash in nfcxx: Intel
# Knights Corner is freestanding, with the gcc backend (the k1om GCC). The toolchain (NFCXX_K1OM_ROOT, default /opt/k1om) and
# the runtime (build/k1om/libC.a) must be there. Its compiler environment is NFCXX_GCC, NFCXX_AS and NFCXX_K1OM_ROOT; the
# backend becomes gcc. Checked against the bash by tests/driver-k1om/run.sh.
#
#   ruby scripts/nfcxx-k1om.rb plan target=NAME freestanding=0|1 backend_explicit=0|1 backend=NAME root=ROOT
#       prints the statements for the driver to eval (backend=gcc and the exports), or the refusal on standard error, status 2.
#       NFCXX_K1OM_ROOT is read from the environment.

require "shellwords"

module NfcxxK1om
  module_function

  class Refusal < StandardError; end

  def plan(opts, env)
    return "" unless opts.fetch("target") == "linux_k1om"
    freestanding = opts.fetch("freestanding") == "1"
    explicit = opts.fetch("backend_explicit") == "1"
    backend = opts.fetch("backend")
    root = opts.fetch("root")
    raise Refusal, "nfcxx: --target=linux_k1om needs --freestanding (the host's C++ headers are GCC 13's, not k1om's)" unless freestanding
    raise Refusal, "nfcxx: --target=linux_k1om uses the gcc backend (the k1om GCC)" if explicit && backend != "gcc"
    k1om_root = env["NFCXX_K1OM_ROOT"].to_s.empty? ? "/opt/k1om" : env["NFCXX_K1OM_ROOT"]
    unless File.executable?(File.join(k1om_root, "bin/k1om-mpss-linux-gcc"))
      raise Refusal, "nfcxx: no k1om toolchain at #{k1om_root} (NFCXX_K1OM_ROOT; docs/notes/k1om.md)"
    end
    unless File.file?(File.join(root, "build/k1om/libC.a"))
      raise Refusal, "nfcxx: no k1om runtime at #{root}/build/k1om/libC.a (run scripts/setup-k1om.sh)"
    end
    [
      "backend=gcc",
      "k1om_root=#{Shellwords.escape(k1om_root)}",
      "export NFCXX_GCC=#{Shellwords.escape("#{root}/scripts/k1om-cc.rb")} NFCXX_AS=#{Shellwords.escape("#{root}/scripts/k1om-bin/as.rb")} NFCXX_K1OM_ROOT=#{Shellwords.escape(k1om_root)}",
    ].join("\n")
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-k1om: plan KEY=VALUE... (got #{cmd.inspect})" unless cmd == "plan"
  begin
    out = NfcxxK1om.plan(rest.to_h { |kv| kv.split("=", 2) }, ENV)
    puts out unless out.empty?
  rescue NfcxxK1om::Refusal => e
    warn e.message
    exit 2
  end
end
