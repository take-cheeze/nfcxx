#!/usr/bin/env ruby
# nfcxx's --freestanding, --emit-c, --emit-hip and -E paths and the Path B compile and link of a freestanding program,
# ported from the bash in nfcxx: the argument checks that come before the back end is chosen, the --target checks, the
# include and GNU-version setup of the front end, the EDG front end run that prints the generated C (cpfe with
# --gen_c_file_name), the rewriter exec of --emit-hip, the preprocessor exec of -E, and the Path B compile (pathb-cc per
# source, -c or the link's objects) and link (cc with EDG's runtime and libc).
#
#   ruby scripts/nfcxx-freestanding.rb --facts=FILE ARG...
#
# prints the commands the bash runs for ARG..., one per line, then "STATUS n" (the exit status the bash ends with):
#   ENV NAME=VALUE         a variable the bash exports for the programs that follow (EDG_CPFE_DEFAULT_OPTIONS): printed
#                          before each RUN line it applies to, as the stub logs it
#   RUN PROGRAM ARG...     a program the driver runs (ROOT/build/edg/bin/cpfe, ROOT/scripts/pathb-cc, cc); its output is
#                          not part of the plan
#   EXEC PROGRAM ARG...    the program replaces nfcxx (--emit-hip: ROOT/build/cuda-rewrite; -E: g++). No STATUS line: the
#                          exit status is the program's.
# ROOT stands for the repository, WORK for the working directory, TMP for a temporary directory (mktemp -d).
#
# A refusal the bash makes before it runs anything (status 2: no input files, a bad --dialect, --target without
# --freestanding or --emit-c, an unknown --target, --emit-hip without one .cu, C sources with --emit-c, a module
# with --emit-c, a source on stdin without -E, -x with a language other than C++, Path B on a host it does not
# compile freestanding programs on, a missing QBE, an unknown --backend) prints only "STATUS 2". Any argument list
# outside the paths above, or one whose bash run would go on into a path not ported (the gcc backend, hosted
# compile and link, C inputs, modules, a cu input, -fsanitize, objects and libraries on the link line), exits 3 with
# "unported: ..." on stderr and prints nothing on stdout.
#
# FILE holds the facts the bash reads from the machine (tests/nfcxx-freestanding/run.sh writes it):
#   uname NAME              uname -s (Linux, Darwin)
#   machine NAME            uname -m
#   cxx-clang 0|1           the host C++ compiler (g++) is clang
#   gnu-dump VERSION        g++ -dumpfullversion (empty or absent: none)
#   host-sys DIR            a directory of the host C++ library, in host_sys_includes' order
#   target-table NAME       EDG's lib_NAME table exists (--target=NAME)
#   eh-tls 1                ${EDG}/../eh-tls exists
#   module PATH             PATH declares or imports a C++ module
#   exists PATH             PATH (relative to WORK) is an existing directory (abs_path of an -I with a slash)
#   qbe 1                   build/qbe/qbe exists (Path B's code generator; scripts/setup-qbe.sh)
#   pathb-ldrt PATH         what scripts/pathb-ldrt prints, relative to ROOT (libnfcxxld.a, the long double helpers)
#   sycl-header DIR         DIR (a -I value) holds sycl/detail/kernel_desc.hpp (the SYCL two-pass check of -c); none here
#
# Assumed, not read: the environment (NFCXX_* variables are not set, as the harness runs the bash with none), the
# built repository tools (ensure_tool finds build/cuda-rewrite and build/edg/bin/eccp fresh), the EDG base directory,
# which the front end runs in, and the link's libC.a (ROOT/build/edg/lib/libC.a, passed by path whether it exists or not).
# Path B's -I/-D/-U/-include/-std options come from the command line; -isystem and -m reach no Path B command line
# (the bash passes -isystem to eccp and the gcc -dM probe feeds eccp's -D options only), so the port does not model them
# for Path B.

class Unported < StandardError
end

# the bash ends with this status (after a refusal it makes before it runs anything)
class Ends < StandardError
  attr_reader :status

  def initialize(status)
    super("status #{status}")
    @status = status
  end
end

ROOT = "ROOT".freeze
WORK = "WORK".freeze
TMP = "TMP".freeze
EDG_BIN = "ROOT/build/edg/bin".freeze
EDG_BASE = "ROOT/build/edg-base".freeze
# the targets for which the driver passes --unsigned_chars (plain char is unsigned on their ABIs)
EDG_LIBC = "ROOT/build/edg/lib/libC.a".freeze
UNSIGNED_CHAR_TARGETS = %w[linux_aarch64 linux_armv7 linux_riscv32 linux_riscv64].freeze
# the machines Path B compiles freestanding programs on, per host (pb_fs_host in nfcxx)
PATHB_FS_MACHINES = { "Linux" => %w[x86_64 aarch64 arm64], "Darwin" => %w[arm64] }.freeze

