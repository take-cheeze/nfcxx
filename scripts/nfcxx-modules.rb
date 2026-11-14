#!/usr/bin/env ruby
# Plan printer for nfcxx's C++ module build (docs/notes/modules.md): the modules block of nfcxx (the refusals, the
# module options of a compile) and mod_build_program (the order of the interface units, the nested compiles, the link).
# A program with no module source takes the plain path (one or more sources, planned here too).
#
#   ruby scripts/nfcxx-modules.rb --facts=FILE [--cwd=DIR] ARGS...
#
# ARGS are nfcxx's arguments. The output is one line per tool call the bash makes for the build, then "STATUS N" (the
# bash's exit status). The tools:
#   ECCP WORDS    the gcc backend's EDG call (eccp): a compile, or the link of the objects
#   PATHB WORDS   Path B's compile (scripts/pathb-cc), the default backend or --backend=pathb
#   CC WORDS      Path B's link (cc -o OUT OBJECTS ...): the objects and -o OUT
# The words of a module compile are
#   --modules --modules_directory DIR [--create_module_interface DIR/NAME.eifc] SOURCE -o OUT
# and those of a plain compile are SOURCE -o OUT. Paths are absolute: relative ones are taken under --cwd. TMP is the
# bash's mktemp -d directory (mdir when --module-dir is not given), TMP/mN.o the objects of the nested compiles of a
# module build, TMP/pN.o the objects of a plain Path B build and TMP/N.o the objects of its C sources.
#
# The backend: --backend= as given; else gcc for -shared (Path B is the default otherwise). -E is the host C++ compiler's
# preprocessing, which the bash runs before anything else: no module or backend line, and the status is the host's.
# -fsanitize=address and -fno-omit-frame-pointer change only options the port does not print (the libasan link and the
# checks), so they are planned as the same words.
#
# Path B's fallback: a Path B build that fails on a file (a pathb-fail fact, status nonzero) on the default backend makes
# the bash run the command again with NFCXX_BACKEND=gcc. The output is then the lines so far (the failed Path B line
# included) and the gcc run's. In a module build the fallback is per nested compile (each nested run is this driver
# again), and the link is unchanged. An explicit --backend=pathb that fails exits with the Path B status: not modelled.
#
# Exit status: 0 planned; 2 the bash refuses (its message on stderr, STATUS 2 on stdout); 3 not covered (unported, the
# reason on stderr). Not covered: --emit-c on the plain path (EDG's front end cpfe is not built in the sandbox), an explicit
# --backend=pathb with a failing file, options outside the list below (-M, --cosmo, --target, --freestanding, -m*, ...),
# -fsanitize other than address, CUDA and cpp2 inputs. The port assumes every step succeeds except the failures the facts
# give. The environment has no NFCXX_* variables and build/qbe/qbe exists (run.sh's sandbox).
#
# FACTS (--facts=FILE): SRC lines and the other "key value" lines are read; the others are ignored.
#   SRC PATH MODULE(0|1) DECL(- if none) IMPORTS(- or a comma list) RC MESSAGE(- if none)   tab-separated
#     What the bash reads from the source: mod_is_module_src, mod_decl_name, mod_imports and mod_check_src (RC and MESSAGE
#     are its exit status and output). tests/nfcxx-modules/run.sh writes these by running those functions from nfcxx.
#   pathb-fail ARG RC   the status of Path B's build of the argument ARG as given (stub.sh's pathb-cc exits with it); 0 or
#                       absent: it builds
#   preprocess RC       the status of the host preprocessor (stub.sh's g++ -E)
require "pathname"
require "set"

class Unported < StandardError; end

class Refused < StandardError
  attr_reader :status

  def initialize(status, message)
    super(message)
    @status = status
  end
end

# a Path B build that failed on the default backend: the bash runs the command again with gcc, so the output is the
# lines so far (LINES, the failed Path B line included) and then the gcc run's
class Fallback < StandardError
  attr_reader :lines

  def initialize(lines)
    super("Path B did not build a file")
    @lines = lines
  end
end

