#!/usr/bin/env ruby
# Build the Go interpreter that lib/poly (nfcpoly_go.cpp) embeds into build/poly-go/:
#   libnfcgo.so   yaegi (a Go interpreter written in Go) and the bridge of lib/poly/go, as a cgo c-shared library (~30 MB)
#   libnfcgo.h    the header cgo generated; scripts check that it declares the functions of lib/poly/go/nfcgo.h
# The host program is linked with -L build/poly-go -lnfcgo -Wl,-rpath,<that directory>. One library serves both back ends:
# it is Go code behind a plain C interface, and the C++ host (nfcxx, qbe or gcc) only calls into it.
# Needs Go (>= 1.24: weak pointers make the collector exact, from $GO, PATH or /usr/local/go/bin) and a C compiler for cgo, and the module proxy for the first build
# (yaegi is pinned in lib/poly/go/go.mod and go.sum; the module cache serves later builds offline).
#   FORCE=1   rebuild even if the library is newer than its sources
#   POLY_GO_DIR=DIR   build into DIR instead of build/poly-go (a private copy: build/ may be shared between checkouts)
# Exit status: 0 built (or up to date); 3 cannot be built here (no Go, Go too old, no C compiler, module proxy unreachable):
# tests/poly/run.sh reports that as a SKIP; 1 the build failed.
# Ruby port of setup-poly-go.sh: the external commands, their order and arguments are the same.
require "open3"

def which(cmd)
  return (File.file?(cmd) && File.executable?(cmd) ? cmd : nil) if cmd.include?("/")
  ENV.fetch("PATH", "").split(":", -1).each do |d|
    f = File.join(d.empty? ? "." : d, cmd)
    return f if File.file?(f) && File.executable?(f)
  end
  nil
end

# Runs an external command and returns its exit status (127 when it cannot start, as the shell does).
def run(argv, env: {}, chdir: nil, out: nil, err: nil)
  opts = {}
  opts[:chdir] = chdir if chdir
  opts[:out] = out if out
  opts[:err] = err if err
  pid = Process.spawn(env, *argv, **opts)
  Process.wait(pid)
  $?.exitstatus || 1
rescue SystemCallError
  127
end

# $(...) of a command: its standard output without trailing newlines, and its status.
def capture(argv, err: File::NULL)
  out, st = Open3.capture2(*argv, err: err)
  [out.sub(/\n+\z/, ""), st.exitstatus || 1]
rescue SystemCallError
  ["", 127]
end

# test -nt: a is newer than b, or a exists and b does not
def newer?(a, b)
  return false unless File.exist?(a)
  return true unless File.exist?(b)
  File.mtime(a) > File.mtime(b)
end

# $(nproc 2>/dev/null || sysctl -n hw.ncpu)
def jobs
  out, st = capture(["nproc"])
  return out if st == 0
  capture(["sysctl", "-n", "hw.ncpu"])[0]
end

# xargs -P N: runs the commands of items, N at a time, in input order when N is 1; true when all succeeded
def parallel(n, items, &blk)
  queue = Queue.new
  items.each { |i| queue << i }
  queue.close
  ok = true
  lock = Mutex.new
  threads = Array.new([n.to_i, 1].max) do
    Thread.new do
      while (item = queue.pop)
        good = blk.call(item) == 0
        lock.synchronize { ok &&= good }
      end
    end
  end
  threads.each(&:join)
  ok
end


# true when a *.go file under dir is newer than ref (find DIR -name '*.go' -newer REF)
def go_source_newer?(dir, ref)
  require "find"
  Find.find(dir).any? { |p| File.fnmatch?("*.go", File.basename(p)) && newer?(p, ref) }
end

