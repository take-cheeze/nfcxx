#!/usr/bin/env ruby
# EDG's C++ runtime (libC.a) for the --cosmo links (docs/notes/cosmo.md): the members of the host build's libC.a, compiled
# from 3rd/edg/lib_src with cosmo's C compiler and headers. Prints the directory of libC.a, building it first when it is
# missing or older than the host archive. Two members of the host archive are left out: decode.o defines __cxa_demangle
# for EDG's prelinker, and eh_util.o defines std::terminate, std::unexpected and the handler setters, which cosmo's
# libc++abi (libcosmo.a) already has.
# Needs build/edg (scripts/setup-edg.sh) for the member list and the eccp driver, and cosmocc (NFCXX_COSMOCC, or
# build/cosmocc/bin/cosmocc from scripts/setup-cosmo.sh). COSMO_LIBC_OUT: another output directory.
# This is scripts/cosmo-libc.sh (bash) ported to Ruby: the same commands, in the same order.
require "fileutils"

ROOT = File.expand_path("..", File.expand_path(File.dirname($0)))

def env(name)
  v = ENV[name]
  v.nil? || v.empty? ? nil : v
end

# A command run as the bash runs it under set -e: a failure ends the script with its status.
def run!(*cmd, env: {})
  return if system(env, *cmd)

  exit($?.exitstatus || 127)
end

edg = env("EDG_BUILD") || File.join(ROOT, "build", "edg")
cosmocc = env("NFCXX_COSMOCC") || File.join(ROOT, "build", "cosmocc", "bin", "cosmocc")
cosmo_root = File.expand_path("..", File.dirname(cosmocc))
out = env("COSMO_LIBC_OUT") || File.join(ROOT, "build", "cosmo-libc")
host = File.join(edg, "lib", "libC.a")
unless File.file?(host)
  warn "cosmo-libc: #{host} is missing; run scripts/setup-edg.sh"
  exit 2
end
unless File.executable?(cosmocc)
  warn "cosmo-libc: #{cosmocc} is not installed; run scripts/setup-cosmo.sh"
  exit 2
end

lib = File.join(out, "libC.a")
self_path = File.expand_path(__FILE__)
if !File.file?(lib) || File.mtime(host) > File.mtime(lib) || File.mtime(self_path) > File.mtime(lib)
  FileUtils.mkdir_p(File.join(out, "obj"))
  # the C compile of eccp's output: cosmo's gcc with cosmo's include path and predefines (cosmocc's own wrapper flags).
  # cosmocc itself refuses the -S that gcc-cc runs for its weak symbols.
  cosmo_cc = File.join(out, "cosmo-cc")
  File.write(cosmo_cc, <<~CC)
    #!/bin/sh
    exec "#{cosmo_root}/bin/x86_64-linux-cosmo-gcc" -U__k8 -U__k8__ -U__amd64 -U__amd64__ -U__x86_64 -U__x86_64__ -U__linux -U__linux__ -mno-red-zone -mlong-double-64 -D__COSMOPOLITAN__ -D__COSMOCC__ -D__FATCOSMOCC__ -isystem "#{cosmo_root}/include" -fno-pie -nostdinc -isystem "#{cosmo_root}/include" "$@"
  CC
  File.chmod(0o755, cosmo_cc)
  # the host archive's members, minus decode.o
  members = IO.popen(["ar", "t", host], &:read).lines.map(&:chomp).reject { |o| o == "decode.o" }
  Dir.glob(File.join(out, "obj", "*.o")).each { |o| File.delete(o) }
  members.each do |o|
    src = File.join(ROOT, "3rd", "edg", "lib_src", "#{o.delete_suffix(".o")}.c")
    unless File.file?(src)
      warn "cosmo-libc: no source for #{o} in 3rd/edg/lib_src"
      exit 2
    end
    run!(File.join(edg, "bin", "eccp"), "--building_runtime", "--c++23", "-g",
         "-DCHECKING=1", "-DDEBUG=1", "-DUSE_STDINT_HEADER", "-DSYSTEM_RUNTIME_HAS_IA64_THREAD_ATEXIT=0", "-D__COSMOPOLITAN__", "-D__COSMOCC__",
         "-D__FATCOSMOCC__", "--preinclude", "#{cosmo_root}/include/libc/integral/normalize.inc", "--no_standard_includes",
         "--sys_include=#{ROOT}/3rd/edg/include_c++", "--sys_include=#{ROOT}/3rd/edg/include_c99", "--sys_include=#{cosmo_root}/include",
         "--g++", "--nfcxx_eh_thread_local", "-DNFCXX_EH_TLS=1", "--c_to_obj_option", "-fPIC", "-o", File.join(out, "obj", o), "-c", src,
         env: { "NFCXX_GCC" => cosmo_cc, "NFCXX_CC" => File.join(ROOT, "scripts", "gcc-cc.rb"), "NFCXX_CCACHE" => "0" })
  end
  run!("objcopy", "-W", "_ZSt9terminatev", "-W", "_ZSt13get_terminatev", "-W", "_ZSt13set_terminatePFvvE", "-W", "_ZSt14set_unexpectedPFvvE",
       "-W", "_ZSt10unexpectedv", File.join(out, "obj", "eh_util.o"))
  File.delete(lib) if File.file?(lib)
  objs = Dir.glob(File.join(out, "obj", "*.o")).sort
  run!("ar", "rcs", lib, *objs)
end
puts out
