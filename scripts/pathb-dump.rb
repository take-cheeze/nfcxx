#!/usr/bin/env ruby
# Path B: print the lowered IL of a C++ file as s-expressions (stage 1, see be/nfcxx_be.h for the format), or
# with --ir the mid-level IR (stage 2, see docs/notes/pathb-stage2.md). Runs the harness front end
# (build/pathb, from scripts/setup-pathb.sh) from the EDG base dir, with the same flags as the nfcxx --emit-c
# branch. Front-end errors go to stderr and give a non-zero exit status.
# Usage: scripts/pathb-dump.rb [--ir] [-std=c++NN | -std=cNN] [-Idir] [-Dmacro] [-Umacro] [--freestanding] file.cpp...
# The options are those of scripts/pathb-dump (bash), which this ports to Ruby: the same options, the same front-end
# command line, the same environment settings. Hosted by default, with the host's include directories (scripts/host-sys.rb).
require "fileutils"
require_relative "host-sys"

ROOT = File.expand_path("..", File.expand_path(File.dirname($0)))

def die(message, status = 2)
  warn message
  exit status
end

cpfe = ENV["PATHB_CPFE"].to_s.empty? ? File.join(ROOT, "build", "pathb", "cmake", "bin", "cpfe") : ENV["PATHB_CPFE"]
base = ENV["PATHB_BASE"].to_s.empty? ? File.join(ROOT, "build", "pathb", "edg-base") : ENV["PATHB_BASE"]
die("pathb-dump: harness not built; run scripts/setup-pathb.sh") unless File.executable?(cpfe)

std = ""
user_gnu = []
fe_dialect = "g++"
files = []
user_opts = []
mode = "il"
hosted = ENV["PATHB_HOSTED"].to_s.empty? ? "1" : ENV["PATHB_HOSTED"]
target = ""
eh_runtime = false
cuda_device = !ENV["NFCXX_PATHB_CUDA"].to_s.empty?
nostdinc = false
isys = []
idafter = []

args = ARGV.dup
i = 0
need = lambda do |what|
  i += 1
  die("pathb-dump: #{what}") unless i < args.size
  args[i]
end
while i < args.size
  arg = args[i]
  case arg
  when "--ir" then mode = "ir"
  when "--stats" then ENV["NFCXX_PATHB_STATS"] = "1"
  when "--ir-loc" then ENV["NFCXX_IR_LOC"] = "1"
  when "--ir-scopes" then ENV["NFCXX_IR_SCOPES"] = "1"
  when "--ir-noinline" then ENV["NFCXX_IR_NOINLINE"] = "1"
  when "--borrow" then ENV["NFCXX_PATHB_BORROW"] = "1"
  when /\A--sanitize=/ then ENV["NFCXX_IR_SANITIZE"] = arg.delete_prefix("--sanitize=")
  when /\A--overflow=/ then ENV["NFCXX_IR_OVERFLOW"] = arg.delete_prefix("--overflow=")
  when "--cuda-device" then cuda_device = true
  when "--freestanding" then hosted = "0"
  when "--eh-runtime" then eh_runtime = true
  when "--cuda" then user_opts << "--cuda"
  when /\A--target=/ then target = arg.delete_prefix("--target=")
  when "--target"
    i += 1
    die("pathb-dump: --target needs a name") unless i < args.size
    target = args[i]
  when /\A-std=c\+\+/ then std = "--c++#{arg.delete_prefix("-std=c++")}"
  when "-std=c89", "-std=c99", "-std=c11", "-std=c17", "-std=c18", "-std=c23" then std = "--#{arg.delete_prefix("-std=")}"
  when /\A-std=/ then die("pathb-dump: unknown standard #{arg.delete_prefix("-std=")}")
  when /\A-I./ then user_opts << "-I#{HostSys.abs_path(arg.delete_prefix("-I"))}"
  when /\A-[DU]./ then user_opts << arg
  when "--modules" then user_opts << "--modules"
  when "--modules_directory", "--create_module_interface"
    v = need.("#{arg} needs a path")
    user_opts << arg << HostSys.abs_path(v)
  when "-funsigned-char", "-fno-signed-char" then user_opts.push("--unsigned_chars", "-U__CHAR_UNSIGNED__", "-D__CHAR_UNSIGNED__=1")
  when "-fsigned-char", "-fno-unsigned-char" then user_opts.push("--signed_chars", "-U__CHAR_UNSIGNED__")
  when "-nostdinc" then nostdinc = true
  when "-ftrivial-auto-var-init=zero" then ENV["NFCXX_IR_AUTO_INIT"] = "zero"
  when "-ftrivial-auto-var-init=uninitialized" then ENV.delete("NFCXX_IR_AUTO_INIT")
  when "-isystem", "-idirafter"
    v = need.("#{arg} needs a directory")
    (arg == "-isystem" ? isys : idafter) << "--sys_include=#{HostSys.abs_path(v)}"
  when /\A-isystem./ then isys << "--sys_include=#{HostSys.abs_path(arg.delete_prefix("-isystem"))}"
  when /\A-idirafter./ then idafter << "--sys_include=#{HostSys.abs_path(arg.delete_prefix("-idirafter"))}"
  when "-fshort-wchar"
    user_opts.push("--diag_suppress=predef_macro_redefined", "-D__WCHAR_TYPE__=short unsigned int", "-D__WCHAR_MAX__=0xffff",
                   "-D__WCHAR_MIN__=0", "-D__WCHAR_WIDTH__=16", "-D__SIZEOF_WCHAR_T__=2")
  when "-ffreestanding" then user_opts.push("--diag_suppress=predef_macro_redefined", "-D__STDC_HOSTED__=0")
  when /\A--diag_/ then user_opts << arg
  when "-include"
    v = need.("-include needs a file")
    user_opts.push("--preinclude", HostSys.abs_path(v))
  when /\A--gnu[-_]version=/ then user_gnu = ["--gnu_version=#{arg.sub(/\A--gnu[-_]version=/, "")}"]
  when "-Wno-narrowing" then user_opts.push("--diag_warning=narrowing_conversion")
  when "--dialect=g++" then fe_dialect = "g++"
  when "--dialect=clang" then fe_dialect = "clang"
  when /\A--dialect=/ then die("pathb-dump: unknown dialect #{arg.delete_prefix("--dialect=")}")
  when /\A-W/ then nil
  else files << arg
  end
  i += 1
