#!/usr/bin/env ruby
# The CIL route of nfcc (docs/notes/cil.md): a C or C++ file -> Path B (scripts/pathb-cil -c) -> a JSON fragment, which is the
# object; the link is scripts/cil-link.rb over the fragments (CIL, ilasm, a launcher for dotnet). The old per-file fallback
# through cproc is gone with cproc: a file Path B refuses is an error here. NFCXX_CIL_VERBOSE=1 says which file was refused, and why.
require "tempfile"

# A variable that is unset or empty is nil (bash's ${VAR:-default}).
def env(name)
  v = ENV[name]
  v.nil? || v.empty? ? nil : v
end

ENV["NFCXX_CIL"] = "1"
here = File.expand_path(File.dirname($0))
root = File.expand_path("..", here)
compile = false
out = ""
srcs = []
pass = []
frags = []
args = ARGV.dup
until args.empty?
  a = args.shift
  case a
  when "-c" then compile = true
  when "-o" then out = args.shift.to_s
  when /\A-[DIU]./m, /\A-std=/ then pass << a
  when "-D", "-I", "-U" then pass << "#{a}#{args.shift}"
  when "--c-input", "--eh-unwind" then nil
  when /\A-O/, /\A-g/, /\A-W/, "-w", "-fPIC", "-fpic", "-fno-PIC", "-fno-pic", "-fwrapv", "-fno-strict-aliasing",
       "-m64", "-pipe", "-fno-common", "-fno-builtin", "-fomit-frame-pointer" then nil
  when /\A-/
    warn "cil-cc: option '#{a}' is not supported by the CIL route"
    exit 2
  when /\.(c|cc|cpp|cxx)\z/ then srcs << a
  else
    # an object of the -c compile: the JSON fragment of one file (nfcc names it .o)
    first = begin
      File.file?(a) ? File.open(a, "rb") { |f| f.read(1) } : nil
    rescue SystemCallError
      nil
    end
    if first == "{"
      frags << a
    else
      warn "cil-cc: unsupported input '#{a}'"
      exit 2
    end
  end
end
out = "a.out" if out.empty?

if compile
  unless srcs.size == 1
    warn "cil-cc: -c takes one source file"
    exit 2
  end
  err = IO.popen(["mktemp"], &:read).sub(/\n+\z/, "")
  at_exit { File.delete(err) if File.exist?(err) }
  if system("#{here}/pathb-cil", "-c", *pass, "-o", out, srcs[0], err: [err, "w"])
    warn "cil-cc: Path B: #{srcs[0]}" if env("NFCXX_CIL_VERBOSE")
    exit 0
  end
  text = File.binread(err)
  # A defined variadic function (va_start) is out of scope of the CIL backend: the refusal is the answer (tests/cil/errors).
  summary = text.byteslice(0, 300).tr("\n", " ")
  # the captured text is bytes: written as bytes, not interpolated into a UTF-8 string
  if text.include?("variadic definitions (va_start) are not supported by the CIL backend")
    $stderr.write("cil-cc: Path B: #{srcs[0]}: ".b + summary + "\n".b)
  else
    $stderr.write("cil-cc: Path B refused #{srcs[0]}: ".b + summary + "\n".b)
  end
  File.delete(out) if File.exist?(out)
  exit 1
end

# The link: the fragments of the -c compiles (JSON) and nothing else. cil-link.rb needs no C compiler except for the variadic shim.
unless srcs.empty?
  warn "cil-cc: the link takes fragments, not sources"
  exit 2
end
if frags.empty?
  warn "cil-cc: nothing to link"
  exit 2
end
keep = env("NFCXX_KEEP_IL") ? ["--keep-il"] : []
ilasm = env("ILASM") || "#{root}/build/cil/ilasm"
cc = env("CC") || "cc"
begin
  Kernel.exec("#{root}/scripts/mrb", "#{root}/scripts/cil-link.rb", "--ilasm", ilasm, "--cc", cc,
              *keep, "-o", out, *frags)
rescue SystemCallError => e
  warn "cil-cc: #{e.message}"
  exit 127
end
