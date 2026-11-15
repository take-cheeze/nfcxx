#!/usr/bin/env ruby
# Print the function bodies of C or C++ files as clang-shaped JSON (be/nfcxx_ast.c, docs/notes/nfcxx-ast.md): the
# nfcxx front end's replacement for `clang -fsyntax-only -Xclang -ast-dump=json` where bc2cpp reads it (one JSON document
# per file, on stdout; the front end's diagnostics on stderr, a non-zero status when it rejects the file).
# Takes clang's spelling of the options: -x c|c++, -std=gnuNN|cNN|gnu++NN|c++NN, -I, -isystem, -D, -U, -include; other
# options (-W*, -f*, -O*, -m*, -MD, -MF f ...) are ignored. A .c file is C unless -x c++ says otherwise.
# The front end is build/libclang-edg/cmake/bin/cpfe (scripts/setup-libclang-edg.sh; LIBCLANG_EDG_IN_PROCESS=0 is
# enough), run from its base dir with the host's library headers and GNU version (scripts/host-sys.rb), in EDG's gcc / g++
# dialect: like clang's gnuNN modes, the C library's default feature macros stay on (unlike scripts/libclang-cursors.rb,
# which defines _POSIX_SOURCE for the declaration listing). The bash original is tests/launch/oracle/nfcxx-ast-dump.sh.
require "fileutils"
require_relative "launch"

NAME = "nfcxx-ast-dump"
ROOT = Launch.root_of(__FILE__)

def parse(argv)
  o = { opts: [], lang: "", files: [], std: "", depfile: nil }
  rest = argv.dup
  until rest.empty?
    a = rest.shift
    case a
    when "-x" then o[:lang] = Launch.value!(rest, a, NAME)
    when /\A-x./ then o[:lang] = a[2..]
    when /\A-std=/ then o[:std] = a.delete_prefix("-std=")
    when "-I", "-isystem" then o[:opts] << "-I#{HostSys.abs_path(Launch.value!(rest, a, NAME))}"
    when /\A-I./ then o[:opts] << "-I#{HostSys.abs_path(a[2..])}"
    when /\A-isystem./ then o[:opts] << "-I#{HostSys.abs_path(a[8..])}"
    when "-D", "-U" then o[:opts] << (a + Launch.value!(rest, a, NAME))
    when /\A-[DU]./ then o[:opts] << a
    when "-include" then o[:opts].push("--preinclude", HostSys.abs_path(Launch.value!(rest, a, NAME)))
    when "-MF" then o[:depfile] = Launch.value!(rest, a, NAME)
    when "-MT", "-MQ", "-o"
      # the bash loop's second shift fails with no argument left, and set -e ends the script (silently, status 1)
      exit 1 if rest.shift.nil?
    when /\A-/ then nil
    else o[:files] << a
    end
  end
  o
end

# the front end's mode for a C file, and the -tused flag it takes only for C++
def c_mode(std)
  m = case std
      when "c89", "c90", "gnu89", "gnu90" then ["--c89", "--gcc"]
      when "c99", "gnu99" then ["--c99", "--gcc"]
      when "c17", "c18", "gnu17", "gnu18" then ["--c17", "--gcc"]
      when "c23", "gnu23", "c2x", "gnu2x" then ["--c23", "--gcc"]
      else ["--c11", "--gcc"]
      end
  # EDG's --cNN defines __STRICT_ANSI__ (clang's cNN does too); clang's gnuNN does not, and glibc then keeps pread etc.
  m += ["-U__STRICT_ANSI__"] unless std.match?(/\Ac[0-9]/)
  [m, []]
end

def cxx_mode(std)
  m = if std.match?(/\A(c\+\+|gnu\+\+)/)
        ["--c++#{std.sub(/\A.*?\+\+/m, "")}", "--g++"]
      else
        ["--c++17", "--g++"]
      end
  [m, ["-tused"]]
end

# a make rule for the -M output: one `stem.o: /path ...` line, the absolute headers with their spaces escaped
def make_rule(stem, deps)
  paths = deps.each_line.filter_map { |l| l.chomp[%r{\A[^ ]+\.o: (/.*)\z}, 1] }
  "#{stem}.o:" + paths.map { |d| " #{d.gsub(" ") { "\\ " }}" }.join + "\n"
end

def main
  cpfe = Launch.env_or("LIBCLANG_EDG_CPFE", File.join(ROOT, "build/libclang-edg/cmake/bin/cpfe"))
  base = Launch.env_or("LIBCLANG_EDG_BASE", File.join(ROOT, "build/libclang-edg/edg-base"))
  unless File.executable?(cpfe)
    warn "#{NAME}: front end not built; run scripts/setup-libclang-edg.sh"
    exit 2
  end

  o = parse(ARGV)
  if o[:files].empty?
    warn "#{NAME}: no input file"
    exit 2
  end

  status = 0
  o[:files].each do |file|
    lang = o[:lang]
    lang = file.end_with?(".c") ? "c" : "c++" if lang.empty?
    mode, tused = lang == "c" ? c_mode(o[:std]) : cxx_mode(o[:std])
    sys_inc = HostSys.sys_includes(lang).reject(&:empty?).map { |d| "--sys_include=#{d}" }
    gnu = HostSys.gnu_version
    gnu_opts = gnu ? ["--gnu_version=#{gnu}"] : []
    f = Launch.realpath!(file)
    stem = File.basename(f).sub(/\.[^.]*\z/, "")
    ti = File.join(base, "#{stem}.ti")
    had_ti = File.exist?(ti)

    code = Launch.run(
      [cpfe, "-D__CHAR_BIT__=8", *mode, "--wdir", "/", *gnu_opts, *tused, *o[:opts], *sys_inc,
       "--sys_include=#{base}/include", f],
      env: { "NFCXX_DECL_AST" => "1" }, dir: base
    )
    status = code unless code.zero?
    FileUtils.rm_f(ti) unless had_ti

    next unless o[:depfile]

    # -M prints one `target.o: /path` line per header; the diagnostics are discarded
    deps, code = Launch.capture(
      [cpfe, "-D__CHAR_BIT__=8", *mode, "--wdir", "/", *gnu_opts, *o[:opts], *sys_inc,
       "--sys_include=#{base}/include", "-M", f],
      dir: base
    )
    status = code unless code.zero?
    File.write(o[:depfile], make_rule(stem, deps))
  end
  exit status
end

main
