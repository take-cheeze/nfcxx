#!/usr/bin/env ruby
# Generate the C that the EDG front end emits for a chosen (non-host) target configuration,
# without compiling it. The target picks the predefined-macro table (build/edg-base/lib_<target>)
# and the sizes/alignments EDG uses for layout, so this is the C to hand to a cross compiler.
#
# Usage: scripts/gen-c-target.rb [-t TARGET] [-std=c++NN] [-o out.c] file.cpp
#   TARGET defaults to linux_riscv32 (ILP32, little-endian, the closest EDG config to Hexagon;
#   see docs/notes/hexagon.md). Other choices: linux_i686 (32-bit x86, not ABI-exact, see notes),
#   linux_armv7, win32. Without -o the C goes to stdout.
# Needs build/edg (scripts/setup-edg.sh). cpfe runs from the base dir, as the nfcxx driver does.
require "fileutils"
require "tmpdir"
$stdout.sync = true
$stderr.sync = true

def errno_text(err)
  SystemCallError.new(nil, err.errno).message
end

# realpath FILE (GNU, default mode): the last component need not exist, the others must
def gnu_realpath(path)
  return File.realpath(path) if File.exist?(path)

  real_dir = File.realpath(File.dirname(path))
  raise Errno::ENOTDIR unless File.directory?(real_dir)

  "#{real_dir}/#{File.basename(path)}"
rescue SystemCallError => e
  warn "realpath: #{path}: #{errno_text(e)}"
  exit 1
end

root = File.expand_path("..", File.dirname($PROGRAM_NAME))
edg_build = ENV["EDG_BUILD"].to_s
edg = "#{edg_build.empty? ? "#{root}/build/edg" : edg_build}/bin"
edg_base = ENV["EDG_BASE"].to_s
base = edg_base.empty? ? "#{root}/build/edg-base" : edg_base

target = "linux_riscv32"
std = "--c++23"
out = ""
src = ""
args = ARGV.dup
until args.empty?
  a = args.shift
  if a == "-t" || a == "--target"
    # target=$2 with set -u: a missing value is the shell's "unbound variable" error (the script's line 19)
    unless (value = args.shift)
      warn "#{$PROGRAM_NAME}: line 19: $2: unbound variable"
      exit 1
    end
    target = value
  elsif a.start_with?("--target=")
    target = a.delete_prefix("--target=")
  elsif a.start_with?("-std=c++")
    std = "--c++#{a.delete_prefix("-std=c++")}"
  elsif a == "-o"
    # out=$2 (the script's line 22), with the same unbound-variable error as -t
    unless (value = args.shift)
      warn "#{$PROGRAM_NAME}: line 22: $2: unbound variable"
      exit 1
    end
    out = value
  elsif a.start_with?("-")
    warn "gen-c-target: unknown option #{a}"
    exit 2
  else
    src = a
  end
end

if src.empty?
  warn "usage: #{$PROGRAM_NAME} [-t TARGET] [-std=c++NN] [-o out.c] file.cpp"
  exit 2
end
cpfe = "#{edg}/cpfe"
unless File.executable?(cpfe)
  warn "gen-c-target: cpfe not built; run scripts/setup-edg.sh"
  exit 2
end
unless File.directory?("#{base}/lib_#{target}")
  warn "gen-c-target: no predefined macros for target '#{target}' in #{base}"
  exit 2
end

src = gnu_realpath(src)
# setup-edg.sh copies the base dir with a relative `include` symlink that dangles in build/edg-base;
# use the real EDG header directory in that case.
inc = "#{base}/include"
inc = "#{root}/3rd/edg/include_c++" unless File.exist?("#{inc}/exception.h")

Dir.mktmpdir("gen-c-target") do |tmp|
  # (cd "$base" && "$edg/cpfe" ...): run from the base dir; a failing cpfe ends the script with its status
  status = nil
  Dir.chdir(base) do
    system([cpfe, cpfe], "-D_POSIX_SOURCE", "-D__CHAR_BIT__=8", std, "--g++", "--target", target,
           "--sys_include=#{inc}", "-tused", "--gen_c_file_name=#{tmp}/out.c", src)
    status = $?.exitstatus || (128 + $?.termsig.to_i) unless $?.success?
  end
  exit status if status

  tmp_out = "#{tmp}/out.c"
  if !out.empty?
    # cp "$tmp/out.c" "$out": into a directory it copies to DIR/out.c
    unless File.exist?(tmp_out)
      warn "cp: cannot stat '#{tmp_out}': No such file or directory"
      exit 1
    end
    dest = File.directory?(out) ? "#{out}/out.c" : out
    begin
      FileUtils.cp(tmp_out, dest)
    rescue SystemCallError => e
      warn "cp: cannot create regular file '#{out}': #{errno_text(e)}"
      exit 1
    end
  else
    # cat "$tmp/out.c"
    begin
      $stdout.binmode
      $stdout.write(File.binread(tmp_out))
    rescue SystemCallError => e
      warn "cat: #{tmp_out}: #{errno_text(e)}"
      exit 1
    end
  end
end
