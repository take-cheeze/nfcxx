#!/usr/bin/env ruby
# libclang-edg: list the declarations of one C++ file as tab-separated records (format: be/nfcxx_decl.c).
# Runs the libclang-edg front end (build/libclang-edg, from scripts/setup-libclang-edg.sh) with the same host
# library and GNU options as scripts/pathb-dump. Usage: scripts/libclang-cursors.rb [--c | -std=c++NN] [-Idir] [-Dmacro] file.cpp   (--c: C mode, for C headers)
# The libclang shim (lib/libclang-edg) runs this script; LIBCLANG_EDG_CPFE and LIBCLANG_EDG_BASE override the paths.
# The bash original is tests/launch/oracle/libclang-cursors.sh.
require "fileutils"
require_relative "launch"

NAME = "libclang-cursors"
ROOT = Launch.root_of(__FILE__)

def main
  cpfe = Launch.env_or("LIBCLANG_EDG_CPFE", File.join(ROOT, "build/libclang-edg/cmake/bin/cpfe"))
  base = Launch.env_or("LIBCLANG_EDG_BASE", File.join(ROOT, "build/libclang-edg/edg-base"))
  unless File.executable?(cpfe)
    warn "#{NAME}: front end not built; run scripts/setup-libclang-edg.sh"
    exit 2
  end

  std = "--c++23"
  files = []
  user_opts = []
  c_mode = false
  ARGV.each do |arg|
    case arg
    when "--c" then c_mode = true
    when /\A-std=c\+\+/ then std = "--c++#{arg.delete_prefix("-std=c++")}"
    when /\A-I./ then user_opts << "-I#{HostSys.abs_path(arg[2..])}"
    when /\A-[DU]./ then user_opts << arg
    when /\A-W/ then nil
    else files << arg
    end
  end
  if files.empty?
    warn "#{NAME}: no input file"
    exit 2
  end

  sys_inc = HostSys.sys_includes.reject(&:empty?).map { |d| "--sys_include=#{d}" }
  gnu = HostSys.gnu_version
  gnu_opts = gnu ? ["--gnu_version=#{gnu}"] : []

  status = 0
  files.each do |file|
    f = Launch.realpath!(file)
    b = File.basename(f)
    stem = b.end_with?(".cpp") && b != ".cpp" ? b.delete_suffix(".cpp") : b
    ti = File.join(base, "#{stem}.ti")
    had_ti = File.exist?(ti)
    lang = c_mode ? ["--c"] : [std, "--g++", "-tused"]

    code = Launch.run(
      [cpfe, "-D_POSIX_SOURCE", "-D__CHAR_BIT__=8", *lang, "--wdir", "/", *gnu_opts, *user_opts, *sys_inc,
       "--sys_include=#{base}/include", f],
      dir: base
    )
    status = code unless code.zero?
    FileUtils.rm_f(ti) unless had_ti
  end
  exit status
end

main
