#!/usr/bin/env ruby
# Lua 5.4 for macOS arm64, built on this host. Replaces run_lua_macos.sh (the bash harness it wrapped, cross_macos.sh,
# was removed with the qbe back end). The source is cloned at the pin into build/realworld/lua, as run_lua.sh does.
# Every interpreter file is compiled by Path B (scripts/pathb-cc.rb, EDG -> typed IR -> QBE; no qbe-cc), and linked
# with Path B's runtime archive (scripts/pathb-ldrt.rb) against the clean-room link stub
# (tests/macos-sysroot/lib/libSystem.tbd). The executable is written to build/lua-macos/lua. Nothing is run: the stub has
# no code, so the binary can be checked for its Mach-O shape and its imports only.
#
# Needs the Path B harness (scripts/setup-pathb.sh) and QBE (scripts/setup-qbe.sh).
#
#   ruby tests/realworld/run_lua_macos.rb
#
# Expected on a Mac, once the stub is replaced by the real libSystem: print(1+1) -> 2; lua_test.lua -> lua-ok line.
require "digest"
require "fileutils"
require "rbconfig"
$stdout.sync = true
$stderr.sync = true

root = File.expand_path("../..", __dir__)
stub_dir = File.join(root, "tests/macos-sysroot/lib")
pathb_cc = File.join(root, "scripts/pathb-cc.rb")
pathb_ldrt = File.join(root, "scripts/pathb-ldrt.rb")
work = File.join(root, "build/realworld")
src = File.join(work, "lua")
obj_dir = File.join(root, "build/lua-macos/obj")
out = File.join(root, "build/lua-macos/lua")
pin = "312b9efaa1061c2c4cad08554dbc1351c3270eef" # lua/lua tag v5.4.9, as run_lua.sh
DEPLOYMENT = "11.0" # the link's -platform_version below, so the objects and the executable agree

def die(msg)
  warn "run_lua_macos: #{msg}"
  exit 1
end

def git_ok(*argv)
  system("git", *argv)
end

# fetch: a shallow clone of the pinned commit, the same pattern as run_lua.sh
def fetch(url, pin, src)
  FileUtils.mkdir_p(src)
  unless File.directory?(File.join(src, ".git"))
    git_ok("init", "-q", src) || die("git init #{src} failed")
    git_ok("-C", src, "remote", "add", "origin", url) || die("git remote add failed")
  end
  head = IO.popen(["git", "-C", src, "rev-parse", "-q", "--verify", "#{pin}^{commit}"], err: File::NULL, &:read).strip
  if head != pin
    git_ok("-C", src, "fetch", "-q", "--depth", "1", "origin", pin) || die("fetch #{url} failed")
  end
  git_ok("-C", src, "checkout", "-q", pin) || die("checkout #{pin} failed")
end

# pathb: one C file to an object through Path B (scripts/pathb-cc.rb, the same call as nfcxx-pathb.rb's C compiles).
# The system headers are the clean-room set plus clang's resource headers (stddef.h, stdarg.h, ...), not the SDK's: the
# SDK's headers name libc functions with $DARWIN_EXTSN and _chk labels, which the stub does not export.
def pathb!(ruby, pathb_cc, sysincl, src, dst)
  env = { "NFCXX_SYS_INCLUDES" => sysincl, "MACOSX_DEPLOYMENT_TARGET" => DEPLOYMENT }
  system(env, ruby, pathb_cc, "-std=c11", src, "-o", dst) || die("pathb-cc failed: #{src}")
end

resource = IO.popen(["clang", "-print-resource-dir"], err: File::NULL, &:read).strip
die("clang -print-resource-dir gave nothing") if resource.empty?
sysincl = [File.join(root, "tests/macos-sysroot/include"), File.join(resource, "include")].join(":")

fetch("https://github.com/lua/lua", pin, src)

# Every interpreter file: luac.c (the compiler), ltests.c (test hooks) and onelua.c (amalgamation) are not part of it.
FileUtils.mkdir_p(obj_dir)
srcs = Dir.glob(File.join(src, "l*.c")).sort.reject { |f| %w[luac.c ltests.c onelua.c].include?(File.basename(f)) }
objs = srcs.map do |f|
  dst = File.join(obj_dir, "#{File.basename(f, '.c')}.o")
  pathb!(RbConfig.ruby, pathb_cc, sysincl, f, dst)
  dst
end

# Path B's runtime archive (long double and __int128 helpers): the archive only pulls in the helpers a program calls.
rt = IO.popen([RbConfig.ruby, pathb_ldrt], &:read).strip
die("no Path B runtime archive (scripts/pathb-ldrt.rb)") if rt.empty? || !File.file?(rt)

FileUtils.mkdir_p(File.dirname(out))
# Apple's ld reads the TBD stub through -L and -lSystem; undefined names fail the link, which is the stub check.
ld_args = ["-arch", "arm64", "-platform_version", "macos", "11.0", "11.0", "-o", out, *objs, rt,
           "-L#{stub_dir}", "-lSystem"]
system("ld", *ld_args) || die("link failed")

hdr = IO.popen(["otool", "-hv", out], err: File::NULL, &:read)
die("#{out} is not a Mach-O arm64 executable") unless hdr.include?("EXECUTE") && hdr.include?("ARM64")

sha = Digest::SHA256.file(out).hexdigest[0, 16]
puts "built: #{out} (sha256 #{sha})"
puts "expected on the Mac: print(1+1) -> 2; lua_test.lua -> lua-ok<TAB>27<TAB>6765<TAB>Lua 5.4; exit 0"
