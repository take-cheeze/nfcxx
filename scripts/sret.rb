#!/usr/bin/env ruby
# Print the path of the object that bridges the indirect-result convention for the exported library functions that return a
# class by value (scripts/sret-darwin-symbols.txt for libc++ on macOS, scripts/sret-linux-symbols.txt for libstdc++ on Linux
# aarch64). On AArch64 such a result goes through x8, but EDG's C prototype for the function passes the result pointer as the
# first argument (x0). A thunk per function moves x0 to x8, shifts the integer arguments down one register and branches to the
# real function. The C compilers rename the calls to the thunks (rename.sed next to the object), so the rename and the object
# always come from this script. Prints nothing elsewhere (x86-64 and other hosts pass the result pointer in the first argument).
# Cross mode (NFCXX_MACOS_SYSROOT set, a Linux host building for macOS arm64): the Mach-O thunks are built with llvm-mc in
# build/sret-cross. The export check needs the SDK, which the cross host does not have, so the names are taken from the list
# and the Mac's linker resolves them: a name the library does not export is an undefined symbol on the Mac, not a silent call.
# Limit: a function with more than seven integer arguments would also need its stack arguments moved; none of the listed
# functions has one.
require "fileutils"

# A command's standard output without its trailing newlines (bash's $(...)); a failing command ends the script.
def capture!(*cmd)
  out = IO.popen(cmd, &:read).sub(/\n+\z/, "")
  exit($?.exitstatus || 1) unless $?.success?
  out
end

# Runs a command; a failure ends the script with its status (bash's set -e).
def run!(*cmd)
  return if system(*cmd)
  exit($?.exitstatus || 1)
end

# bash's `[ a -nt b ]`: a exists and is newer than b, or b does not exist.
def newer?(a, b)
  File.exist?(a) && (!File.exist?(b) || File.mtime(a) > File.mtime(b))
end

def uname(flag)
  IO.popen(["uname", flag], &:read).sub(/\n+\z/, "")
end

root = File.expand_path("..", File.expand_path(File.dirname($0)))
cross = false
if ENV["NFCXX_MACOS_SYSROOT"] && !ENV["NFCXX_MACOS_SYSROOT"].empty?
  cross = true
  list = "#{root}/scripts/sret-darwin-symbols.txt"
  prefix = "_"
else
  host = "#{uname("-s")}-#{uname("-m")}"
  if host.start_with?("Darwin-")
    list = "#{root}/scripts/sret-darwin-symbols.txt"
    prefix = "_"
  elsif host == "Linux-aarch64"
    list = "#{root}/scripts/sret-linux-symbols.txt"
    prefix = ""
  else
    exit 0
  end
end
dir = cross ? "#{root}/build/sret-cross" : "#{root}/build/sret"
out = cross ? "#{dir}/sret-macos.a" : "#{dir}/sret.o"
if !File.file?(out) || newer?(list, out) || newer?($0, out)
  FileUtils.mkdir_p(dir)
  tmp = IO.popen(["mktemp", "-d", "#{dir}/.build.XXXXXX"], &:read).sub(/\n+\z/, "")
  exit($?.exitstatus || 1) unless $?.success?
  at_exit { FileUtils.rm_rf(tmp) }
  # the names: the list's lines without the comments, split into words
  names = File.read(list).each_line.reject { |l| l.start_with?("#") }.join(" ").split
  if cross
    check = ->(_n) { true }
  elsif prefix == "_"
    # the export table: the symbol must be exported by the library, or the thunk would branch to nothing
    exports = "#{capture!("xcrun", "--sdk", "macosx", "--show-sdk-path")}/usr/lib/libc++.1.tbd"
    table = File.file?(exports) ? File.read(exports) : ""
    check = ->(n) { table.include?("_#{n}") }
  else
    pf = capture!("cc", "-print-file-name=libstdc++.so.6")
    lib = capture!("realpath", pf)
    exports = "#{tmp}/exports.txt"
    nm_out = capture!("nm", "-D", "--defined-only", lib)
    awk_out = IO.popen(["awk", '{split($3, a, "@"); print a[1]}'], "r+") do |io|
      io.write(nm_out)
      io.close_write
      io.read
    end
    File.write(exports, awk_out)
    table = awk_out.lines.map(&:chomp)
    check = ->(n) { table.include?(n) }
  end
  thunks = +""
  rename = +""
  thunks << "\t.section .note.GNU-stack,\"\",%progbits\n" if prefix.empty?
  thunks << "\t.text\n"
  names.each do |n|
    unless check.(n)
      warn "sret: #{n} is not exported by its library (#{exports})"
      exit 1
    end
    thunk = "__nfcxx_sret_#{n}"
    one = "#{tmp}/one.#{thunk}.s"
    body = +"\t.text\n"
    body << "\t.globl\t#{prefix}#{thunk}\n"
    body << "\t.type\t#{prefix}#{thunk},%function\n" if prefix.empty?
    body << "\t.p2align\t2\n"
    body << "#{prefix}#{thunk}:\n"
    body << "\tmov\tx8, x0\n\tmov\tx0, x1\n\tmov\tx1, x2\n\tmov\tx2, x3\n\tmov\tx3, x4\n\tmov\tx4, x5\n\tmov\tx5, x6\n\tmov\tx6, x7\n"
    body << "\tb\t#{prefix}#{n}\n"
    File.write(one, body)
    thunks << body
    if cross
      run!("llvm-mc", "-triple=arm64-apple-darwin", "-filetype=obj", "-o", "#{tmp}/#{thunk}.o", one)
      run!("llvm-ar", "rcs", "#{tmp}/sret.a", "#{tmp}/#{thunk}.o")
    end
    # extended regular expressions (sed -E, both GNU and BSD): the identifier after a non-identifier character or at a line start
    # (only the leading character is matched, so neighbouring occurrences do not overlap)
    rename << "s/(^|[^A-Za-z0-9_])#{n}/\\1#{thunk}/g\n"
  end
  File.write("#{tmp}/thunks.s", thunks)
  File.write("#{tmp}/rename.sed", rename)
  if cross
    # an archive: the linker pulls only the thunks the program calls (the others name library functions the stub need not list)
    File.write("#{tmp}/sret.a.check", "")
    run!("llvm-ar", "rcs", "#{tmp}/sret.a") unless File.file?("#{tmp}/sret.a")
    File.rename("#{tmp}/rename.sed", "#{dir}/rename.sed")
    File.rename("#{tmp}/sret.a", out)
  else
    run!("cc", "-c", "-o", "#{tmp}/sret.o", "#{tmp}/thunks.s")
    File.rename("#{tmp}/rename.sed", "#{dir}/rename.sed")
    File.rename("#{tmp}/sret.o", out)
  end
end
puts out