class Facts
  def initialize(path)
    @single = {}
    @lists = Hash.new { |h, k| h[k] = [] }
    File.foreach(path) do |line|
      line = line.chomp
      next if line.empty? || line.start_with?("#")
      key, value = line.split(" ", 2)
      value ||= ""
      @single[key] ||= value
      @lists[key] << value
    end
  end

  def value(key)
    @single[key]
  end

  def list(key)
    @lists[key]
  end

  def flag?(key)
    @single[key] == "1"
  end

  def exists?(path)
    list("exists").include?(path)
  end
end

# host_gnu_version: major*10000 + minor*100 + patch from g++ -dumpfullversion; 150000 for a clang host without it
def host_gnu_version(facts)
  ver = facts.value("gnu-dump").to_s
  if ver.empty?
    return facts.flag?("cxx-clang") ? "150000" : nil
  end
  maj, min, pat = ver.split(".")
  (maj.to_i * 10000 + min.to_i * 100 + pat.to_i).to_s
end

# host_clang_version: the --clang_version value of the host clang (clang 21 is capped at 200000), or nil
def host_clang_version(facts)
  facts.flag?("cxx-clang") ? "200000" : nil
end

# pb_fs_host: Path B compiles freestanding programs on this host (x86-64 and aarch64 Linux, arm64 macOS)
def pb_fs_host?(facts)
  (PATHB_FS_MACHINES[facts.value("uname")] || []).include?(facts.value("machine"))
end

# abs_path of an -I value as the bash makes it (abs_path, which needs no existing path): a value without a slash
# names WORK's entry; with a slash, its directory must exist. Used by the EDG front end's command line (--emit-c).
def abs_include(value, facts)
  if value.start_with?("/") || value.include?("..") || value.end_with?("/")
    raise Unported, "-I#{value}: an absolute or parent path"
  end
  if value.include?("/")
    dir = File.dirname(value)
    raise Unported, "-I#{value}: its directory is not a fact" unless facts.exists?(dir)
  end
  "#{WORK}/#{value}"
end

# the argument loop of nfcxx for the options in this port; anything else is unported
def parse(argv)
  o = { emit_c: false, emit_hip: false, fs: false, target: nil, gnu: nil, dialect: nil, backend: nil, std: "--c++23",
        cflags: [], user_inc: [], srcs: [], cu: [], cfiles: [], diag: [], compile_only: false, preprocess: false,
        ppflags: [], xlang: "", stdin: false, out: "a.out", outset: false, sysdirs: [], preinc: [], isa: [] }
  i = 0
  while i < argv.size
    a = argv[i]
    case a
    when "--emit-c" then o[:emit_c] = true
    when "--emit-hip" then o[:emit_hip] = true
    when "--freestanding" then o[:fs] = true
    when /\A--target=(.*)\z/m then o[:target] = Regexp.last_match(1)
    when /\A--gnu-version=(.*)\z/m then o[:gnu] = Regexp.last_match(1)
    when /\A--dialect=(.*)\z/m then o[:dialect] = Regexp.last_match(1)
    when /\A--backend=(.*)\z/m
      o[:backend] = Regexp.last_match(1)
      raise Unported, "--backend= with an empty value" if o[:backend].empty?
    when /\A-std=c\+\+(.*)\z/m then o[:std] = "--c++#{Regexp.last_match(1)}"
    when /\A-std=gnu\+\+(.*)\z/m then o[:std] = "--c++#{Regexp.last_match(1)}"
    when "-o"
      raise Unported, "-o without a value" if i + 1 >= argv.size
      o[:out] = argv[i + 1]
      o[:outset] = true
      i += 1
    when "-c" then o[:compile_only] = true
    when "-E" then o[:preprocess] = true
    when "-P" then o[:ppflags] << "-P"
    when "-" then o[:stdin] = true
    when "-x"
      raise Unported, "-x without a value" if i + 1 >= argv.size
      o[:xlang] = argv[i + 1]
      i += 1
    when "-include"
      raise Unported, "-include without a value" if i + 1 >= argv.size
      o[:preinc] << argv[i + 1]
      i += 1
    when "-isystem"
      raise Unported, "-isystem without a value" if i + 1 >= argv.size
      o[:sysdirs] << argv[i + 1]
      i += 1
    when /\A-isystem./ then o[:sysdirs] << a.delete_prefix("-isystem")
    when /\A-m/ then o[:isa] << a
    when "-I", "-D", "-U"
      raise Ends, 2 if i + 1 >= argv.size
      o[:cflags] << "#{a}#{argv[i + 1]}"
      o[:user_inc] << argv[i + 1] if a == "-I"
      i += 1
    when /\A-I./
      o[:cflags] << a
      o[:user_inc] << a[2..]
    when /\A-[DU]./ then o[:cflags] << a
    when "-Wno-narrowing" then o[:diag] << "--diag_warning=narrowing_conversion"
    when "-fexceptions", "-fwrapv", "-fno-strict-aliasing", "-pipe", "-w", "-fvisibility-inlines-hidden" then nil
    when /\A-W/, /\A-fvisibility=/ then nil
    when /\A-/ then raise Unported, "option #{a}"
    when /\.cu\z/ then o[:cu] << a
    when /\.c\z/ then o[:cfiles] << a
    when /\.cpp2\z/, /\.o\z/, /\.a\z/, /\.so\z/ then raise Unported, "input #{a}"
    else
      raise Unported, "input #{a} in a directory" if a.include?("/")
      o[:srcs] << a
    end
    i += 1
  end
  o
