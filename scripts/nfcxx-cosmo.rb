#!/usr/bin/env ruby
# nfcxx's --cosmo backend, ported from the bash in nfcxx: the cosmo block after the argument loop (cosmocc is the C compiler,
# NFCXX_GCC, NFCXX_SYS_INCLUDES, the cosmo defines), and the C-input path that runs cosmocc: each .c is compiled by cosmocc,
# then copied (-c) or linked by it (C only). docs/notes/cosmo.md. The argument loop is the subset this slice reads.
#
#   ruby scripts/nfcxx-cosmo.rb --facts=FILE ARG...
#
# prints the commands the bash runs for ARG..., one per line, then "STATUS n" (the exit status the bash ends with):
#   RUN PROGRAM ARG...    a program the driver runs: cosmocc for each C compile (-c -O2 -fwrapv -fno-strict-aliasing, the -I/-D/-U
#                         options, the cosmo defines, the .c, -o TMP/N.o) and for the C-only link (the objects, the link options, -o)
#   CP SRC DST            the object of a -c compile, copied to its output
# ROOT stands for the repository (cosmocc is ROOT/build/cosmocc/bin/cosmocc unless NFCXX_COSMOCC names another ROOT file) and TMP
# for a temporary directory (mktemp -d). A refusal the bash makes (status 2) prints the lines before it, then its status, and its
# message goes to stderr.
#
# Accepted: --cosmo, --backend=gcc, -c, -o FILE, -I/-D/-U (joined or separate), -lNAME, -LDIR, -Wl,..., -O*, -g[N], -std=cN, -W*
# (ignored), -w, -fwrapv, -fno-strict-aliasing, -fexceptions, -pipe, *.a and *.so (link inputs), and *.c inputs.
#
# Not covered (exit 3, "unported: ..." on stderr): an argument list without --cosmo; any other input (C++, .o, stdin); any other
# option; --backend=pathb and NFCXX_PATH=b, whose cosmo link (ape.lds, fixupobj, apelink) is reached only from Path B; NFCXX_BACKEND;
# NFCXX_* variables other than NFCXX_COSMOCC, NFCXX_GCC, NFCXX_SYS_INCLUDES and NFCXX_PATH (not b); a host other than Linux x86_64
# (the bash adds -D__AARCH64EL__ on aarch64); NFCXX_COSMOCC paths not under ROOT (the port cannot see other files).
#
# FILE holds the facts the bash reads from the machine (tests/nfcxx-cosmo/run.sh writes it):
#   root-exec REL          ROOT/REL is an executable file (the cosmocc stand-in); an absent file is not installed
#   uname-s NAME           uname -s of the host
#   uname-m NAME           uname -m of the host
# Environment: NFCXX_COSMOCC (empty: the default), NFCXX_GCC, NFCXX_SYS_INCLUDES (both overwritten by the cosmo block),
# NFCXX_PATH (b asks for Path B).
#
# Assumed, not read: host_dialect and host_gnu_version (probes that do not change the C commands), host_sys_includes (its
# output is NFCXX_SYS_INCLUDES, set by the cosmo block), the repository's tools (none runs on this path).

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
IGNORED = %w[-w -pipe -fwrapv -fno-strict-aliasing -fexceptions].freeze
ENV_OK = %w[NFCXX_COSMOCC NFCXX_GCC NFCXX_SYS_INCLUDES].freeze

class Facts
  def initialize(path)
    @root_exec = []
    @uname = {}
    File.foreach(path) do |line|
      key, value = line.chomp.split(" ", 2)
      case key
      when "root-exec" then @root_exec << value
      when "uname-s", "uname-m" then @uname[key] = value
      end
    end
  end

  def root_exec?(rel)
    @root_exec.include?(rel)
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
    elsif a == "-c"
      st[:compile_only] = true
      st[:files] << "-c"
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
    elsif a.match?(/\A-Wl,/) || a.match?(/\A-l./) || a.match?(/\A-L./) || a.match?(/\A-O[0-9a-z]*\z/) ||
          a.match?(/\A-g[0-9]?\z/) || a.match?(/\A-std=(c|gnu)[0-9]+\z/)
      st[:files] << a
    elsif a == "-Wno-narrowing"
      raise Unported, "-Wno-narrowing is an EDG option"
    elsif a.start_with?("-W") || IGNORED.include?(a)
      nil
    elsif !a.start_with?("-") && (a.end_with?(".a") || a.end_with?(".so"))
      st[:files] << a
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
    next if key == "NFCXX_PATH" && env[key] != "b"

    raise Unported, "#{key}=#{env[key]} is set"
  end
end

# the cosmocc the bash runs: NFCXX_COSMOCC, else the default; it must be executable (the bash checks with -x)
def cosmocc_path(env, facts)
  path = env["NFCXX_COSMOCC"]
  path = DEFAULT_COSMOCC if path.nil? || path.empty?
  raise Unported, "NFCXX_COSMOCC=#{path} is not under ROOT" unless path.start_with?("ROOT/")
  raise Failed, "nfcxx: #{path} is not installed; run scripts/setup-cosmo.sh (or set NFCXX_COSMOCC)" unless facts.root_exec?(path.delete_prefix("ROOT/"))

  path
end

def build(args, env, facts, lines)
  st = { cosmo: false, backend: nil, backend_explicit: false, out: "a.out", outset: false, compile_only: false,
         cfiles: [], files: [], cflags: [] }
  parse(args, st)
  raise Unported, "no --cosmo: the other backends are not this port" unless st[:cosmo]

  check_env(env)
  raise Unported, "host #{facts.uname("uname-s")} #{facts.uname("uname-m")}" unless facts.uname("uname-s") == "Linux" && facts.uname("uname-m") == "x86_64"
  raise Failed, "nfcxx: no input files" if st[:cfiles].empty?
  raise Unported, "Path B (--backend=pathb or NFCXX_PATH=b) with --cosmo" if st[:backend] == "pathb" || env["NFCXX_PATH"] == "b"
  raise Failed, "nfcxx: --cosmo needs --backend=gcc or --backend=pathb" if st[:backend_explicit] && st[:backend] != "gcc"

  prog = cosmocc_path(env, facts)
  cflags = st[:cflags] + COSMO_DEFINES
  cobjs = []
  st[:cfiles].each_with_index do |c, n|
    obj = "TMP/#{n}.o"
    lines << ["RUN", prog, *C_FLAGS, *cflags, c, "-o", obj].join(" ")
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
  lines << ["RUN", prog, *cobjs, *st[:files], "-o", st[:out]].join(" ")
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
