#!/usr/bin/env ruby
# Build the mruby that lib/poly (nfcpoly) embeds, with C++ exceptions, into build/poly/<backend>/:
#   lib/libmruby.a    the mruby VM, the compiler (scripts are parsed at run time) and the gems of scripts/mruby-rt-config.rb
#   include/          mruby.h, mruby/*.h and the generated headers; give the host program -I build/poly/<backend>/include
# C sources are compiled by nfcc and the files that mruby builds as C++ under MRB_USE_CXX_EXCEPTION (vm.c, error.c, gc.c
# and the compiler gem's parser and code generator) by nfcxx, so mruby's raise is a throw on EDG's exception runtime.
# See docs/notes/poly.md.
#   NFCXX_BACKEND=pathb|gcc   back end of both compilers (default pathb); one build tree per back end
#   FORCE=1                 rebuild even if the library is newer than the config and this script
# Needs ruby and the rake gem (the same bootstrap as scripts/setup-mruby.sh), EDG (scripts/setup-edg.sh) and, for the
# pathb back end, the Path B harness (scripts/setup-pathb.sh). The mruby source is fetched from GitHub at the pin below, unpatched.
# Ruby port of setup-poly.sh: the external commands, their order and arguments are the same.
require 'open3'

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

# test -nt: a is newer than b, or a exists and b does not
def newer?(a, b)
  return false unless File.exist?(a)
  return true unless File.exist?(b)
  File.mtime(a) > File.mtime(b)
end

# $(nproc 2>/dev/null || sysctl -n hw.ncpu)
def jobs
  out, st = capture(['nproc'])
  return out if st == 0
  capture(['sysctl', '-n', 'hw.ncpu'])[0]
end

self_path = File.realpath($PROGRAM_NAME)
Dir.chdir(File.join(File.dirname(File.expand_path($PROGRAM_NAME)), '..'))
root = Dir.pwd
work = File.join(root, 'build/poly')
be = ENV['NFCXX_BACKEND']
be = 'pathb' if be.nil? || be.empty?
unless %w[gcc pathb].include?(be)
  $stderr.puts "setup-poly: NFCXX_BACKEND must be pathb or gcc, not '#{be}'"
  exit 1
end
pin = '831da26b9021de0369d17b71b5667e2941a1a32d'   # mruby/mruby tag 4.0.0, same pin as scripts/setup-mruby.sh
src = "#{work}/src"
out = "#{work}/out-#{be}"
dest = "#{work}/#{be}"
fresh = lambda do
  File.file?("#{dest}/lib/libmruby.a") && newer?("#{dest}/lib/libmruby.a", 'scripts/mruby-rt-config.rb') &&
    newer?("#{dest}/lib/libmruby.a", self_path)
end
exit 0 if ENV['FORCE'].to_s.empty? && fresh.call

unless which('ruby')
  $stderr.puts 'setup-poly: ruby (CRuby) is needed to bootstrap mruby\'s build'
  exit 1
end
if which('rake')
  rake = ['rake']
else
  bindir, = capture(['ruby', '-e', 'print Gem.bindir'])
  if File.executable?("#{bindir}/rake")
    bindir, = capture(['ruby', '-e', 'print Gem.bindir'])   # the shell runs the command substitution again here
    rake = ["#{bindir}/rake"]
  else
    rake = ['ruby', '-rrake', '-e', 'Rake.application.run(ARGV)', '--']
  end
end
unless run(rake + ['--version'], out: File::NULL, err: File::NULL) == 0
  $stderr.puts 'setup-poly: the rake gem is needed (apt-get install rake)'
  exit 1
end
unless File.executable?("#{root}/build/edg/bin/eccp")
  $stderr.puts 'setup-poly: EDG not built; run scripts/setup-edg.sh'
  exit 1
end
run(['mkdir', '-p', work])
# One build at a time per tree (rake writes into the source tree's .lock files and the build directory).
lock = File.open("#{work}/.lock", 'w')
lock.flock(File::LOCK_EX) if which('flock')
exit 0 if ENV['FORCE'].to_s.empty? && fresh.call

unless File.directory?("#{src}/.git")
  ok = run(['mkdir', '-p', src]) == 0 &&
       run(['git', '-C', src, 'init', '-q']) == 0 &&
       run(['git', '-C', src, 'remote', 'add', 'origin', 'https://github.com/mruby/mruby']) == 0
  exit 1 unless ok
end
out_rev, = capture(['git', '-C', src, 'rev-parse', '-q', '--verify', "#{pin}^{commit}"])
if out_rev != pin
  unless run(['git', '-C', src, 'fetch', '-q', '--depth', '1', 'origin', pin]) == 0
    $stderr.puts "setup-poly: fetching mruby #{pin} failed"
    exit 1
  end
end
exit 1 unless run(['git', '-C', src, 'reset', '-q', '--hard', pin]) == 0

# mruby writes a .lock file next to its config, so the config is copied into the work dir.
run(['cp', 'scripts/mruby-rt-config.rb', "#{work}/build_config-#{be}.rb"])
log = "#{work}/build-#{be}.log"
built = run([*rake, "-j#{jobs}", 'all'], chdir: src,
            env: { 'NFCXX_BACKEND' => be, 'MRUBY_CC' => "#{root}/nfcc", 'MRUBY_CXX' => "#{root}/nfcxx",
                   'MRUBY_CONFIG' => "#{work}/build_config-#{be}.rb", 'MRUBY_BUILD_DIR' => out },
            out: [log, 'w'], err: [:child, :out])
unless built == 0
  run(['tail', '-30', log], out: $stderr)
  $stderr.puts "setup-poly: build failed (full log: #{log})"
  exit 1
end
lib = "#{out}/host/lib/libmruby.a"
unless File.file?(lib)
  $stderr.puts "setup-poly: #{lib} missing after the build (log: #{log})"
  exit 1
end
run(['rm', '-rf', "#{dest}.new"])
run(['mkdir', '-p', "#{dest}.new/lib", "#{dest}.new/include"])
run(['cp', lib, "#{dest}.new/lib/libmruby.a"])
run(['cp', '-r', "#{src}/include/.", "#{dest}.new/include/"])
run(['cp', '-r', "#{out}/host/include/.", "#{dest}.new/include/"]) if File.directory?("#{out}/host/include")
run(['rm', '-rf', dest])
run(['mv', "#{dest}.new", dest])
$stderr.puts "setup-poly: built #{dest}/lib/libmruby.a (backend #{be}, C++ exceptions)"