end

# the EDG front end's line (cpfe runs in the EDG base directory; its defaults come from EDG_CPFE_DEFAULT_OPTIONS)
def run_lines(env, prog, args)
  out = []
  out << env if env
  out << (["RUN", prog] + args).join(" ")
  out
end

# -E: the host C++ compiler preprocesses (exec), with the options the bash gives it, before anything else is checked
def preprocess_plan(o)
  args = ["-E", "-std=#{o[:std].delete_prefix('--')}"]
  args += ["-x", o[:xlang]] unless o[:xlang].empty?
  args += o[:ppflags]
  args += o[:cflags]
  args += o[:sysdirs].map { |d| "-isystem#{d}" }
  o[:preinc].each { |f| args += ["-include", f] }
  args += o[:srcs]
  args << "-" if o[:stdin]
  args += ["-o", o[:out]] if o[:outset]
  [(["EXEC", "g++"] + args).join(" ")]
end

# --emit-c: the EDG front end alone, its generated C on stdout (hosted or freestanding)
def emit_plan(o, facts, dialect, sys_inc, env, source)
  raise Unported, "-isystem in a hosted --emit-c (the host's include lists are not ported)" unless o[:sysdirs].empty? || o[:fs]
  raise Unported, "host #{facts.value('uname')}" unless facts.value("uname") == "Linux"
  inc = o[:fs] ? ["-I#{ROOT}/lib"] : sys_inc + ["--sys_include=#{EDG_BASE}/include"]
  # each -I goes in front of the ones before it, as the bash prepends them in order
  o[:user_inc].each { |v| inc = ["-I#{abs_include(v, facts)}"] + inc }
  eh_tls = facts.flag?("eh-tls") ? ["--nfcxx_eh_thread_local"] : []
  args = ["-D_POSIX_SOURCE", "-D__CHAR_BIT__=8", o[:std], "--#{dialect}"] + eh_tls +
         env[:gnu_opts] + o[:diag] + inc + ["--gen_c_file_name=#{TMP}/out.c", "#{WORK}/#{source}"]
  run_lines(env[:line], "#{EDG_BIN}/cpfe", args) + ["STATUS 0"]
end

def host_dialect(facts)
  facts.flag?("cxx-clang") ? "clang" : "g++"
end

# the Path B compile and link of a freestanding program (the backend pathb): one pathb-cc run per source, then with -c
# the objects are the output; otherwise each source's object (TMP/pN.o) and the link with EDG's runtime and libc
def pathb_plan(o, facts, env, dialect, gnu)
  pb = o[:diag].dup
  pb << "--dialect=clang" if dialect == "clang" && !o[:dialect].nil?
  pb += ["--freestanding", "--eh-runtime", "--gnu-version=#{gnu}", "-I#{ROOT}/lib"]
  common = pb + ["-std=c++#{o[:std].delete_prefix('--c++')}"] + o[:cflags] + o[:preinc].flat_map { |f| ["-include", f] }
  lines = []
  if o[:compile_only]
    o[:srcs].each do |f|
      dst = o[:outset] ? o[:out] : File.basename(f).sub(/\.[^.]*\z/, "") + ".o"
      lines += run_lines(env, "#{ROOT}/scripts/pathb-cc", common + [f, "-o", dst])
    end
  else
    ldrt = facts.value("pathb-ldrt")
    raise Unported, "the output of scripts/pathb-ldrt is not a fact" if ldrt.nil?
    pobjs = []
    o[:srcs].each_with_index do |f, n|
      obj = "#{TMP}/p#{n}.o"
      lines += run_lines(env, "#{ROOT}/scripts/pathb-cc", common + [f, "-o", obj])
      pobjs << obj
    end
    link = ["-o", o[:out]] + pobjs + ["#{ROOT}/#{ldrt}", EDG_LIBC, "-lpthread", "-lm"]
    lines += run_lines(env, "cc", link)
  end
  lines + ["STATUS 0"]
