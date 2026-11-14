#!/usr/bin/env ruby
# Build the ASTro luastro interpreter that lib/poly (nfcpoly_astro.cpp) embeds, into build/poly-astro/<backend>/:
#   lib/libluastro.a   luastro (sample/luastro of ko1/astro: a Lua 5.4 subset on ASTro's generated AST interpreter) as a library:
#                      lib/poly/nfcpoly_astro_shim.c (luastro's main.c without the command line) and the generated node.c
#   include/           nfcpoly_astro_shim.h; give the host program -I build/poly-astro/<backend>/include, and link
#                      -ldl -lm -lpthread after the library
# The evaluator is generated from node.def by ASTroGen (Ruby), the same way tests/realworld/run_astro.sh does it, with the same two
# patches, applied to a copy (the clone stays at the pin): Ruby 3.4's implicit `it` becomes `_1` (the host may have Ruby 3.3), and the
# `;;` that ASTroGen writes between allocator declarations (not ISO C) becomes a newline. docs/notes/astro.md.
#   NFCXX_BACKEND=pathb|gcc   back end of the C compiler (default pathb); one build tree per back end
#   FORCE=1                 rebuild even if the library is newer than this script and the shim
# Exit status: 0 built (or up to date); 3 cannot be built here (no ruby, ko1/astro cannot be fetched): tests/poly/run.sh reports a
# SKIP; 1 the build failed. Needs EDG's nfcc toolchain (scripts/setup-pathb.sh for the pathb back end).
# Ruby port of setup-poly-astro.sh: the external commands, their order and arguments are the same.
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
work = File.join(root, "build/poly-astro")
be = ENV["NFCXX_BACKEND"]
be = "pathb" if be.nil? || be.empty?
unless %w[gcc pathb].include?(be)
  $stderr.puts "setup-poly-astro: NFCXX_BACKEND must be pathb or gcc, not '#{be}'"
  exit 1
end
pin = "68f15d81b8cc378053c78c2a087b691851bdc2ac"   # ko1/astro main, same pin as tests/realworld/run_astro.sh
src = "#{work}/src"
out = "#{work}/out-#{be}"
dest = "#{work}/#{be}"
skip = lambda { |msg| $stderr.puts "setup-poly-astro: #{msg}"; exit 3 }
fresh = lambda do
  File.file?("#{dest}/lib/libluastro.a") && newer?("#{dest}/lib/libluastro.a", self_path) &&
    newer?("#{dest}/lib/libluastro.a", "lib/poly/nfcpoly_astro_shim.c") &&
    newer?("#{dest}/lib/libluastro.a", "lib/poly/nfcpoly_astro_shim.h")
end
exit 0 if ENV["FORCE"].to_s.empty? && fresh.call
skip.call("no ruby (ASTroGen, the generator of luastro's evaluator, is a Ruby program)") unless which("ruby")
run(["mkdir", "-p", work])
lock = File.open("#{work}/.lock", "w")
lock.flock(File::LOCK_EX) if which("flock")
exit 0 if ENV["FORCE"].to_s.empty? && fresh.call

unless File.directory?("#{src}/.git")
  ok = run(["mkdir", "-p", src]) == 0 &&
       run(["git", "-C", src, "init", "-q"]) == 0 &&
       run(["git", "-C", src, "remote", "add", "origin", "https://github.com/ko1/astro"]) == 0
  exit 1 unless ok
end
out_rev, = capture(["git", "-C", src, "rev-parse", "-q", "--verify", "#{pin}^{commit}"])
if out_rev != pin
  skip.call("fetching ko1/astro #{pin} failed") unless run(["git", "-C", src, "fetch", "-q", "--depth", "1", "origin", pin]) == 0
end
exit 1 unless run(["git", "-C", src, "reset", "-q", "--hard", pin]) == 0

