#!/usr/bin/env ruby
# nfcxx's --cosmo backend, ported from the bash in nfcxx: the -E block (the host C++ preprocessor, which runs before the
# cosmo block), the EDG check, the cosmo block after the argument loop (cosmocc is the C compiler, NFCXX_GCC,
# NFCXX_SYS_INCLUDES, the cosmo defines), and the C-input path that runs cosmocc: each .c is compiled by cosmocc, then copied
# (-c) or linked by it (C and object inputs, with -shared, -rdynamic and -fsanitize=address as the bash gives them).
# docs/notes/cosmo.md. The argument loop is the subset this slice reads.
#
#   ruby scripts/nfcxx-cosmo.rb --facts=FILE ARG...
#
# prints the commands the bash runs for ARG..., one per line, then "STATUS n" (the exit status the bash ends with):
#   RUN PROGRAM ARG...    a program the driver runs: g++ -E (the preprocessor, with -E), cosmocc for each C compile (-c -O2
#                         -fwrapv -fno-strict-aliasing, the sanitizer and -fPIC options, the -I/-D/-U options, the cosmo
#                         defines, the .c, -o TMP/N.o) and for the C-only link (the link options, the objects, the link
#                         inputs, -o)
#   CP SRC DST            the object of a -c compile, copied to its output
# ROOT stands for the repository (cosmocc is ROOT/build/cosmocc/bin/cosmocc unless NFCXX_COSMOCC names another file) and TMP
# for a temporary directory (mktemp -d). SB stands for the sandbox's host directory (a file outside ROOT that the facts name).
# A refusal the bash makes (status 2) prints the lines before it, then its status, and its message goes to stderr.
#
# -E is the bash's exec of the host C++ compiler, before any cosmo check: its line has the .c inputs left out (they are not
# sources of the preprocessor, as the bash's srcs holds only C++ inputs), so `--cosmo -E a.c` runs g++ with no file.
#
# Accepted: --cosmo, --backend=gcc|pathb, -c, -E, -P, -o FILE, -I/-D/-U (joined or separate), -lNAME, -LDIR, -l and -L alone
# (link options, as the bash's -* case gives them: the next word is then a source), -Wl,..., -O*, -g[N], -std=cN, -std=c++NN and
# -std=gnu++NN (the -E line only), -W* (ignored), -w, -fwrapv, -fno-strict-aliasing, -fexceptions, -pipe, -pthread, -fPIE, -fpie,
# -pie, -Wno-narrowing, -fvisibility=* (no effect on the C path), -fPIC, -fpic, -shared (implies -fPIC), -rdynamic,
# -fsanitize=address with -fno-omit-frame-pointer and -fomit-frame-pointer, *.a and *.so (link inputs), *.o (link inputs),
# *.c inputs, and any other word that is not an option (a C++ source: the EDG path, see below).
#
# Refused, with the bash's status and message: no input files (status 2); the EDG path without EDG built (a C++ source, or an
# object with no C source: status 2, "EDG not built"); the cosmo backend checks (--backend other than gcc or pathb, status 2);
# cosmocc not installed (status 2); QBE not built for the Path B backend (status 2); -c with -o and more than one source
# (status 2, after the compiles).
#
# Not covered (exit 3, "unported: ..." on stderr): an argument list without --cosmo; the EDG path when EDG is built (a C++
# source, or an object with C sources: eccp's command lines are not modeled); the Path B C compile when QBE is built (scripts/
# pathb-cc), -fsanitize=address with an object and no -c or -shared (the shim block builds the VLA runtime, scripts/asan-vla),
# and the Path B cosmo link (ape.lds, fixupobj, apelink), which only runs after the EDG path; -m options (the bash
# runs the host gcc probes concurrently, so their log order is not fixed); NFCXX_BACKEND; NFCXX_* variables other than
# NFCXX_COSMOCC, NFCXX_GCC, NFCXX_SYS_INCLUDES, NFCXX_PATH and NFCXX_BACKEND; EDG_BUILD; a host other than Linux x86_64 (the bash adds
# -D__AARCH64EL__ on aarch64); a NFCXX_COSMOCC path that is neither under ROOT nor named by a host fact (the port cannot see
# other files); a relative NFCXX_COSMOCC; and the other options.
#
# FILE holds the facts the bash reads from the machine (tests/nfcxx-cosmo/run.sh writes it):
#   root-exec REL          ROOT/REL is an executable file (the cosmocc stand-in, or the EDG and QBE tools when present); an
#                          absent file is not installed
#   host-exec PATH         PATH (a file outside ROOT, named as the case names it) is executable
#   host-file PATH         PATH is a file that is not executable
#   host-absent PATH       PATH does not exist
#   uname-s NAME           uname -s of the host
#   uname-m NAME           uname -m of the host
# Environment: NFCXX_COSMOCC (empty: the default), NFCXX_GCC, NFCXX_SYS_INCLUDES (both overwritten by the cosmo block),
# NFCXX_PATH (b asks for Path B), NFCXX_BACKEND (the initial backend; a value other than pathb becomes gcc under --cosmo).
#
# Assumed, not read: host_dialect and host_gnu_version (probes that do not change the C commands), host_sys_includes (its
# output is NFCXX_SYS_INCLUDES, set by the cosmo block), the repository's tools (none runs on this path), the cu and cpp2
# preparation (no .cu or .cpp2 input is accepted here), and the SYCL two-pass build (its header is not under any -I).

