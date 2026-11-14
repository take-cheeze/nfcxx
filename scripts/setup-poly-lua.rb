#!/usr/bin/env ruby
# Build the Lua that lib/poly (nfcpoly_lua.cpp) embeds, with C++ exceptions, into build/poly-lua/<backend>/:
#   lib/liblua.a   the Lua 5.4 core and the base, coroutine, table, string, math and utf8 libraries
#   include/       lua.h, luaconf.h, lauxlib.h, lualib.h; give the host program -I build/poly-lua/<backend>/include
# Lua has two ways to raise an error: longjmp, or, when the file is compiled as C++, throw. ldo.c is the only file that
# does either, so it is built as C++ by nfcxx (in a generated wrapper that includes it inside extern "C") and every other
# file as C by nfcc: a Lua error is then a throw on EDG's exception runtime, the one the host's throw and catch use, and it
# runs the destructors of the C++ frames it crosses. See docs/notes/poly.md.
# Not built: lua.c, luac.c, linit.c (it would open io, os, package, debug), liolib.c, loslib.c, loadlib.c, ldblib.c. A script
# gets no files, no os.exit and no clock unless the host binds them.
#   NFCXX_BACKEND=pathb|gcc   back end of both compilers (default pathb); one build tree per back end
#   FORCE=1                 rebuild even if the library is newer than this script
# Needs EDG (scripts/setup-edg.sh) and, for the pathb back end, the Path B harness (scripts/setup-pathb.sh). The Lua source
# is fetched from GitHub at the pin below, unpatched.
# Ruby port of setup-poly-lua.sh: the external commands, their order and arguments are the same.
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

# a shell glob: its matches, sorted, or the pattern itself when nothing matches
def shell_glob(pattern)
  found = Dir.glob(pattern).sort
  found.empty? ? [pattern] : found
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
work = File.join(root, "build/poly-lua")
be = ENV["NFCXX_BACKEND"]
be = "pathb" if be.nil? || be.empty?
unless %w[gcc pathb].include?(be)
  $stderr.puts "setup-poly-lua: NFCXX_BACKEND must be pathb or gcc, not '#{be}'"
  exit 1
end
pin = "312b9efaa1061c2c4cad08554dbc1351c3270eef"   # lua/lua tag v5.4.9, same pin as tests/realworld/run_lua.sh
src = "#{work}/src"
out = "#{work}/out-#{be}"
dest = "#{work}/#{be}"
fresh = lambda { File.file?("#{dest}/lib/liblua.a") && newer?("#{dest}/lib/liblua.a", self_path) }
exit 0 if ENV["FORCE"].to_s.empty? && fresh.call
unless File.executable?("#{root}/build/edg/bin/eccp")
  $stderr.puts "setup-poly-lua: EDG not built; run scripts/setup-edg.sh"
  exit 1
end
run(["mkdir", "-p", work])
lock = File.open("#{work}/.lock", "w")
lock.flock(File::LOCK_EX) if which("flock")
exit 0 if ENV["FORCE"].to_s.empty? && fresh.call

unless File.directory?("#{src}/.git")
  ok = run(["mkdir", "-p", src]) == 0 &&
       run(["git", "-C", src, "init", "-q"]) == 0 &&
       run(["git", "-C", src, "remote", "add", "origin", "https://github.com/lua/lua"]) == 0
  exit 1 unless ok
end
out_rev, = capture(["git", "-C", src, "rev-parse", "-q", "--verify", "#{pin}^{commit}"])
if out_rev != pin
  unless run(["git", "-C", src, "fetch", "-q", "--depth", "1", "origin", pin]) == 0
    $stderr.puts "setup-poly-lua: fetching Lua #{pin} failed"
    exit 1
  end
end
exit 1 unless run(["git", "-C", src, "reset", "-q", "--hard", pin]) == 0
run(["rm", "-rf", out])
run(["mkdir", "-p", out])
# the files, sorted as the shell's glob sorts them; the programs and the libraries that are not built are left out
skipped = %w[lua.c luac.c ltests.c onelua.c linit.c liolib.c loslib.c loadlib.c ldblib.c]
files = shell_glob("#{src}/l*.c").reject { |f| skipped.include?(File.basename(f)) }
File.write("#{out}/ldo-cxx.cpp", "extern \"C\" {\n#include \"#{src}/ldo.c\"\n}\n")
log = "#{work}/build-#{be}.log"
File.write(log, "")
ok = parallel(jobs, files) do |f|
  b = File.basename(f, ".c")
  if b == "ldo"
    run(["#{root}/nfcxx", "-c", "-O2", "-I#{src}", "#{out}/ldo-cxx.cpp", "-o", "#{out}/ldo.o"],
        env: { "NFCXX_BACKEND" => be }, out: [log, "a"], err: [:child, :out])
  else
    run(["#{root}/nfcc", "-c", "-O2", "-I#{src}", f, "-o", "#{out}/#{b}.o"],
        env: { "NFCXX_BACKEND" => be }, out: [log, "a"], err: [:child, :out])
  end
end
unless ok
  run(["tail", "-30", log], out: $stderr)
  $stderr.puts "setup-poly-lua: build failed (full log: #{log})"
  exit 1
end
run(["rm", "-f", "#{out}/liblua.a"])
run(["ar", "rcs", "#{out}/liblua.a", *shell_glob("#{out}/*.o")])
run(["rm", "-rf", "#{dest}.new"])
run(["mkdir", "-p", "#{dest}.new/lib", "#{dest}.new/include"])
run(["cp", "#{out}/liblua.a", "#{dest}.new/lib/liblua.a"])
run(["cp", "#{src}/lua.h", "#{src}/luaconf.h", "#{src}/lauxlib.h", "#{src}/lualib.h", "#{dest}.new/include/"])
run(["rm", "-rf", dest])
run(["mv", "#{dest}.new", dest])
$stderr.puts "setup-poly-lua: built #{dest}/lib/liblua.a (backend #{be}, C++ exceptions)"