run(["rm", "-rf", out])
run(["mkdir", "-p", "#{out}/sample"])
run(["cp", "-r", "#{src}/lib", "#{src}/runtime", "#{out}/"])
run(["cp", "-r", "#{src}/sample/luastro", "#{out}/sample/"])
d = "#{out}/sample/luastro"
# the two patches, to the copy: `it` becomes _1 (sed -E), and the allocator declarations are joined with a newline
run(["sed", "-i", "-E", 's/\bit\./_1./g; s/#\{it\}/#{_1}/g', "#{out}/lib/astrogen.rb", "#{d}/lua_gen.rb"])
run(["sed", "-i", 's/build_allocator_decl}\.join(";\\\\n")/build_allocator_decl}.join("\\\\n")/', "#{out}/lib/astrogen.rb"])
astrogen = "#{out}/lib/astrogen.rb"
unless File.file?(astrogen)   # grep, which reads it in the shell, reports this and matches nothing
  $stderr.puts "grep: #{astrogen}: No such file or directory"
end
unless File.file?(astrogen) && File.read(astrogen).include?('build_allocator_decl}.join("\\n")')
  $stderr.puts "setup-poly-astro: the ;; patch no longer applies (astrogen.rb changed); move the pin and the patch together"
  exit 1
end
log = "#{work}/build-#{be}.log"
File.write(log, "")
ENV["LC_ALL"] = "C.UTF-8"   # node.def holds non-ASCII text; the generator reads it as UTF-8
generated = run(["ruby", "-I", "../../lib", "-I", ".", "-r", "astrogen", "-r", "lua_gen", "-e",
                 "ASTroGen.start([], node_def_class: LuaNodeDef)"],
                chdir: d, out: [log, "a"], err: [:child, :out]) == 0 && File.file?("#{d}/node_head.h")
unless generated
  run(["tail", "-20", log], out: $stderr)
  $stderr.puts "setup-poly-astro: ASTroGen failed (full log: #{log})"
  exit 1
end
# luastro's main.c is replaced by the shim; its node.c holds the evaluator glue. -I: the generated headers, the ASTro runtime.
cflags = ["-c", "-O2", "-I#{d}", "-I#{out}/runtime", "-I#{root}/lib/poly"]
compiled = run(["#{root}/nfcc", *cflags, "#{root}/lib/poly/nfcpoly_astro_shim.c", "-o", "#{out}/shim.o"],
               env: { "NFCXX_BACKEND" => be}, out: [log, "a"], err: [:child, :out]) == 0 &&
           run(["#{root}/nfcc", *cflags, "#{d}/node.c", "-o", "#{out}/node.o"],
               env: { "NFCXX_BACKEND" => be }, out: [log, "a"], err: [:child, :out]) == 0
unless compiled
  run(["tail", "-30", log], out: $stderr)
  $stderr.puts "setup-poly-astro: build failed (full log: #{log})"
  exit 1
end
# luastro defines lua_arith, lua_concat and lua_len, which the real Lua (liblua.a, the "lua" backend) defines too, and a program that
# links both would not link. Every global lua_* / luaL_* symbol of the two objects is renamed with a prefix (the references too).
nm_out, = capture(["nm", "--defined-only", "-g", "#{out}/shim.o", "#{out}/node.o"], err: $stderr)
renames = nm_out.lines.map { |l| l.chomp.split }.select { |f| f.size == 3 && f[2].match?(/\Alua(L)?_/) }
                .map { |f| "#{f[2]} ls_#{f[2]}" }.uniq.sort
File.write("#{out}/rename.txt", renames.map { |r| r + "\n" }.join)
%w[shim node].each do |o|
  unless run(["objcopy", "--redefine-syms=#{out}/rename.txt", "#{out}/#{o}.o"]) == 0
    $stderr.puts "setup-poly-astro: objcopy failed"
    exit 1
  end
end
run(["rm", "-f", "#{out}/libluastro.a"])
run(["ar", "rcs", "#{out}/libluastro.a", "#{out}/shim.o", "#{out}/node.o"])
run(["rm", "-rf", "#{dest}.new"])
run(["mkdir", "-p", "#{dest}.new/lib", "#{dest}.new/include"])
run(["cp", "#{out}/libluastro.a", "#{dest}.new/lib/libluastro.a"])
run(["cp", "#{root}/lib/poly/nfcpoly_astro_shim.h", "#{dest}.new/include/"])
run(["rm", "-rf", dest])
run(["mv", "#{dest}.new", dest])
$stderr.puts "setup-poly-astro: built #{dest}/lib/libluastro.a (backend #{be})"