end

def plan(argv, facts)
  o = parse(argv)
  # the sources the bash counts: the .cu and .cpp inputs (ncpp), then the .c files apart
  sources = o[:cu] + o[:srcs]
  raise Ends, 2 if sources.empty? && o[:cfiles].empty? && !o[:stdin]

  if o[:emit_hip]
    raise Ends, 2 unless o[:cu].size == 1
    return [(["EXEC", "#{ROOT}/build/cuda-rewrite", "--hip"] + o[:cflags] + [o[:cu][0]]).join(" ")]
  end

  raise Unported, "cu inputs (the rewriter runs before the rest)" unless o[:cu].empty?
  # the SYCL two-pass build of a -c compile whose -I directory holds the oneAPI kernel header (not a fact here)
  if o[:compile_only] && sources.size == 1 && o[:cfiles].empty? && !o[:preprocess] && !o[:emit_c] &&
     o[:user_inc].any? { |d| facts.list("sycl-header").include?(d) }
    raise Unported, "the SYCL two-pass build (-I directory with sycl/detail/kernel_desc.hpp)"
  end
  return preprocess_plan(o) if o[:preprocess]

  raise Ends, 2 if o[:stdin]
  raise Ends, 2 unless ["", "c++", "none"].include?(o[:xlang])
  dialect = o[:dialect] || host_dialect(facts)
  raise Ends, 2 unless %w[g++ clang].include?(dialect)

  if sources.any? { |s| facts.list("module").include?(s) }
    raise Ends, 2 if o[:emit_c]
    raise Unported, "C++ modules (docs/notes/modules.md)"
  end

  # the front-end include and GNU-version setup
  if o[:fs]
    gnu = o[:gnu].nil? || o[:gnu].empty? ? "130000" : o[:gnu]
    sys_inc = []
  else
    sys_inc = facts.list("host-sys").map { |d| "--sys_include=#{d}" }
    gnu = o[:gnu].nil? || o[:gnu].empty? ? host_gnu_version(facts) : o[:gnu]
  end

  gnu_opts = []
  if dialect == "clang"
    cv = host_clang_version(facts)
    gnu_opts = ["--clang_version=#{cv}"] if cv
  elsif gnu && !gnu.empty?
    gnu_opts = ["--gnu_version=#{gnu}"]
  end

  target = o[:target]
  if target && !target.empty?
    raise Unported, "--target=linux_k1om" if target == "linux_k1om"
    raise Ends, 2 unless o[:fs]
    raise Ends, 2 unless o[:emit_c]
    raise Ends, 2 unless facts.list("target-table").include?(target)
    gnu_opts += ["--target", target]
    gnu_opts << "--unsigned_chars" if UNSIGNED_CHAR_TARGETS.include?(target)
  end

  # EDG_CPFE_DEFAULT_OPTIONS is exported for every program that runs after this point
  env = { gnu_opts: gnu_opts, line: gnu_opts.empty? ? nil : "ENV EDG_CPFE_DEFAULT_OPTIONS=#{gnu_opts.join(' ')} " }

  raise Ends, 2 if o[:emit_c] && !o[:cfiles].empty?
  return emit_plan(o, facts, dialect, sys_inc, env, sources[0]) if o[:emit_c]

  # the compile and link path: C inputs and the hosted path are not ported
  raise Unported, "C inputs (not ported)" unless o[:cfiles].empty?
  raise Unported, "hosted compile and link (no --freestanding)" unless o[:fs]
  backend = o[:backend] || (pb_fs_host?(facts) ? "pathb" : "gcc")
  case backend
  when "pathb"
    raise Ends, 2 unless pb_fs_host?(facts)
    raise Ends, 2 unless facts.flag?("qbe")
  when "gcc" then raise Unported, "the gcc backend (eccp and the host C compiler are not ported)"
  else raise Ends, 2
  end
  # -m options (the gcc -dM probe feeds only eccp) and -isystem (eccp only) reach no Path B command line
  pathb_plan(o, facts, env[:line], dialect, gnu)
end

def main(argv)
  facts_path = nil
  rest = []
  argv.each do |a|
    if a.start_with?("--facts=") then facts_path = a.delete_prefix("--facts=") else rest << a end
  end
  abort "usage: nfcxx-freestanding.rb --facts=FILE ARG..." unless facts_path
  facts = Facts.new(facts_path)
  begin
    out = plan(rest, facts)
    puts out
    0
  rescue Ends => e
    puts "STATUS #{e.status}"
    0
  rescue Unported => e
    warn "unported: #{e.message}"
    3
  end
end

exit main(ARGV) if $PROGRAM_NAME == __FILE__
