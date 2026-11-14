#!/usr/bin/env ruby
# Build the interpreters that lib/poly embeds with the HOST compilers (gcc and g++), for machines where nfcxx itself is not built
# (tests/uop/run_poly.sh with UOP_HOST=1): the same engines and settings as scripts/setup-poly.sh (mruby with C++ exceptions),
# scripts/setup-poly-lua.sh (Lua with ldo.c as C++) and scripts/setup-poly-js.sh (QuickJS-NG, plain C), without nfcc or nfcxx and
# without any patch (the sources are built as they are, as setup-poly*.sh now do). Go (yaegi) is scripts/setup-poly-go.sh, which already uses the host's Go and gcc, and
# Python is the system CPython; neither is built here.
#   scripts/setup-poly-host.sh ruby|lua|js     builds build/poly-host/<language>/{lib,include}
#   FORCE=1                                    rebuild even if the library exists
# Exit status: 0 built (or up to date); 3 cannot be built here (a tool or a download is missing); 1 the build failed.
# Sources, at the pins of the other setup scripts: mruby 4.0.0 and Lua 5.4.9 as the source tarballs of the Ubuntu archive (checked
# against the sha256 below; the upstream tag tarball of GitHub is tried first) and QuickJS-NG v0.17.0 file by file from
# raw.githubusercontent.com at the commit of the tag. Needs curl, tar, gcc, g++, ar; ruby with rake for mruby.
# Ruby port of setup-poly-host.sh: the external commands, their order and arguments are the same.
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


Dir.chdir(File.join(File.dirname(File.expand_path($PROGRAM_NAME)), ".."))
root = Dir.pwd
work = File.join(root, "build/poly-host")
lang = ARGV[0].to_s
skip = lambda { |msg| $stderr.puts "setup-poly-host: #{msg}"; exit 3 }
unless %w[ruby lua js].include?(lang)
  $stderr.puts "usage: #{$PROGRAM_NAME} ruby|lua|js"
  exit 1
end
%w[curl tar gcc g++ ar].each { |t| skip.call("#{t} not found") unless which(t) }
dest = "#{work}/#{lang}"
exit 0 if ENV["FORCE"].to_s.empty? && File.file?("#{dest}/.built")
run(["mkdir", "-p", work])
lock = File.open("#{work}/.lock", "w")
lock.flock(File::LOCK_EX) if which("flock")
exit 0 if ENV["FORCE"].to_s.empty? && File.file?("#{dest}/.built")
log = "#{work}/build-#{lang}.log"
File.write(log, "")
fail_build = lambda do
  run(["tail", "-20", log], out: $stderr)
  $stderr.puts "setup-poly-host: #{lang} build failed (log: #{log})"
  exit 1
end

# fetch OUT SHA256 URL...: the first URL that downloads; a download from the Ubuntu archive must match SHA256
def fetch(out, sha, log, *urls)
  urls.each do |u|
    next unless run(["curl", "-sSfL", "-m", "120", "-o", out, u], err: [log, "a"]) == 0
    if u.include?("archive.ubuntu.com")
      got, = capture(["sha256sum", out])
      unless got.split(" ", 2)[0].to_s == sha
        File.write(log, "checksum mismatch: #{u}\n", mode: "a")
        next
      end
    end
    return true
  end
  false
end

# the rake of the ruby build: rake, or the rake gem under the Gem.bindir of ruby, or ruby -rrake
def rake_command
  if which("rake")
    ["rake"]
  else
    bindir, = capture(["ruby", "-e", "print Gem.bindir"])
    if File.executable?("#{bindir}/rake")
      bindir, = capture(["ruby", "-e", "print Gem.bindir"])   # the shell runs the command substitution again here
      ["#{bindir}/rake"]
    else
      ["ruby", "-rrake", "-e", "Rake.application.run(ARGV)", "--"]
    end
  end
end

case lang
when "ruby"
  skip.call("ruby (CRuby) is needed to bootstrap mruby's build") unless which("ruby")
  rake = rake_command
  skip.call("the rake gem is needed") unless run(rake + ["--version"], out: File::NULL, err: File::NULL) == 0
  pin = "831da26b9021de0369d17b71b5667e2941a1a32d"   # mruby/mruby tag 4.0.0
  src = "#{work}/mruby-src"
  run(["rm", "-rf", src, "#{work}/mruby-out"])
  run(["mkdir", "-p", src])
  skip.call("cannot download mruby 4.0.0") unless fetch("#{work}/mruby.tgz", "e2ea271dbed14e9f2b33df773ae447b747dbc242ce2675022c0a57efea85a7b4", log,
    "https://github.com/mruby/mruby/archive/#{pin}.tar.gz",
    "http://archive.ubuntu.com/ubuntu/pool/universe/m/mruby/mruby_4.0.0.orig.tar.gz")
  fail_build.call unless run(["tar", "xzf", "#{work}/mruby.tgz", "-C", src, "--strip-components=1"]) == 0
  # mruby's own rake build, with scripts/mruby-rt-config.rb (C++ exceptions) and the host compilers
  run(["cp", "scripts/mruby-rt-config.rb", "#{work}/build_config-host.rb"])
  built = run([*rake, "-j#{jobs}", "all"], chdir: src,
              env: { "MRUBY_CC" => "gcc", "MRUBY_CXX" => "g++", "MRUBY_CONFIG" => "#{work}/build_config-host.rb",
                     "MRUBY_BUILD_DIR" => "#{work}/mruby-out" },
              out: [log, "a"], err: [:child, :out])
  fail_build.call unless built == 0
  lib = "#{work}/mruby-out/host/lib/libmruby.a"
  fail_build.call unless File.file?(lib)
  run(["rm", "-rf", dest])
  run(["mkdir", "-p", "#{dest}/lib", "#{dest}/include"])
  run(["cp", lib, "#{dest}/lib/"])
  run(["cp", "-r", "#{src}/include/.", "#{dest}/include/"])
  run(["cp", "-r", "#{work}/mruby-out/host/include/.", "#{dest}/include/"])