Fact = Struct.new(:modsrc, :decl, :imports, :rc, :msg)

# nfcxx's module check: C++ modules need C++20 or later (--c++NN is the name nfcxx gives the standard)
OLD_STANDARDS = %w[--c++98 --c++03 --c++11 --c++14 --c++17].freeze
# options that do not change the plan's words (checked by run.sh): they reach the compile and the link, and the port does not
# print them. -fPIC and -fPIE go to eccp's C compile options or to pathb-cc --pic; -rdynamic and -pie to the link options.
PLAIN_FLAG = /\A(-O[0-3sg]?|-g|-Wall|-Wextra|-pthread|-D.+|-I.+|-l.+|-L.+|-Wl,.+|-fPIC|-fpic|-fPIE|-fpie|-pie|-rdynamic|-pipe|-fexceptions|-fwrapv|-fno-strict-aliasing|-W\S*|-w|-fvisibility=\S+|-fvisibility-inlines-hidden)\z/

def load_facts(path)
  facts = { pathb: {}, preprocess: 0 }
  File.foreach(path) do |line|
    f = line.chomp.split("\t", -1)
    if f[0] == "SRC"
      facts[f[1]] = Fact.new(f[2] == "1", f[3] == "-" ? nil : f[3], f[4] == "-" ? [] : f[4].split(","),
                             Integer(f[5], 10), f[6] == "-" ? nil : f[6])
      next
    end
    k, a, b = line.split
    case k
    when "pathb-fail" then facts[:pathb][a] = Integer(b, 10)
    when "preprocess" then facts[:preprocess] = Integer(a, 10)
    end
  end
  facts
end

# the command line, as the bash's parser reads it (the cases it does not model raise Unported)
def parse(args)
  opt = { std: "--c++23", out: "a.out", outset: false, compile: false, emit_c: false, moddir: nil,
          backend: nil, shared: false, preprocess: false, srcs: [], cfiles: [], objs: [] }
  i = 0
  while i < args.size
    a = args[i]
    case a
    when "-c" then opt[:compile] = true
    when "-o"
      raise Unported, "-o with no file" if i + 1 >= args.size
      i += 1
      opt[:out] = args[i]
      opt[:outset] = true
    when /\A-std=(?:gnu\+\+|c\+\+)(.+)\z/ then opt[:std] = "--c++#{Regexp.last_match(1)}"
    when "--emit-c" then opt[:emit_c] = true
    when "-E" then opt[:preprocess] = true
    when "-shared" then opt[:shared] = true
    when "-fsanitize=address", "-fno-sanitize=address", "-fno-omit-frame-pointer", "-fomit-frame-pointer" then nil
    when /\A--module-dir=(.*)\z/
      dir = Regexp.last_match(1)
      opt[:moddir] = dir.empty? ? nil : dir
    when "--backend=gcc" then opt[:backend] = "gcc"
    when "--backend=pathb" then opt[:backend] = "pathb"
    when PLAIN_FLAG then nil
    when /\.c\z/ then opt[:cfiles] << a
    when /\.(cu|cpp2)\z/ then raise Unported, "#{a}: CUDA and cpp2 inputs are not ported"
    when /\.(o|a|so)\z/ then opt[:objs] << a
    when /\A-/ then raise Unported, "option #{a} is not ported"
    else opt[:srcs] << a
    end
    i += 1
  end
  opt
end

# abs PATH CWD: the path as the bash's cd && pwd -P gives it (no symlinks in the work tree; . and .. are removed)
def abs(path, cwd)
  joined = path.start_with?("/") ? path : File.join(cwd, path)
  Pathname.new(joined).cleanpath.to_s
end

def decl_of(facts, src)
  facts[src].decl
end

# the backend the bash builds with: --backend= as given; else gcc for -shared (the default is Path B otherwise)
def backend_of(opt)
  return opt[:backend] if opt[:backend]

  opt[:shared] ? "gcc" : "pathb"
end

# the default backend (no --backend=): a Path B failure on a file falls back to gcc
def default_backend?(opt)
  opt[:backend].nil? && !opt[:shared]
end