# grep -oE 'nfcgo_[a-z_]+\(' | sort -u | tr '\n' ' ': the names of the functions in a header, as one string
def header_names(text)
  text.scan(/nfcgo_[a-z_]+\(/).uniq.sort.map { |m| m + " " }.join
end

self_path = File.realpath($PROGRAM_NAME)
Dir.chdir(File.join(File.dirname(File.expand_path($PROGRAM_NAME)), ".."))
root = Dir.pwd
work = ENV["POLY_GO_DIR"].to_s.empty? ? File.join(root, "build/poly-go") : ENV["POLY_GO_DIR"]
src = File.join(root, "lib/poly/go")
lib = "#{work}/libnfcgo.so"
skip = lambda { |msg| $stderr.puts "setup-poly-go: #{msg}"; exit 3 }
fresh = lambda do
  File.file?(lib) && File.file?("#{work}/libnfcgo.h") && newer?(lib, self_path) && newer?(lib, "#{src}/go.mod") &&
    newer?(lib, "#{src}/go.sum") && !go_source_newer?(src, lib) && newer?(lib, "#{src}/nfcgo.h")
end
exit 0 if ENV["FORCE"].to_s.empty? && fresh.call

gobin = ENV["GO"].to_s
if !gobin.empty?
  skip.call("GO=#{gobin} is not an executable") unless which(gobin)
else
  gobin = which("go") || ""
  gobin = "/usr/local/go/bin/go" if gobin.empty? && File.executable?("/usr/local/go/bin/go")
  skip.call("Go not found (install Go >= 1.24 or set GO=/path/to/go)") if gobin.empty?
end
ver_out, = capture([gobin, "env", "GOVERSION"])
ver = ver_out.lines.map { |l| l.sub(/\Ago/, "") }.join.sub(/\n+\z/, "")
unless ver.match?(/\A(?:1\.2[4-9].*|1\.[3-9][0-9].*|[2-9].*)\z/m)
  skip.call("Go >= 1.24 is needed, found '#{ver.empty? ? "unknown" : ver}' (#{gobin})")
end
cc = ENV["CC"].to_s.empty? ? "gcc" : ENV["CC"]
skip.call("no C compiler (#{cc}) for cgo") unless which(cc)

run(["mkdir", "-p", work])
if ENV["HOME"].to_s.empty?   # go needs a place for its build cache
  ENV["HOME"] = "#{work}/home"
  run(["mkdir", "-p", ENV["HOME"]])
end
lock = File.open("#{work}/.lock", "w")
lock.flock(File::LOCK_EX) if which("flock")
exit 0 if ENV["FORCE"].to_s.empty? && fresh.call

log = "#{work}/build.log"
File.write(log, "")
tmp = "#{work}/new.#{Process.pid}"
run(["rm", "-rf", tmp])
run(["mkdir", "-p", tmp])
at_exit { run(["rm", "-rf", tmp]) }
# GOTOOLCHAIN=local: never download another toolchain. go.sum is committed and must match.
built = run([gobin, "build", "-trimpath", "-buildmode=c-shared", "-o", "#{tmp}/libnfcgo.so", "."],
            chdir: src, env: { "GOTOOLCHAIN" => "local", "CGO_ENABLED" => "1", "CC" => cc },
            out: [log, "a"], err: [:child, :out])
unless built == 0
  if File.read(log).match?(/proxy\.golang\.org|dial tcp|no such host|i\/o timeout|connection refused|TLS handshake|network is unreachable|server misbehaving|Temporary failure|403 Forbidden|reading https?:\/\//i)
    run(["tail", "-5", log], out: $stderr)
    skip.call("cannot download the Go modules (yaegi): the module proxy is unreachable; build once with network access (log: #{log})")
  end
  run(["tail", "-30", log], out: $stderr)
  $stderr.puts "setup-poly-go: build failed (full log: #{log})"
  exit 1
end
unless File.file?("#{tmp}/libnfcgo.h")
  $stderr.puts "setup-poly-go: cgo produced no header"
  exit 1
end
want = header_names(File.read("#{tmp}/libnfcgo.h"))
hdr = "#{src}/nfcgo.h"
if File.file?(hdr)
  have = header_names(File.foreach(hdr).select { |l| l.match?(/^[a-z]/) }.join)
else
  $stderr.puts "grep: #{hdr}: No such file or directory"   # grep, which reads it in the shell, reports this and matches nothing
  have = header_names("")
end
if want != have
  $stderr.puts "setup-poly-go: lib/poly/go/nfcgo.h and the cgo header disagree: cgo exports [#{want}], nfcgo.h declares [#{have}]"
  exit 1
end
run(["mv", "#{tmp}/libnfcgo.h", "#{work}/libnfcgo.h"])
run(["mv", "#{tmp}/libnfcgo.so", lib])
goversion, = capture([gobin, "env", "GOVERSION"])
yaegi = File.read("#{src}/go.mod").scan(/traefik\/yaegi v[0-9.]*/).map { |m| m.split(" ")[1] }.join("\n")
$stderr.puts "setup-poly-go: built #{lib} (#{goversion}, yaegi #{yaegi})"
