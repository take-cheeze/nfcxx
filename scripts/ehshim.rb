#!/usr/bin/env ruby
# Print the path of the EH shim object (lib/ehshim/nfcxx_eh_shim.cpp, docs/notes/eh-shim.md), building it first when it
# is missing or older than its source or EDG's runtime. The shim makes exceptions thrown by libstdc++.so (std::__throw_*
# functions) and std::exception_ptr work on EDG's exception runtime; the driver and the Path B test harness link the object into
# every hosted program.
#   NFCXX_EHSHIM=0       print nothing (link without the shim)
#   NFCXX_EHSHIM_DIR=d   where the object is kept (default build/ehshim)
# The object is compiled by nfcxx itself with the gcc backend (needs EDG: scripts/setup-edg.sh), so that its `throw`
# statements are EDG throws. It depends on the host g++ (headers), hence the version in the file name. When it cannot be
# built the script prints a warning on stderr and nothing on stdout: programs then link without the shim, as before.
# The host_gnu_version and host_dialect of scripts/host-sys.sh are ported here (same probes, same values).
require "fileutils"

# A variable that is unset or empty is nil (bash's ${VAR:-default}).
def env(name)
  v = ENV[name]
  v.nil? || v.empty? ? nil : v
end

# A command's standard output without its trailing newlines, and whether the command succeeded (its stderr is discarded).
def probe(*cmd)
  out = IO.popen(cmd, err: File::NULL, &:read)
  [out.sub(/\n+\z/, ""), $?.success?]
rescue SystemCallError
  ["", false]
end

# bash's `[ a -nt b ]`: a exists and is newer than b, or b does not exist.
def newer?(a, b)
  File.exist?(a) && (!File.exist?(b) || File.mtime(a) > File.mtime(b))
end

def cxx
  env("NFCXX_CXX") || "g++"
end

# host_dialect: clang when the host C++ compiler's first --version line says clang, else g++
def host_dialect
  out, ok = probe(cxx, "--version")
  ok && out.lines.first.to_s.match?(/clang/i) ? "clang" : "g++"
end

# host_gnu_version: major*10000 + minor*100 + patch of the host g++ (-dumpfullversion); clang has none, so 150000 (GCC 15)
def host_gnu_version
  out, ok = probe(cxx, "-dumpfullversion")
  ver = ok ? out : ""
  return "150000" if ver.empty? && host_dialect == "clang"
  return "" if ver.empty?
  maj, min, pat = ver.split(".", 3)
  (maj.to_i * 10000 + min.to_i * 100 + pat.to_i).to_s
end

# Runs a command; a failure ends the script with its status (bash's set -e).
def capture!(*cmd)
  out = IO.popen(cmd, &:read).sub(/\n+\z/, "")
  exit($?.exitstatus || 1) unless $?.success?
  out
end

exit 0 if ENV["NFCXX_EHSHIM"] == "0"
root = File.expand_path("..", File.expand_path(File.dirname($0)))
src = "#{root}/lib/ehshim/nfcxx_eh_shim.cpp"
dir = env("NFCXX_EHSHIM_DIR") || "#{root}/build/ehshim"
edg = env("EDG_BUILD") || "#{root}/build/edg"
# -tls: built against an EDG runtime whose exception handling state is thread-local (the eh-tls marker of
# scripts/setup-edg.sh): its references to that state are TLS ones, which do not link against the other runtime.
tls = File.file?("#{edg}/eh-tls") ? "-tls" : ""
out = "#{dir}/nfcxx_eh_shim-#{host_gnu_version}#{tls}.o"
rt = "#{edg}/lib/libC.a"   # an EDG rebuild rebuilds the shim too
if !File.file?(out) || newer?(src, out) || (File.file?(rt) && newer?(rt, out))
  FileUtils.mkdir_p(dir)
  tmp = capture!("mktemp", "-d", "#{dir}/.build.XXXXXX")
  at_exit { FileUtils.rm_rf(tmp) }
  # the driver of this checkout; NFCXX_PATH=b, NFCXX_BACKEND and NFCXX_CC (set by the qbe backend) must not redirect the shim to another compiler.
  # NFCXX_EH_UNWIND is unset too: the shim is linked into every hosted program, QBE ones included, and its copy of the
  # unwinder flag (lib/ehshim/nfcxx_eh_unwind.h, weak and 0 here) must stay 0 so that only gcc programs built with the gate use the unwinder.
  log = "#{tmp}/log"
  unset = { "NFCXX_PATH" => nil, "NFCXX_BACKEND" => nil, "NFCXX_CC" => nil, "NFCXX_EHSHIM" => nil, "NFCXX_EH_UNWIND" => nil }
  built = system(unset, "#{root}/nfcxx", "--backend=gcc", "-c", src, "-o", "#{tmp}/shim.o", out: log, err: [:child, :out])
  unless built
    warn "ehshim: cannot build #{src}; linking without it (exceptions thrown by libstdc++ will abort):"
    File.foreach(log).first(5).each { |l| warn l.chomp }
    exit 0
  end
  File.rename("#{tmp}/shim.o", out)   # atomic: concurrent builds each write their own copy
end
puts out