# mod_build_program's order: the interface units in dependency order (a unit goes once every unit it imports is done),
# then the other sources in the order given
def build_order(srcs, facts)
  ifaces = srcs.select { |s| decl_of(facts, s) }
  others = srcs.reject { |s| decl_of(facts, s) }
  names = ifaces.map { |s| decl_of(facts, s) }
  pending = ifaces.dup
  done = Set.new
  ordered = []
  until pending.empty?
    progress = false
    rest = []
    pending.each do |s|
      ready = facts[s].imports.all? { |d| !names.include?(d) || done.include?(d) }
      if ready
        ordered << s
        done << decl_of(facts, s)
        progress = true
      else
        rest << s
      end
    end
    raise Refused.new(2, "nfcxx: cyclic module imports among: #{rest.join(' ')}") unless progress
    pending = rest
  end
  ordered + others
end

def module_words(dir, decl, src)
  words = ["--modules", "--modules_directory", dir]
  words += ["--create_module_interface", "#{dir}/#{decl}.eifc"] if decl
  words + [src]
end

# the output of a compile with -c: the -o file; without one, gcc's compile names it a.out and Path B's names it
# after the source (basename.o, in the directory of the command)
def compile_out(opt, src, backend)
  return opt[:out] if opt[:outset] || backend == "gcc"

  File.basename(src).sub(/\.[^.]*\z/, "") + ".o"
end

# the link of the objects: eccp takes them before -o; Path B's cc takes -o first, then the objects
def link_line(opt, objs, cwd)
  return ["ECCP", *objs, "-o", abs(opt[:out], cwd)] if backend_of(opt) == "gcc"

  ["CC", "-o", abs(opt[:out], cwd), *objs]
end

# one Path B call (its line is pushed to LINES). KEY is the argument as given (the facts name it). A failing build on the
# default backend raises Fallback; an explicit --backend=pathb is not modelled past its failure.
def pathb_call(opt, facts, lines, key, words)
  lines << ["PATHB", *words]
  return if facts[:pathb].fetch(key, 0).zero?
  raise Unported, "--backend=pathb: a failing Path B build of #{key} exits with its status (not modelled)" unless default_backend?(opt)

  raise Fallback, lines
end

# one compile of a source in a module build (a nested run, or the -c run): the backend's line; on the default backend,
# a failing Path B build is followed by the gcc run (the same words, GCC_OUT the output it names)
def compile_run(opt, facts, key, words, pb_out, gcc_out)
  return [["ECCP", *words, "-o", gcc_out]] if backend_of(opt) == "gcc"

  lines = []
  begin
    pathb_call(opt, facts, lines, key, [*words, "-o", pb_out])
  rescue Fallback => e
    return e.lines + [["ECCP", *words, "-o", gcc_out]]
  end
  lines
end

# a program with no module source: the unchanged path. The gcc backend's eccp call compiles and links all the sources; Path B
# compiles each to TMP/pN.o and cc links them (the C sources to TMP/N.o, linked with them and not projected)
def plain_pathb(opt, facts, cwd, lines)
  opt[:cfiles].each_with_index do |c, n|
    pathb_call(opt, facts, lines, c, ["-o", "TMP/#{n}.o"])
  end
  if opt[:compile]
    opt[:srcs].each do |s|
      pathb_call(opt, facts, lines, s, [abs(s, cwd), "-o", abs(compile_out(opt, s, "pathb"), cwd)])
    end
    lines
  else
    objs = opt[:srcs].each_with_index.map do |s, n|
      pathb_call(opt, facts, lines, s, [abs(s, cwd), "-o", "TMP/p#{n}.o"])
      "TMP/p#{n}.o"
    end
    lines << link_line(opt, objs, cwd)
  end
end

# gcc: one eccp call compiles (-c) or compiles and links all the sources, to the -o file (a.out without one)
def plain_gcc(opt, cwd)
  [["ECCP", *opt[:srcs].map { |s| abs(s, cwd) }, "-o", abs(opt[:out], cwd)]]
end

