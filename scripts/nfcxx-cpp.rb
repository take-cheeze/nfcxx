#!/usr/bin/env ruby
# nfcxx-cpp: preprocess a C or C++ source with the EDG front end (cpfe -E), the host's system headers and GNU version, as
# nfcxx's compile does. A stand-in for `clang -E -P`:
#   nfcxx-cpp [-x c|c++] [-std=...] [-P] [-I DIR] [-D MACRO] ... FILE
# -P drops the `# LINE "file"` markers (clang -P). -std is ignored for C (EDG's GNU C mode); for C++ it selects --c++NN.
# Needs scripts/setup-edg.sh (build/edg/bin/cpfe, build/edg-base). Exit status 2 when EDG is not built.
# (`nfcxx -E` itself hands the preprocessing to the host g++, as nfcc does; this is the EDG preprocessor.)
# The host probes are scripts/host-sys.rb. The bash original is tests/launch/oracle/nfcxx-cpp.sh.
require_relative "launch"

NAME = "nfcxx-cpp"
ROOT = Launch.root_of(__FILE__)

# the options as the bash loop reads them
def parse(argv)
  o = { lang: "", std: "", strip: false, args: [], files: [] }
  rest = argv.dup
  until rest.empty?
    a = rest.shift
    case a
    when "-x" then o[:lang] = Launch.value!(rest, a, NAME)
    when /\A-x./ then o[:lang] = a[2..]
    when /\A-std=/ then o[:std] = a.delete_prefix("-std=")
    when "-P" then o[:strip] = true
    when "-E" then nil
    when "-I", "-D", "-U", "-include" then o[:args].push(a, Launch.value!(rest, a, NAME))
    when /\A-/ then o[:args] << a
    else o[:files] << a
    end
  end
  o
end

def main
  cpfe = Launch.env_or("CPFE", File.join(ROOT, "build/edg/bin/cpfe"))
  unless File.executable?(cpfe)
    warn "#{NAME}: EDG not built (#{cpfe}); run scripts/setup-edg.sh"
    exit 2
  end
  ENV["EDG_BASE"] = Launch.env_or("EDG_BASE", File.join(ROOT, "build/edg-base"))

  o = parse(ARGV)
  lang = o[:lang]
  if lang.empty?
    lang = o[:files][0].to_s.end_with?(".c") ? "c" : "c++"
  end
  sys = HostSys.sys_includes(lang).map { |d| "--sys_include=#{d}" }
  gnu = HostSys.gnu_version
  gopt = gnu ? ["--gnu_version=#{gnu}"] : []
  lopt = []
  dial = "--gcc"
  if lang == "c"
    lopt = ["--c99"]
  else
    dial = "--g++"
    n = o[:std].sub(/\A.*?\+\+/m, "")
    lopt = ["--c++#{n}"] if %w[98 03 11 14 17 20 23].include?(n)
  end

  argv = [cpfe, dial, *gopt, *lopt, "-E", *sys, *o[:args], *o[:files]]
  unless o[:strip]
    exec(*argv)
  end

  # -P: the markers go; the pipeline's status is cpfe's (pipefail; grep always succeeds)
  out = IO.popen(argv, "rb", &:read)
  st = $?
  out.each_line do |l|
    next if l.match?(/\A# [0-9]/)

    $stdout.write(l.end_with?("\n") ? l : "#{l}\n")
  end
  exit(st.success? ? 0 : Launch.status_of(st))
end

main
