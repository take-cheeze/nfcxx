#!/usr/bin/env ruby
# Build the small standalone `mruby` interpreter that runs nfcxx's own scripts (see scripts/mrb and
# docs/notes/mruby-scripting.md) into build/mruby-tool/bin/mruby. Does nothing if it is already built.
# No rake: scripts/mruby-ninja.rb reads mruby's build config and gems and writes a ninja build file, and ninja builds it.
#   MRUBY_CC=<cc>   Build a second interpreter, bin/mruby-nfcc, with this C compiler and linker instead of
#                   the host cc (MRUBY_CC=$PWD/nfcc dogfoods the compiler, as tests/realworld/run_mruby.sh
#                   does; NFCXX_BACKEND picks its back end). The host-cc bin/mruby is always built first:
#                   scripts/qbe-cc runs mruby, so an nfcc build needs one to exist.
#                   Run scripts with it via MRB=build/mruby-tool/bin/mruby-nfcc scripts/mrb ...
#   FORCE=1         rebuild even if bin/mruby exists
# Needs ruby (CRuby, stdlib only), ninja, git, flock, and the host tools of the vendored gems: a C compiler, make,
# ar, gzip and tar (docs/notes/mruby-scripting.md). The 3rd/ gems are submodules: `git submodule update --init`.
# Ruby port of setup-mruby.sh: the external commands, their order and arguments are the same.
require 'open3'
require 'rbconfig'

# A command on PATH (command -v), or nil.
def which(cmd)
  return (File.file?(cmd) && File.executable?(cmd) ? cmd : nil) if cmd.include?('/')
  ENV.fetch('PATH', '').split(':', -1).each do |d|
    f = File.join(d.empty? ? '.' : d, cmd)
    return f if File.file?(f) && File.executable?(f)
  end
  nil
end

# Runs an external command and returns its exit status (127 when it cannot start, as the shell does).
def run(argv, env: {}, chdir: nil, out: nil, err: nil)
  opts = {}
  opts[:chdir] = chdir if chdir
  opts[:out] = out if out
  opts[:err] = err if err
  pid = Process.spawn(env, *argv, **opts)
  Process.wait(pid)
  $?.exitstatus || 1
rescue SystemCallError
  127
end

# $(...) of a command: its standard output without trailing newlines, and its status.
def capture(argv, err: File::NULL)
  out, st = Open3.capture2(*argv, err: err)
  [out.sub(/\n+\z/, ''), st.exitstatus || 1]
rescue SystemCallError
  ['', 127]
end

Dir.chdir(File.join(File.dirname(File.expand_path($PROGRAM_NAME)), '..'))
root = Dir.pwd
work = File.join(root, 'build/mruby-tool')
pin = '831da26b9021de0369d17b71b5667e2941a1a32d'   # mruby/mruby tag 4.0.0, same pin as tests/realworld/run_mruby.sh
src = File.join(work, 'src')
mruby_cc = ENV['MRUBY_CC']

if !mruby_cc.nil? && !mruby_cc.empty? && mruby_cc != 'cc'
  # the host interpreter first (no-op when present); unset, not empty: the gems' ENV.fetch('MRUBY_CC', 'cc') would take "" as the compiler
  exit 1 unless run([RbConfig.ruby, $PROGRAM_NAME], env: { 'MRUBY_CC' => nil }) == 0
  cc = mruby_cc
  tag = '-nfcc'
else
  cc = 'cc'
  tag = ''
end
exe = "#{work}/bin/mruby#{tag}"
exit 0 if ENV['FORCE'].to_s.empty? && File.executable?(exe)
unless which('ruby')
  $stderr.puts 'setup-mruby: ruby (CRuby) is needed to generate the build file'
  exit 1
end
unless which('ninja')
  $stderr.puts 'setup-mruby: ninja is needed (apt-get install ninja-build)'
  exit 1
end
%w[3rd/mruby-onig-regexp/mrbgem.rake 3rd/mruby-json/mrbgem.rake].each do |f|
  next if File.file?(f)
  $stderr.puts "setup-mruby: #{f} is missing (git submodule update --init 3rd/mruby-onig-regexp 3rd/mruby-json)"
  exit 1
end
# The gems under 3rd/ build Onigmo with the host's `make`, `ar`, `gzip` and `tar` (mrbgem.rake of mruby-onig-regexp;
# its configure script ships in the tarball, so only `sh` is needed to run it). Fail here, not 10 minutes into the build.
missing = []
[cc, 'make', 'ar', 'gzip', 'tar'].each do |t|
  next if which(t)
  p = case t
      when 'make' then 'make'
      when 'ar' then 'binutils'
      when 'gzip', 'tar' then t
      else 'build-essential (or gcc)'
      end
  missing << "#{t} (apt-get install #{p})"
end
unless missing.empty?
  $stderr.puts "setup-mruby: host tool(s) missing: #{missing.join('; ')}"
  exit 1
end
run(['mkdir', '-p', work])
# One build at a time (parallel compiles can all find the interpreter missing); re-check once locked.
lock = File.open("#{work}/.lock", 'w')
lock.flock(File::LOCK_EX) if which('flock')
exit 0 if ENV['FORCE'].to_s.empty? && File.executable?(exe)
unless File.directory?("#{src}/.git")
  ok = run(['mkdir', '-p', src]) == 0 &&
       run(['git', '-C', src, 'init', '-q']) == 0 &&
       run(['git', '-C', src, 'remote', 'add', 'origin', 'https://github.com/mruby/mruby']) == 0
  exit 1 unless ok
end
out_rev, = capture(['git', '-C', src, 'rev-parse', '-q', '--verify', "#{pin}^{commit}"])
if out_rev != pin
  unless run(['git', '-C', src, 'fetch', '-q', '--depth', '1', 'origin', pin]) == 0
    $stderr.puts "setup-mruby: fetching mruby #{pin} failed"
    exit 1
  end
end
exit 1 unless run(['git', '-C', src, 'checkout', '-q', pin]) == 0

# First step: the ninja build file for mruby, from the config and the gems' own mrbgem.rake files. Then ninja builds it.
out = "#{work}/out#{tag}"
log = "#{work}/build#{tag}.log"
built = run(['ruby', 'scripts/mruby-ninja.rb', 'generate', src, 'scripts/mruby-tool-config.rb', out],
            env: { 'MRUBY_CC' => cc, 'NFCXX_ROOT' => root }, out: [log, 'w'], err: [:child, :out])
built = run(['ninja', '-C', out, "#{out}/host/bin/mruby"], out: [log, 'a'], err: [:child, :out]) if built == 0
unless built == 0
  run(['tail', '-20', log], out: $stderr)
  $stderr.puts "setup-mruby: build failed (full log: #{log})"
  exit 1
end
run(['mkdir', '-p', "#{work}/bin"])
run(['mv', "#{exe}.new", exe]) if run(['cp', "#{out}/host/bin/mruby", "#{exe}.new"]) == 0
$stderr.puts "setup-mruby: built #{exe} (cc=#{cc}, ninja)"
