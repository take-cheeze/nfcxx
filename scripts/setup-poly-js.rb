#!/usr/bin/env ruby
# Build the QuickJS-NG that lib/poly (nfcpoly_js.cpp) embeds into build/poly-js/<backend>/:
#   lib/libquickjs.a   the engine: quickjs.c, dtoa.c, libregexp.c, libunicode.c
#   include/           quickjs.h; give the host program -I build/poly-js/<backend>/include
# QuickJS reports errors as return values (JS_EXCEPTION), never with setjmp/longjmp or a throw, so every file is plain C
# built by nfcc: no C++ build is needed (unlike mruby and Lua). Not built: quickjs-libc.c, qjs.c, qjsc.c. A script gets
# no files, no `os`, no `std`, no module loader, and no timers unless the host binds them.
# QuickJS is compiled without -D_GNU_SOURCE (its CMakeLists defines it, but nothing in the sources needs it on Linux).
#   NFCXX_BACKEND=pathb|gcc   back end of the C compiler (default pathb); one build tree per back end
#   FORCE=1                   rebuild even if the library is newer than this script
# Needs flock and ar; the gcc back end needs gcc, Path B the harness (scripts/setup-pathb.sh). The
# source is fetched from GitHub at the pin and built unmodified. Its interpreter loop uses computed goto (`goto *`
# after each of about 250 opcodes): Path B compiles it with one shared dispatch switch (docs/notes/pathb-computed-goto.md).
# Ruby port of setup-poly-js.sh: the external commands, their order and arguments are the same.
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

self_path = File.realpath($PROGRAM_NAME)
Dir.chdir(File.join(File.dirname(File.expand_path($PROGRAM_NAME)), ".."))
root = Dir.pwd
work = File.join(root, "build/poly-js")
be = ENV["NFCXX_BACKEND"]
be = "pathb" if be.nil? || be.empty?
unless %w[gcc pathb].include?(be)
  $stderr.puts "setup-poly-js: NFCXX_BACKEND must be pathb or gcc, not '#{be}'"
  exit 1
end
pin = "6d46d07d04041b40f4f49eaa7fdebe44c314c699"   # quickjs-ng/quickjs tag v0.17.0
src = "#{work}/src"
out = "#{work}/out-#{be}"
dest = "#{work}/#{be}"
fresh = lambda { File.file?("#{dest}/lib/libquickjs.a") && newer?("#{dest}/lib/libquickjs.a", self_path) }
exit 0 if ENV["FORCE"].to_s.empty? && fresh.call
if be == "pathb" && !File.executable?("#{root}/build/pathb/cmake/bin/cpfe") && ENV["PATHB_CPFE"].to_s.empty?
  $stderr.puts "setup-poly-js: the Path B harness is not built; run scripts/setup-pathb.sh"
  exit 1
end
run(["mkdir", "-p", work])
lock = File.open("#{work}/.lock", "w")
lock.flock(File::LOCK_EX) if which("flock")
exit 0 if ENV["FORCE"].to_s.empty? && fresh.call

unless File.directory?("#{src}/.git")
  ok = run(["mkdir", "-p", src]) == 0 &&
       run(["git", "-C", src, "init", "-q"]) == 0 &&
       run(["git", "-C", src, "remote", "add", "origin", "https://github.com/quickjs-ng/quickjs"]) == 0
  exit 1 unless ok
end
out_rev, = capture(["git", "-C", src, "rev-parse", "-q", "--verify", "#{pin}^{commit}"])
if out_rev != pin
  unless run(["git", "-C", src, "fetch", "-q", "--depth", "1", "origin", pin], env: { "GIT_LFS_SKIP_SMUDGE" => "1" }) == 0
    $stderr.puts "setup-poly-js: fetching QuickJS-NG #{pin} failed"
    exit 1
  end
end
exit 1 unless run(["git", "-C", src, "reset", "-q", "--hard", pin]) == 0
exit 1 unless run(["git", "-C", src, "clean", "-q", "-fdx"]) == 0
run(["rm", "-rf", out])
run(["mkdir", "-p", out])
log = "#{work}/build-#{be}.log"
File.write(log, "")
# quickjs.c is the long pole (about 25 s on the gcc back end), so it starts first.
names = %w[quickjs dtoa libregexp libunicode]
ok = parallel(jobs, names) do |n|
  run(["#{root}/nfcc", "-c", "-O2", "-I#{src}", "#{src}/#{n}.c", "-o", "#{out}/#{n}.o"],
      env: { "NFCXX_BACKEND" => be }, out: [log, "a"], err: [:child, :out])
end
unless ok
  run(["tail", "-30", log], out: $stderr)
  $stderr.puts "setup-poly-js: build failed (full log: #{log})"
  exit 1
end
run(["rm", "-f", "#{out}/libquickjs.a"])
run(["ar", "rcs", "#{out}/libquickjs.a", *names.map { |n| "#{out}/#{n}.o" }])
run(["rm", "-rf", "#{dest}.new"])
run(["mkdir", "-p", "#{dest}.new/lib", "#{dest}.new/include"])
run(["cp", "#{out}/libquickjs.a", "#{dest}.new/lib/libquickjs.a"])
run(["cp", "#{src}/quickjs.h", "#{dest}.new/include/"])
run(["rm", "-rf", dest])
run(["mv", "#{dest}.new", dest])
$stderr.puts "setup-poly-js: built #{dest}/lib/libquickjs.a (backend #{be}, QuickJS-NG v0.17.0)"