class Unported < StandardError
end

# the bash exits with a status after it prints its lines (a refusal it makes, such as a missing cosmocc)
class Failed < StandardError
  attr_reader :status

  def initialize(message, status = 2)
    super(message)
    @status = status
  end
end

DEFAULT_COSMOCC = "ROOT/build/cosmocc/bin/cosmocc".freeze
C_FLAGS = %w[-c -O2 -fwrapv -fno-strict-aliasing].freeze
COSMO_DEFINES = %w[-D__COSMOPOLITAN__ -D__COSMOCC__ -D__FATCOSMOCC__].freeze
# options the bash takes and that change nothing on the C path (EDG and Path B options, the -E line has no use for them)
NO_EFFECT = %w[-w -pipe -fwrapv -fno-strict-aliasing -fexceptions -pthread -fPIE -fpie -pie -Wno-narrowing
               -fvisibility-inlines-hidden].freeze
ENV_OK = %w[NFCXX_COSMOCC NFCXX_GCC NFCXX_SYS_INCLUDES NFCXX_PATH NFCXX_BACKEND].freeze
EDG_ECCP = "build/edg/bin/eccp".freeze
QBE_TOOL = "build/qbe/qbe".freeze

class Facts
  def initialize(path)
    @root_exec = []
    @host = {}
    @uname = {}
    File.foreach(path) do |line|
      key, value = line.chomp.split(" ", 2)
      case key
      when "root-exec" then @root_exec << value
      when "host-exec" then @host[value] = :exec
      when "host-file" then @host[value] = :file
      when "host-absent" then @host[value] = :absent
      when "uname-s", "uname-m" then @uname[key] = value
      end
    end
  end

  def root_exec?(rel)
    @root_exec.include?(rel)
  end

  # :exec, :file, :absent, or nil when the facts do not say
  def host(path)
    @host[path]
  end

  def uname(key)
    @uname[key]
  end
end

