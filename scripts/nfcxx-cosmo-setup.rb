#!/usr/bin/env ruby
# nfcxx's --cosmo setup (stage B3 of docs/notes/driver-body-port.md), ported from the bash block in nfcxx: cosmocc is the C
# compiler, its libc++ headers are the C++ target, and the backend is gcc (or Path B with --backend=pathb). Checked against the
# bash block by tests/driver-cosmo/run.sh (the block copied verbatim, with a stub cosmocc).
#
#   ruby scripts/nfcxx-cosmo-setup.rb setup root=ROOT backend=NAME backend_explicit=0|1 path_b=0|1 gnu=VERSION
#       prints shell assignments for the driver to eval: backend, NFCXX_GCC, NFCXX_SYS_INCLUDES, gnu (only when it was empty and
#       the compiler reported a version) and the cflags additions. A refusal prints the bash's message to standard error, status 2.
#       The compiler is NFCXX_COSMOCC, else ROOT/build/cosmocc/bin/cosmocc.

require "shellwords"
require "open3"

module NfcxxCosmo
  module_function

  class Refusal < StandardError; end

  def q(s) = Shellwords.escape(s)

  # the gnu version the compiler reports, as the bash's awk turns it: each line of -dumpfullversion as %d%02d%02d
  def gnu_version(gver)
    out = begin
      Open3.capture3(gver, "-dumpfullversion")[0]
    rescue SystemCallError
      ""
    end
    out.each_line.map do |line|
      parts = line.chomp.split(".", -1)
      format("%d%02d%02d", parts[0].to_i, parts[1].to_i, parts[2].to_i)
    end.join("\n")
  end

  def setup(opts, env)
    root = opts.fetch("root")
    backend = opts.fetch("backend", "")
    backend_explicit = opts.fetch("backend_explicit", "0") == "1"
    path_b = opts.fetch("path_b", "0") == "1"
    gnu = opts.fetch("gnu", "")

    backend = "pathb" if path_b
    if backend != "pathb"
      if backend_explicit && backend != "gcc"
        raise Refusal, "nfcxx: --cosmo needs --backend=gcc or --backend=pathb"
      end
      backend = "gcc"
    end

    cosmo_bin = env["NFCXX_COSMOCC"].to_s.empty? ? File.join(root, "build/cosmocc/bin/cosmocc") : env["NFCXX_COSMOCC"]
    unless File.executable?(cosmo_bin)
      raise Refusal, "nfcxx: #{cosmo_bin} is not installed; run scripts/setup-cosmo.sh (or set NFCXX_COSMOCC)"
    end
    cosmo_root = File.expand_path(File.join(File.dirname(cosmo_bin), ".."))

    lines = []
    lines << "export NFCXX_GCC=#{q(cosmo_bin)}"
    lines << "export NFCXX_SYS_INCLUDES=#{q("#{cosmo_root}/include/third_party/libcxx:#{cosmo_root}/include")}"
    gver = File.join(cosmo_root, "bin/x86_64-linux-cosmo-g++")
    gver = cosmo_bin unless File.executable?(gver)
    if gnu.empty?
      lines << "gnu=#{q(gnu_version(gver))}"
    end

    cflags = %w[-D__COSMOPOLITAN__ -D__COSMOCC__ -D__FATCOSMOCC__]
    if backend == "pathb"
      cflags += ["-D__has_feature(x)=0", "-include", "#{cosmo_root}/include/libc/integral/normalize.inc",
                 "-include", "#{root}/lib/cosmo/libcxx_traits.h"]
    end
    lines << "backend=#{q(backend)}"
    lines << "cosmo_bin=#{q(cosmo_bin)}"
    lines << "cosmo_root=#{q(cosmo_root)}"
    lines << "cflags+=(#{cflags.map { |f| q(f) }.join(" ")})"
    lines
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-cosmo: setup KEY=VALUE... (got #{cmd.inspect})" unless cmd == "setup"
  opts = rest.to_h { |kv| kv.split("=", 2) }
  begin
    puts NfcxxCosmo.setup(opts, ENV)
  rescue NfcxxCosmo::Refusal => e
    warn e.message
    exit 2
  end
end
