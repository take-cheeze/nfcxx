#!/usr/bin/env ruby
# The C compiler of the gcc backend, as eccp runs it on EDG's generated C (EDG_C_TO_OBJ_COMPILER). It is gcc, with
# filters on a `-c file.c` compile of EDG's output (other arguments and files are unchanged):
#
# 1. A `#pragma GCC unroll N` line is removed. EDG passes the pragma through from libstdc++ 15's __find_if
#    (bits/stl_algobase.h), and gcc rejects it when a declaration follows it ("for, while or do statement expected
#    before 'auto'"). The pragma is only a loop hint.
#
# 2. EDG emits a class's complete-object destructor (the D1 of the Itanium ABI, when it is an alias of the D2 body)
#    as `extern __inline__`. Under gnu89 inline rules that is no external definition, so a static object whose data
#    refers to D1 (std::filesystem's directory_iterator holds a shared_ptr<_Dir>) does not link. D2 is written
#    without `extern`, weak, as EDG marks COMDAT members; the D1 wrapper is made the same, so both are emitted and
#    the copies of several units merge.
#
# 3. Weak symbols. EDG marks its COMDAT functions and data __attribute__((__weak__)) and GCC honours that, but a
#    non-extern `__inline__` member is an external definition under gnu89, so each object carries a strong copy
#    and the link fails with "multiple definition". The QBE path appends .weak directives for them
#    (scripts/weak-symbols, which also covers `extern __inline__` members). Here the compile stops at the
#    assembly, the directives are appended, and the assembly is assembled to the object.
#
# This is scripts/gcc-cc (bash) ported to Ruby: the same filters, the same order and the same commands; the sed and
# perl filters are done in Ruby, and the sret thunks' rename (scripts/sret.sh) is still applied by sed -E.
require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", File.expand_path(File.dirname($0)))
CC = ENV["NFCXX_GCC"].to_s.empty? ? "cc" : ENV["NFCXX_GCC"]

# A command run as the bash runs it under set -e: a failure ends the script with its status.
def run!(*cmd)
  return if system(*cmd)

  exit($?.exitstatus || 127)
end

# `command -v NAME` for a program on PATH
def on_path?(name)
  ENV.fetch("PATH", "").split(":").any? do |d|
    f = File.join(d, name)
    File.file?(f) && File.executable?(f)
  end
end

def uname_s
  IO.popen(["uname", "-s"], &:read).sub(/\n+\z/, "")
end

# sret.sh's output: the object's path, or "" when the host needs no thunks (or the script fails)
def sret_file
  out, _err, st = Open3.capture3(File.join(ROOT, "scripts", "sret.sh"))
  st.success? ? out.sub(/\n+\z/, "") : ""
end

host = uname_s
tls_darwin = host == "Darwin"
sret = sret_file
sret_on = !sret.empty?
sret_sed = File.join(ROOT, "build", "sret", "rename.sed")
clang = begin
  out, = Open3.capture2(CC, "--version", err: File::NULL)
  out.match?(/clang/i)
rescue SystemCallError
  false
end
ccbin = on_path?("ccache") && ENV["NFCXX_CCACHE"] != "0" ? ["ccache", CC] : [CC]

tmp = Dir.mktmpdir("gcc-cc")
at_exit { FileUtils.rm_rf(tmp) }

argv = ARGV.dup
args = []
n = 0
csrc = ""
compile = false
argv.each do |a|
  case a
  when "-c"
    compile = true
    args << a
  when /\.c\z/
    csrc = a
    src = File.file?(a) ? File.binread(a) : nil
    filter = src && (sret_on ||
      src.match?(/^[[:space:]]*#pragma GCC unroll/) ||
      (clang && src.include?("static void __tls_init(void)")) ||
      src.match?(/^extern __inline__ __attribute__\(\(visibility\("default"\)\)\) void _ZN.*D1Ev\(/))
    if filter
      n += 1
      f = File.join(tmp, "src#{n}.c")
      lines = src.lines.reject { |l| l.match?(/\A[[:space:]]*#pragma GCC unroll/) }.map do |l|
        l = l.sub("static void __tls_init(void)", "__attribute__((used)) static void __tls_init(void)")
        next l unless tls_darwin

        l.sub(/__asm__\("(_ZTH[^ ]*) = __tls_init"\)/) { %(__asm__("_#{$1} = ___tls_init")) }
      end.join
      # the sret thunks' rename (rename.sed, extended regular expressions), as the sed -E -f of the bash
      lines, = Open3.capture2("sed", "-E", "-f", sret_sed, stdin_data: lines, binmode: true) if sret_on
      # EDG's extern inline complete-object destructors become weak definitions (filter 2)
      lines = lines.lines.map do |l|
        l.sub(/\Aextern __inline__ __attribute__\(\(visibility\("default"\)\)\) void (_ZN.*D1Ev)\(/) do
          "__attribute__((__weak__)) __inline__ __attribute__((visibility(\"default\"))) void #{$1}("
        end
      end.join
      File.binwrite(f, lines)
      args << f
      csrc = f
    else
      args << a
    end
  else
    args << a
  end
end

# 5. EDG writes a file-scope `static __thread` object as a tentative definition, then again with its initializer. GCC 15
#    (its default C23 mode) rejects that redefinition; gnu17, which the C of EDG's output is written for, takes it. The
#    standard is set here unless the caller gave one.
if compile
  args = ["-std=gnu17", *args] unless args.any? { |x| x.start_with?("-std=") }
end

# The output of a `-c ... -o FILE` compile is FILE; without -o, gcc writes the basename.o.
obj = ""
prev = nil
argv.each do |a|
  obj = a if prev == "-o"
  prev = a
end

if compile && !csrc.empty? && File.file?(csrc) && !obj.empty?
  asmf = File.join(tmp, "out.s")
  gsrc = csrc
  # 6. gcc never inlines a function declared weak (another unit's copy could replace it at link time), and EDG marks
  #    every COMDAT function weak. gcc compiles a copy of the C without the COMDAT groups' __weak__ on function
  #    definitions (the object's symbols stay as weak as before, see weak-symbols). NFCXX_WEAK_INLINE=0 compiles the C
  #    as EDG wrote it. Only Linux: on Mach-O the weak attribute is what ld64 coalesces by.
  if ENV["NFCXX_WEAK_INLINE"] != "0" && host == "Linux" && File.binread(csrc).include?("__weak__)) /* COMDAT group:")
    gsrc = File.join(tmp, "inline.c")
    text = File.binread(csrc).gsub(%r{__attribute__\(\(__weak__\)\) /\* COMDAT group: (\w+) \*/([^;{}]*?)(?<!\w)\1\(}) do
      "/* COMDAT group: #{$1} */#{$2}#{$1}("
    end
    File.binwrite(gsrc, text)
  end
  build = []
  skip = false
  args.each do |a|
    if skip
      skip = false
      next
    end
    case a
    when "-c" then build << "-S"
    when "-o"
      build += ["-o", asmf]
      skip = true
    else
      build << (a == csrc ? gsrc : a)
    end
  end
  run!(*ccbin, *build)
  run!(File.join(ROOT, "scripts", "weak-symbols"), csrc, asmf)
  exec(ENV["NFCXX_AS"] || "as", "-o", obj, asmf)
end
exec(*ccbin, *args)