# the argument loop of nfcxx, for the options of this slice (a bash option not listed here is unported)
def parse(args, st)
  i = 0
  while i < args.size
    a = args[i]
    if a == "--cosmo"
      st[:cosmo] = true
    elsif a.start_with?("--backend=")
      st[:backend] = a.delete_prefix("--backend=")
      st[:backend_explicit] = true
    elsif a.start_with?("-") && a.end_with?(".c")
      raise Unported, "option-shaped source #{a}"
    elsif a.end_with?(".c")
      st[:cfiles] << a
    elsif a.end_with?(".cu") || a.end_with?(".cpp2")
      raise Unported, "argument #{a} (CUDA and cpp2 inputs are not ported)"
    elsif a == "-c"
      st[:compile_only] = true
    elsif a == "-E"
      st[:preprocess] = true
    elsif a == "-P"
      st[:ppflags] << a
    elsif a == "-o"
      raise Unported, "-o without a file" if i + 1 >= args.size
      st[:out] = args[i + 1]
      st[:outset] = true
      i += 1
    elsif %w[-I -D -U].include?(a)
      raise Failed, "nfcxx: #{a} needs an argument" if i + 1 >= args.size
      st[:cflags] << a + args[i + 1]
      st[:files] << a + args[i + 1]
      i += 1
    elsif a.match?(/\A-[IDU]./)
      st[:cflags] << a
      st[:files] << a
    elsif a == "-shared"
      st[:shared] = true
      st[:pic] = true
    elsif a == "-fPIC" || a == "-fpic"
      st[:pic] = true
    elsif a == "-rdynamic"
      st[:rdynamic] = true
    elsif a == "-fsanitize=address"
      st[:asan] = true
    elsif a == "-fno-omit-frame-pointer" || a == "-fomit-frame-pointer"
      st[:asanopts] << a
    elsif (m = a.match(/\A-std=(?:gnu\+\+|c\+\+)(.*)\z/m))
      st[:std] = "c++#{m[1]}"
    elsif a.match?(/\A-m/)
      raise Unported, "#{a}: the bash runs the host gcc probes concurrently, so their log order is not fixed"
    elsif a.match?(/\A-fvisibility=/) || NO_EFFECT.include?(a) || (a.start_with?("-W") && !a.start_with?("-Wl,"))
      nil
    elsif a.start_with?("-Wl,") || a.match?(/\A-l./) || a.match?(/\A-L./) || a == "-L" || a == "-l" ||
          a.match?(/\A-O[0-9a-z]*\z/) || a.match?(/\A-g[0-9]?\z/) || a.match?(/\A-std=(c|gnu)[0-9]+\z/)
      st[:files] << a
    elsif a.end_with?(".o")
      st[:objs] << a
      st[:files] << a
    elsif !a.start_with?("-") && (a.end_with?(".a") || a.end_with?(".so"))
      st[:files] << a
    elsif !a.start_with?("-")
      st[:srcs] << a
    else
      raise Unported, "argument #{a}"
    end
    i += 1
  end
end

def check_env(env)
  env.each_key do |key|
    next unless key.start_with?("NFCXX_")
    next if ENV_OK.include?(key)

    raise Unported, "#{key}=#{env[key]} is set"
  end
  raise Unported, "EDG_BUILD is set (the EDG tree is not looked up here)" if env.key?("EDG_BUILD")
end

# the cosmocc the bash runs: NFCXX_COSMOCC, else the default; it must be executable (the bash checks with -x)
def cosmocc_path(env, facts)
  path = env["NFCXX_COSMOCC"]
  path = DEFAULT_COSMOCC if path.nil? || path.empty?
  if path.start_with?("ROOT/")
    raise Failed, "nfcxx: #{path} is not installed; run scripts/setup-cosmo.sh (or set NFCXX_COSMOCC)" unless facts.root_exec?(path.delete_prefix("ROOT/"))

    return path
  end
  case facts.host(path)
  when :exec then path
  when :file, :absent
    raise Failed, "nfcxx: #{path} is not installed; run scripts/setup-cosmo.sh (or set NFCXX_COSMOCC)"
  else
    raise Unported, "NFCXX_COSMOCC=#{path}: no fact says what this file is (the port sees ROOT and the facts only)"
  end
end