def plain_plan(opt, facts, cwd)
  raise Unported, "--emit-c on the plain path: EDG's front end (cpfe) is not built in the sandbox" if opt[:emit_c]
  return plain_gcc(opt, cwd) if backend_of(opt) == "gcc"

  lines = []
  begin
    plain_pathb(opt, facts, cwd, lines)
  rescue Fallback => e
    e.lines + plain_gcc(opt, cwd)
  end
end

def module_plan(opt, facts, cwd)
  # the modules block of nfcxx (before the backend is chosen)
  raise Refused.new(2, "nfcxx: C++ modules need -std=c++20 or later") if OLD_STANDARDS.include?(opt[:std])
  if opt[:emit_c]
    raise Refused.new(2, "nfcxx: --emit-c does not support C++ modules yet (docs/notes/modules.md)")
  end
  unless opt[:cfiles].empty?
    raise Refused.new(2, "nfcxx: C sources cannot be built with C++ modules yet (docs/notes/modules.md)")
  end
  opt[:srcs].each do |s|
    f = facts[s]
    raise Refused.new(f.rc, f.msg) unless f.rc.zero?
  end

  if opt[:compile]
    raise Refused.new(2, "nfcxx: -c with C++ modules takes one source") unless opt[:srcs].size == 1

    s = opt[:srcs][0]
    dir = abs(opt[:moddir] || File.dirname(opt[:out]), cwd)
    words = module_words(dir, decl_of(facts, s), abs(s, cwd))
    compile_run(opt, facts, s, words, abs(compile_out(opt, s, "pathb"), cwd), abs(compile_out(opt, s, "gcc"), cwd))
  else
    order = build_order(opt[:srcs], facts)
    # mod_build_program: each compile is this driver again (-c, the interface directory, the other options)
    nested_dir = opt[:moddir] ? abs(opt[:moddir], cwd) : "TMP"
    lines = []
    order.each_with_index do |s, n|
      # a nested compile of a source with no module statement is the unchanged path: no module words
      words = if facts[s].modsrc
                module_words(nested_dir, decl_of(facts, s), abs(s, cwd))
              else
                [abs(s, cwd)]
              end
      lines.concat compile_run(opt, facts, s, words, "TMP/m#{n}.o", "TMP/m#{n}.o")
    end
    objs = (0...order.size).map { |n| "TMP/m#{n}.o" }
    lines << link_line(opt, objs, cwd)
  end
end

def plan(args, facts, cwd)
  opt = parse(args)
  if opt[:preprocess]
    # -E runs first, before any check of the modules or the backend: the host preprocessor's status is the bash's
    raise Unported, "-E with no input file" if opt[:srcs].empty? && opt[:cfiles].empty? && opt[:objs].empty?
    raise Unported, "-E: the host preprocessor exits nonzero (not modelled)" unless facts[:preprocess].zero?

    return ["STATUS 0"]
  end
  opt[:srcs].each { |s| raise Unported, "no fact for #{s}" unless facts[s] }
  raise Unported, "no source" if opt[:srcs].empty?
  lines = if opt[:srcs].any? { |s| facts[s].modsrc }
            module_plan(opt, facts, cwd)
          else
            plain_plan(opt, facts, cwd)
          end
  lines.map { |l| l.join(" ") } + ["STATUS 0"]
end

def main(argv)
  facts_path = nil
  cwd = Dir.pwd
  args = []
  argv.each do |a|
    if a.start_with?("--facts=") then facts_path = a.delete_prefix("--facts=")
    elsif a.start_with?("--cwd=") then cwd = a.delete_prefix("--cwd=")
    else args << a
    end
  end
  unless facts_path
    warn "usage: nfcxx-modules.rb --facts=FILE [--cwd=DIR] ARGS..."
    return 64
  end
  begin
    lines = plan(args, load_facts(facts_path), cwd)
    puts lines
    0
  rescue Refused => e
    warn e.message
    puts "STATUS #{e.status}"
    e.status
  rescue Unported => e
    warn "unported: #{e.message}"
    3
  end
end

exit main(ARGV) if $PROGRAM_NAME == __FILE__