when "lua"
  src = "#{work}/lua-src"
  run(["rm", "-rf", src])
  run(["mkdir", "-p", src])
  skip.call("cannot download Lua 5.4.9") unless fetch("#{work}/lua.tgz", "2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6", log,
    "https://github.com/lua/lua/archive/312b9efaa1061c2c4cad08554dbc1351c3270eef.tar.gz",
    "http://archive.ubuntu.com/ubuntu/pool/main/l/lua5.4/lua5.4_5.4.9.orig.tar.gz")
  fail_build.call unless run(["tar", "xzf", "#{work}/lua.tgz", "-C", src, "--strip-components=1"]) == 0
  src = "#{src}/src" if File.directory?("#{src}/src")
  out = "#{work}/lua-out"
  run(["rm", "-rf", out])
  run(["mkdir", "-p", out])
  # ldo.c is the one file that raises errors (longjmp, or throw when compiled as C++): it is built as C++, the others as C
  File.write("#{out}/ldo-cxx.cpp", "extern \"C\" {\n#include \"#{src}/ldo.c\"\n}\n")
  skipped = %w[lua luac ltests onelua linit liolib loslib loadlib ldblib]
  shell_glob("#{src}/l*.c").each do |f|
    b = File.basename(f, ".c")
    next if skipped.include?(b)
    if b == "ldo"
      fail_build.call unless run(["g++", "-c", "-O2", "-I#{src}", "#{out}/ldo-cxx.cpp", "-o", "#{out}/ldo.o"], out: [log, "a"], err: [:child, :out]) == 0
    else
      fail_build.call unless run(["gcc", "-c", "-O2", "-I#{src}", f, "-o", "#{out}/#{b}.o"], out: [log, "a"], err: [:child, :out]) == 0
    end
  end
  run(["rm", "-rf", dest])
  run(["mkdir", "-p", "#{dest}/lib", "#{dest}/include"])
  ok = run(["ar", "rcs", "#{dest}/lib/liblua.a", *shell_glob("#{out}/*.o")]) == 0 &&
       run(["cp", "#{src}/lua.h", "#{src}/luaconf.h", "#{src}/lauxlib.h", "#{src}/lualib.h", "#{dest}/include/"]) == 0
  fail_build.call unless ok
when "js"
  pin = "6d46d07d04041b40f4f49eaa7fdebe44c314c699"   # quickjs-ng/quickjs tag v0.17.0
  src = "#{work}/qjs-src"
  out = "#{work}/qjs-out"
  run(["rm", "-rf", src, out])
  run(["mkdir", "-p", src, out])
  %w[quickjs.c quickjs.h dtoa.c dtoa.h libregexp.c libregexp.h libregexp-opcode.h libunicode.c libunicode.h libunicode-table.h
     cutils.h list.h quickjs-atom.h quickjs-opcode.h quickjs-c-atomics.h builtin-array-fromasync.h builtin-iterator-zip-keyed.h
     builtin-iterator-zip.h].each do |f|
    skip.call("cannot download QuickJS-NG (#{f})") unless fetch("#{src}/#{f}", "", log, "https://raw.githubusercontent.com/quickjs-ng/quickjs/#{pin}/#{f}")
  end
  %w[quickjs dtoa libregexp libunicode].each do |n|
    fail_build.call unless run(["gcc", "-c", "-O2", "-I#{src}", "#{src}/#{n}.c", "-o", "#{out}/#{n}.o"], out: [log, "a"], err: [:child, :out]) == 0
  end
  run(["rm", "-rf", dest])
  run(["mkdir", "-p", "#{dest}/lib", "#{dest}/include"])
  ok = run(["ar", "rcs", "#{dest}/lib/libquickjs.a", *shell_glob("#{out}/*.o")]) == 0 &&
       run(["cp", "#{src}/quickjs.h", "#{dest}/include/"]) == 0
  fail_build.call unless ok
end
run(["touch", "#{dest}/.built"])
$stderr.puts "setup-poly-host: built #{dest}"
