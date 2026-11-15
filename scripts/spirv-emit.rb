#!/usr/bin/env ruby
# The SPIR-V emitter of the SYCL path, as scripts/sycl-build.rb and tests/gpu/ggml/sweep.sh run it:
#   scripts/spirv-emit.rb [--kernel-cl] --manifest=FILE FILE.ir > out.spv
# NFCXX_SPIRV_EMITTER picks the implementation (default: cxx when ninja is installed, else ruby):
#   cxx             build/pathb-spirv-emit, the C++ port (tools/pathb-spirv-emit; built here with ninja when missing or
#                   older than its sources): about 1 s for ggml-sycl's fattn-vec-instance-f16-f16
#   ruby            scripts/pathb-spirv-emit.rb, on CRuby when it is installed (NFCXX_SPIRV_RUBY names the interpreter), else
#                   on scripts/mrb.rb (mruby, whose garbage collector makes the same image take ~2000 s; CRuby ~16 s)
#   check           both: the module, the manifest, the exit status and the message must be the same, byte for byte (exit 99
#                   and a report on stderr otherwise); the outputs are the Ruby's
# The Ruby port of the bash wrapper (its original is tests/helpers/oracle/spirv-emit.sh).
require 'fileutils'
require 'tmpdir'
require_relative 'tool-ensure'

ROOT = File.expand_path('..', __dir__)
CXX = File.join(ROOT, 'build/pathb-spirv-emit')

# command -v NAME
def which(cmd)
  ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
    path = File.join(dir.empty? ? '.' : dir, cmd)
    return path if File.file?(path) && File.executable?(path)
  end
  nil
end

# find "$root/tools/pathb-spirv-emit" -newer CXX -name '*.[ch]pp'
def newer_sources?
  cxx_mtime = File.mtime(CXX)
  Dir.glob(File.join(ROOT, 'tools/pathb-spirv-emit', '**', '*'), File::FNM_DOTMATCH).any? do |p|
    next false unless File.basename(p).match?(/\.[ch]pp\z/)

    mtime = (File.mtime(p) rescue nil)
    mtime && mtime > cxx_mtime
  end
end

def need_cxx
  return if File.executable?(CXX) && !newer_sources?

  # one build at a time (parallel compiles can all find the binary missing). The bash wrapper keeps this lock's descriptor
  # (8) open across the exec of the emitter, so the lock is held while the emitter runs; close_on_exec = false does the same.
  lock = File.join(ROOT, 'build/.pathb-spirv-emit.lock')
  begin
    $lock_io = File.open(lock, 'w')
  rescue Errno::ENOENT
    $stderr.puts "#{lock}: No such file or directory"
    exit 1
  rescue Errno::EACCES
    $stderr.puts "#{lock}: Permission denied"
    exit 1
  end
  $lock_io.close_on_exec = false
  $lock_io.flock(File::LOCK_EX) if which('flock')
  ok = system('ninja', '-C', File.join(ROOT, 'tools/pathb-spirv-emit'), out: $stderr)
  unless ok
    $stderr.puts 'ninja: command not found' if ok.nil?
    $stderr.puts 'spirv-emit: building the C++ emitter failed'
    exit 1
  end
end

# runs cmd (a path, or [path, argv0]) with args; the status, 127 when it cannot run (as the shell reports it)
def run(cmd, *args, **redirect)
  ok = system(cmd, *args, **redirect)
  return $?.exitstatus || 1 unless ok.nil?

  File.write(redirect[:err], "#{Array(cmd).first}: command not found\n", mode: 'a') if redirect[:err]
  127
end

def same?(a, b)
  File.exist?(a) && File.exist?(b) && File.binread(a) == File.binread(b)
end

# head -3 FILES >&2 (the headers of several files are shown)
def head3(files)
  files.each_with_index do |f, i|
    $stderr.write("\n") if i.positive?
    $stderr.write("==> #{f} <==\n") if files.size > 1
    $stderr.write(File.binread(f).lines.first(3).join)
  end
end

def check(rb, args, man)
  Dir.mktmpdir('spirv-emit') do |tmp|
    t = ->(name) { File.join(tmp, name) }
    manifest = ->(name) { man.to_s.empty? ? [] : ["--manifest=#{t.(name)}"] }
    rrc = run([rb, rb], File.join(ROOT, 'scripts/pathb-spirv-emit.rb'), *manifest.('rb.man'), *args,
              out: t.('rb.spv'), err: t.('rb.err'))
    crc = run([CXX, CXX], *manifest.('cx.man'), *args, out: t.('cx.spv'), err: t.('cx.err'))
    bad = nil
    add = ->(s) { bad = bad ? "#{bad}; #{s}" : s }
    add.("exit #{rrc} (Ruby) against #{crc} (C++)") unless rrc == crc
    add.('the modules differ') unless same?(t.('rb.spv'), t.('cx.spv'))
    add.('the messages differ') unless same?(t.('rb.err'), t.('cx.err'))
    if !man.to_s.empty? && (File.exist?(t.('rb.man')) || File.exist?(t.('cx.man'))) &&
       !same?(t.('rb.man'), t.('cx.man'))
      add.('the manifests differ')
    end
    unless bad.nil?
      $stderr.puts "spirv-emit: the C++ emitter differs from the Ruby on #{args.join(' ')}: #{bad}"
      head3([t.('rb.err'), t.('cx.err')])
      return 99
    end
    $stderr.write(File.binread(t.('rb.err')))
    FileUtils.cp(t.('rb.man'), man) if !man.to_s.empty? && File.exist?(t.('rb.man'))
    $stdout.binmode
    $stdout.write(File.binread(t.('rb.spv')))
    rrc
  end
end

rb = ENV['NFCXX_SPIRV_RUBY'].to_s
rb = (which('ruby') || File.join(ROOT, 'scripts/mrb.rb')) if rb.empty?
dflt = which('ninja') ? 'cxx' : 'ruby'
mode = ENV['NFCXX_SPIRV_EMITTER'].to_s
mode = dflt if mode.empty?
case mode
when 'ruby'
  ToolEnsure.exec_program(rb, File.join(ROOT, 'scripts/pathb-spirv-emit.rb'), *ARGV)
when 'cxx'
  need_cxx
  ToolEnsure.exec_program(CXX, *ARGV)
when 'check'
  need_cxx
  args = []
  man = nil
  ARGV.each do |a|
    if a.start_with?('--manifest=')
      man = a.delete_prefix('--manifest=')
    else
      args << a
    end
  end
  exit check(rb, args, man)
else
  $stderr.puts "spirv-emit: NFCXX_SPIRV_EMITTER is ruby, cxx or check (got #{mode})"
  exit 2
end