end
die("pathb-dump: no input files") if files.empty?

# The language: C for a C standard, or for .c files without -std; else C++ (C++23 by default).
std = (files[0].end_with?(".c") ? "--c17" : "--c++23") if std.empty?
if std.start_with?("--c++")
  lang = "c++"
  dialect = "--g++"
else
  lang = "c"
  dialect = "--gcc"
end

# --dialect=clang (C++ only): EDG's clang mode; the front end gets --clang_version instead of the GNU version
clang_opts = []
if fe_dialect == "clang" && lang == "c++"
  dialect = "--clang"
  cv = HostSys.clang_version
  clang_opts = ["--clang_version=#{cv}"] if cv
end

target_opts = []
unless target.empty?
  die("pathb-dump: --target needs --freestanding (the host's library headers are the host target's)") unless hosted == "0"
  die("pathb-dump: no predefined macros for target '#{target}' in #{base}") unless File.directory?("#{base}/lib_#{target}")
  target_opts = ["--target", target, "--signed_chars"]
  ENV["NFCXX_IR_VALIST_PTR"] = "1" if target == "linux_i686"
end

sys_inc = isys.dup
gnu_opts = []
cuda_device_opts = cuda_device ? ["--cuda", "--no_exceptions"] : []
# Hosted, or --eh-runtime: the program links EDG's runtime; with per-thread EH state (the eh-tls marker), the EH variables are thread-local
edg_build = ENV["EDG_BUILD"].to_s.empty? ? File.join(ROOT, "build", "edg") : ENV["EDG_BUILD"]
eh_tls = []
eh_tls = ["--nfcxx_eh_thread_local"] if (hosted != "0" || eh_runtime) && File.file?(File.join(edg_build, "eh-tls"))
if hosted != "0"
  sys_inc.concat(HostSys.sys_includes(lang).map { |d| "--sys_include=#{d}" }) unless nostdinc
  gnu = HostSys.gnu_version
  gnu_opts = ["--gnu_version=#{gnu}"] if gnu
end
# clang mode: the clang version replaces the host's GNU version (and --gnu-version)
if !clang_opts.empty?
  gnu_opts = clang_opts
elsif !user_gnu.empty?
  user_opts.concat(user_gnu)
end
sys_inc.concat(idafter)

# The feature-test macros of the host's C library: _DARWIN_C_SOURCE on Darwin, _POSIX_SOURCE elsewhere
uname_s = IO.popen(["uname", "-s"], &:read).chomp
uname_m = IO.popen(["uname", "-m"], &:read).chomp
posix_def = uname_s == "Darwin" ? ["-D_DARWIN_C_SOURCE", "-U__BLOCKS__"] : ["-D_POSIX_SOURCE"]
# Hosted on Darwin: the SDK's libc++ needs the Darwin feature-test macros, clang's feature macros and an empty features.h
darwin_opts = []
if hosted != "0" && uname_s == "Darwin"
  posix_def = ["-D_DARWIN_C_SOURCE", "-U__BLOCKS__"]
  darwin_opts = ["--preinclude", "#{ROOT}/lib/pathb/clang_macros.h", "-I", "#{ROOT}/lib/pathb/darwin-include"]
  darwin_opts << "-D_LIBCPP_ABI_ALTERNATE_STRING_LAYOUT" if uname_m == "arm64"
end
# Hosted on Linux aarch64: an empty math-vector header stands in for GCC's AdvSIMD/SVE one
if hosted != "0" && uname_s == "Linux" && (uname_m == "aarch64" || uname_m == "arm64")
  darwin_opts.push("-I", "#{ROOT}/lib/pathb/linux-aarch64-include")
end
ENV["NFCXX_PATHB_MODE"] = mode
# The IR back end keeps the module's functions in a file in TMPDIR; the front end runs in the base dir, so make it absolute
ENV["TMPDIR"] = HostSys.abs_path(ENV["TMPDIR"]) unless ENV["TMPDIR"].to_s.empty?

status = 0
files.each do |file|
  # realpath: the file's own path resolved, or for a missing file its directory's resolved path (GNU realpath prints it too)
  f = if File.exist?(file) then File.realpath(file)
      else "#{File.realpath(File.dirname(file))}/#{File.basename(file)}" rescue File.expand_path(file)
      end
  stem = File.basename(f).sub(/\.[^.]*\z/, "")
  # cpfe writes <stem>.ti into its working directory; remove it afterwards unless it existed before
  ti = File.join(base, "#{stem}.ti")
  had_ti = File.exist?(ti)
  # -tused: instantiate the templates this file uses (C has no templates)
  tused = lang == "c" ? [] : ["-tused"]
  cmd = [cpfe, *posix_def, *darwin_opts, "-D__CHAR_BIT__=8", std, dialect, "--wdir", "/", *gnu_opts, *tused, *user_opts,
         *sys_inc, *target_opts, *cuda_device_opts, *eh_tls, "--sys_include=#{base}/include", f]
  Dir.chdir(base) { system(*cmd) }
  status = $?.exitstatus || 1 unless $?.success?
  File.delete(ti) if !had_ti && File.exist?(ti)
end
exit status
