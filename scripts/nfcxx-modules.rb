#!/usr/bin/env ruby
# Plan printer for nfcxx's C++ module build (docs/notes/modules.md): the modules block of nfcxx (the refusals, the
# module options of a compile) and mod_build_program (the order of the interface units, the nested compiles, the link).
# A program with no module source takes the plain path (one source, planned here too).
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
# module build, and TMP/p0.o the object of a plain Path B link.
#
# Exit status: 0 planned; 2 the bash refuses (its message on stderr, STATUS 2 on stdout); 3 not covered (unported, the
# reason on stderr). Not covered: several plain sources or objects on the command line, C sources, --emit-c on the plain
# path, options outside the list below (-E, -M, -shared, --cosmo, --target, --freestanding, -fsanitize, -m*, ...), CUDA
# and cpp2 inputs. The port assumes every step succeeds: Path B's fallback to gcc on a failing file (the default backend)
# is not modelled, and neither is the QBE check. The environment has no NFCXX_* variables and build/qbe/qbe exists
# (run.sh's sandbox); the default backend is Path B for every module or plain build the port plans (the options that
# choose gcc or another driver are refused or not covered).
#
# FACTS (--facts=FILE): one line per source argument, tab-separated:
#   SRC PATH MODULE(0|1) DECL(- if none) IMPORTS(- or a comma list) RC MESSAGE(- if none)
# What the bash reads from the source: mod_is_module_src, mod_decl_name, mod_imports and mod_check_src (RC and MESSAGE
# are its exit status and output). Other lines are ignored. tests/nfcxx-modules/run.sh writes the file by running those
# functions from nfcxx.
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

Fact = Struct.new(:modsrc, :decl, :imports, :rc, :msg)

# nfcxx's module check: C++ modules need C++20 or later (--c++NN is the name nfcxx gives the standard)
OLD_STANDARDS = %w[--c++98 --c++03 --c++11 --c++14 --c++17].freeze
# options that do not change the plan's words (checked by run.sh): they reach the compile and the link, and the port does not
# print them. -fPIC and -fPIE go to eccp's C compile options or to pathb-cc --pic; -rdynamic and -pie to the link options.
PLAIN_FLAG = /\A(-O[0-3sg]?|-g|-Wall|-Wextra|-pthread|-D.+|-I.+|-l.+|-L.+|-Wl,.+|-fPIC|-fpic|-fPIE|-fpie|-pie|-rdynamic|-pipe|-fexceptions|-fwrapv|-fno-strict-aliasing|-W\S*|-w|-fvisibility=\S+|-fvisibility-inlines-hidden)\z/

def load_facts(path)
  facts = {}
  File.foreach(path) do |line|
    f = line.chomp.split("\t", -1)
    next unless f[0] == "SRC"
    facts[f[1]] = Fact.new(f[2] == "1", f[3] == "-" ? nil : f[3], f[4] == "-" ? [] : f[4].split(","),
                           Integer(f[5], 10), f[6] == "-" ? nil : f[6])
  end
  facts
end

# the command line, as the bash's parser reads it (the cases it does not model raise Unported)
def parse(args)
  opt = { std: "--c++23", out: "a.out", outset: false, compile: false, emit_c: false, moddir: nil,
          backend: nil, srcs: [], cfiles: [], objs: [] }
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

# the tool of a compile or a link: eccp for the gcc backend; Path B (pathb-cc, then cc) for the default and --backend=pathb
def tool(opt)
  opt[:backend] == "gcc" ? "ECCP" : "PATHB"
end

# the output of a compile with -c: the -o file; without one, gcc's compile names it a.out and Path B's names it
# after the source (basename.o, in the directory of the command)
def compile_out(opt, src)
  return opt[:out] if opt[:outset] || opt[:backend] == "gcc"
  File.basename(src).sub(/\.[^.]*\z/, "") + ".o"
end

# the link of the objects: eccp takes them before -o; Path B's cc takes -o first, then the objects
def link_line(opt, objs, cwd)
  return ["ECCP", *objs, "-o", abs(opt[:out], cwd)] if opt[:backend] == "gcc"
  ["CC", "-o", abs(opt[:out], cwd), *objs]
end

# a program with no module source: the unchanged path, one source. eccp for the gcc backend; Path B compiles the
# source to TMP/p0.o and cc links it (the program's link is the same as a module build's)
def plain_plan(opt, cwd)
  raise Unported, "no source" if opt[:srcs].empty?
  raise Unported, "more than one source with no module source is not ported" unless opt[:srcs].size == 1
  raise Unported, "C sources with a C++ source are not ported" unless opt[:cfiles].empty?
  raise Unported, "objects with a source and no module are not ported" unless opt[:objs].empty?
  raise Unported, "--emit-c is not ported" if opt[:emit_c]
  src = opt[:srcs][0]
  lines = if opt[:compile]
            [[tool(opt), abs(src, cwd), "-o", abs(compile_out(opt, src), cwd)]]
          elsif opt[:backend] == "gcc"
            [["ECCP", abs(src, cwd), "-o", abs(opt[:out], cwd)]]
          else
            [["PATHB", abs(src, cwd), "-o", "TMP/p0.o"], link_line(opt, ["TMP/p0.o"], cwd)]
          end
  lines.map { |l| l.join(" ") } + ["STATUS 0"]
end

def plan(args, facts, cwd)
  opt = parse(args)
  opt[:srcs].each { |s| raise Unported, "no fact for #{s}" unless facts[s] }
  return plain_plan(opt, cwd) unless opt[:srcs].any? { |s| facts[s].modsrc }

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

  lines = []
  if opt[:compile]
    raise Refused.new(2, "nfcxx: -c with C++ modules takes one source") unless opt[:srcs].size == 1
    dir = abs(opt[:moddir] || File.dirname(opt[:out]), cwd)
    words = module_words(dir, decl_of(facts, opt[:srcs][0]), abs(opt[:srcs][0], cwd))
    lines << [tool(opt), *words, "-o", abs(compile_out(opt, opt[:srcs][0]), cwd)]
  else
    order = build_order(opt[:srcs], facts)
    # mod_build_program: each compile is this driver again (-c, the interface directory, the other options)
    nested_dir = opt[:moddir] ? abs(opt[:moddir], cwd) : "TMP"
    order.each_with_index do |s, n|
      # a nested compile of a source with no module statement is the unchanged path: no module words
      words = if facts[s].modsrc
                module_words(nested_dir, decl_of(facts, s), abs(s, cwd))
              else
                [abs(s, cwd)]
              end
      lines << [tool(opt), *words, "-o", "TMP/m#{n}.o"]
    end
    objs = (0...order.size).map { |n| "TMP/m#{n}.o" }
    lines << link_line(opt, objs, cwd)
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
