#!/usr/bin/env ruby
# Linker for the macOS arm64 cross C++ link (EDG_OBJ_TO_EXEC_LINKER, scripts/macos-cxx-link.rb): eccp's gcc-style link line
# becomes an ld64.lld call against the clean-room stubs (tests/macos-sysroot/lib). The objects and -o are kept; compile-only
# options, the host runtime (-lC, -lstdc++, -lgcc*, -lm, -lc, -lpthread, -ldl) and -rpath are dropped. Mach-O only: nothing
# here runs the output. A link that needs a symbol the stubs lack fails in the stub check, as before.
$stdout.sync = true
$stderr.sync = true

root = File.expand_path("..", File.dirname($PROGRAM_NAME))
stub = File.join(root, "tests/macos-sysroot/lib")

# bash case patterns, in the order of the case statement
def pat?(arg, pattern)
  File.fnmatch(pattern, arg, File::FNM_DOTMATCH)
end

def env_or(name, default)
  v = ENV[name].to_s
  v.empty? ? default : v
end

def file_type(path)
  IO.popen(["file", "-b", path], err: File::NULL, &:read).to_s
rescue SystemCallError
  ""
end

out = "a.out"
objs = []
libs = []
argv = ARGV.dup
until argv.empty?
  a = argv.shift
  if a == "-o"
    out = argv.shift or (warn "cross-macos-link: -o needs an argument"; exit 1)
  elsif pat?(a, "-o*")
    out = a[2..]
  elsif a == "-L"
    argv.shift or (warn "cross-macos-link: -L needs an argument"; exit 1)
  elsif pat?(a, "-L*")
    nil
  elsif pat?(a, "-l*")
    libs << a unless %w[C stdc++ gcc gcc_s m c pthread dl rt].include?(a[2..])
  elsif pat?(a, "-Wl,*")
    nil
  elsif %w[-O* -f* -g* -W* -m*].any? { |p| pat?(a, p) } || %w[-pipe -c -shared -rdynamic -fPIC -pic].include?(a)
    nil
  elsif pat?(a, "*.o") || pat?(a, "*.a")
    # the driver adds the host-built sret thunks (ELF); they are not Mach-O and not needed by the programs here
    if file_type(a).include?("ELF")
      warn "cross-macos-link: dropped host object #{a} (not Mach-O)"
    else
      objs << a
    end
  else
    nil
  end
end

# The open-source compiler and libc++abi runtime (tests/macos-sysroot/runtime, built by build.sh): the sized __atomic_*
# calls, the aligned operator new and delete, __cxa_pure_virtual and the __cxa_vec_* helpers. Added only when built.
rt = env_or("NFCXX_MACOS_RT", File.join(root, "build/macos-rt/libnfcxx-darwin-rt.a"))
# EDG's libC.a without the exception, typeinfo and terminate members that libc++ and libc++abi provide (build.sh writes
# libC-darwin.a from it); the raw libC.a is used only when that archive has not been built.
libc = ENV["NFCXX_MACOS_LIBC"].to_s
libcb = File.join(root, "build/macos-rt/libC-darwin.a")
libc = libcb if File.file?(libcb)
libcargs = !libc.empty? && File.file?(libc) ? [libc] : []
# The libc++ built from the open-source sources (tests/macos-sysroot/runtime/build.sh). Linked before -lc++, so its definitions
# are used when it is built; the system libc++ supplies the rest at run time.
cxxb = env_or("NFCXX_MACOS_LIBCXX_BUILT", File.join(root, "build/macos-rt/libc++-darwin.a"))
cxxbargs = File.file?(cxxb) ? [cxxb] : []
rtargs = File.file?(rt) ? [rt] : []

exec(["ld64.lld", "ld64.lld"], "--error-limit=0", "-arch", "arm64", "-platform_version", "macos", "11.0", "11.0",
     "-o", out, *objs, *libcargs, *rtargs, *cxxbargs, "-L", stub, "-lSystem", "-L", stub, "-lc++", *libs)