def build(args, env, facts, lines)
  st = { cosmo: false, backend: nil, backend_explicit: false, out: "a.out", outset: false, compile_only: false,
         preprocess: false, std: "c++23", cfiles: [], srcs: [], objs: [], files: [], cflags: [], ppflags: [],
         shared: false, pic: false, rdynamic: false, asan: false, asanopts: [] }
  parse(args, st)
  raise Unported, "no --cosmo: the other backends are not this port" unless st[:cosmo]

  check_env(env)
  raise Unported, "host #{facts.uname("uname-s")} #{facts.uname("uname-m")}" unless facts.uname("uname-s") == "Linux" && facts.uname("uname-m") == "x86_64"
  raise Failed, "nfcxx: no input files" if st[:cfiles].empty? && st[:srcs].empty? && st[:objs].empty?

  if st[:preprocess]
    # the -E block: exec of the host C++ compiler on the C++ sources (no cosmo check runs before it)
    lines << ["RUN", "g++", "-E", "-std=#{st[:std]}", *st[:ppflags], *st[:cflags], *st[:srcs],
              *(st[:outset] ? ["-o", st[:out]] : [])].join(" ")
    return
  end

  # the EDG check: C++ sources, or objects with no C source, need eccp
  edg = facts.root_exec?(EDG_ECCP)
  if st[:srcs].any? || (st[:objs].any? && st[:cfiles].empty?)
    raise Unported, "C++ or object input with EDG built (#{EDG_ECCP}): the EDG path is not modeled" if edg

    raise Failed, "nfcxx: EDG not built; run scripts/setup-edg.sh"
  end
  raise Unported, "C and object inputs with EDG built: the link is the EDG path" if edg && st[:objs].any?

  # the cosmo block: Path B when NFCXX_PATH=b, else the gcc backend (--backend=gcc or none)
  # backend: --backend, else NFCXX_BACKEND (the bash's initial value; only --backend is checked against --cosmo)
  backend = st[:backend] || env["NFCXX_BACKEND"]
  backend = "pathb" if env["NFCXX_PATH"] == "b"
  if backend != "pathb"
    raise Failed, "nfcxx: --cosmo needs --backend=gcc or --backend=pathb" if st[:backend_explicit] && st[:backend] != "gcc"

    backend = "gcc"
  end
  prog = cosmocc_path(env, facts)
  if backend == "pathb"
    raise Failed, "nfcxx: QBE not built; run scripts/setup-qbe.sh" unless facts.root_exec?(QBE_TOOL)

    raise Unported, "Path B C compile (scripts/pathb-cc) with QBE built: not modeled"
  end

  asan_c = st[:asan] ? ["-fsanitize=address", "-fno-omit-frame-pointer", *st[:asanopts]] : []
  # the shim block: with an object and -fsanitize=address, scripts/asan-vla builds the C++ VLA runtime before the link; that
  # build is not run by this port (its success is not known here)
  if st[:asan] && !st[:compile_only] && !st[:shared] && st[:objs].any?
    raise Unported, "-fsanitize=address with an object: the shim block builds the VLA runtime (scripts/asan-vla)"
  end

  cflags = st[:cflags] + COSMO_DEFINES
  cflags_pic = st[:pic] ? ["-fPIC"] : []
  ldopts = []
  ldopts << "-shared" if st[:shared]
  ldopts << "-rdynamic" if st[:rdynamic]
  cobjs = []
  st[:cfiles].each_with_index do |c, n|
    obj = "TMP/#{n}.o"
    lines << ["RUN", prog, *C_FLAGS, *asan_c, *cflags_pic, *cflags, c, "-o", obj].join(" ")
    cobjs << obj
  end
  if st[:compile_only]
    raise Failed, "nfcxx: -c with -o needs exactly one source" if st[:outset] && cobjs.size != 1

    st[:cfiles].each_with_index do |c, i|
      dst = st[:outset] ? st[:out] : "#{File.basename(c, '.c')}.o"
      lines << "CP #{cobjs[i]} #{dst}"
    end
    return
  end
  lines << ["RUN", prog, *asan_c, *ldopts, *cobjs, *st[:files], "-o", st[:out]].join(" ")
end

def main(argv)
  facts_arg = argv.shift.to_s
  raise ArgumentError, "the first argument is --facts=FILE" unless facts_arg.start_with?("--facts=")

  facts = Facts.new(facts_arg.delete_prefix("--facts="))
  lines = []
  status = 0
  begin
    build(argv, ENV.to_h, facts, lines)
  rescue Failed => e
    $stderr.write("#{e.message}\n")
    status = e.status
  end
  lines.each { |line| $stdout.write("#{line}\n") }
  $stdout.write("STATUS #{status}\n")
  0
rescue Unported => e
  $stderr.write("unported: #{e.message}\n")
  3
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
