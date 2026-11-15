#!/usr/bin/env ruby
# Path B CIL spike (docs/notes/pathb-cil.md): a C++ file -> Path B IR (pathb-dump --ir) -> pathb-cil-emit.rb (fragment) ->
# cil-link.rb (CIL, ilasm) -> an executable launcher (dotnet).
# -c writes the JSON fragment of the one file to OUT and does not link (the object file of scripts/cil-cc.rb).
# Usage: scripts/pathb-cil.rb [-c] [-o OUT] [-std=STD] [-Idir] [-Dmacro] [-Umacro] file.cpp|file.c...
# A .c file is read as C (-std=c11 and _DEFAULT_SOURCE, as gcc's default dialect defines it, unless -std is given), as nfcxx
# reads a C input; every file is one fragment of the link.
# The Ruby port of the bash script (its original is tests/helpers/oracle/pathb-cil.sh).
require 'fileutils'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
MRB = File.join(ROOT, 'scripts/mrb.rb')

# runs cmd (a path, or [path, argv0]) and returns its status (127 when it cannot run)
def run(cmd, *args, **redirect)
  ok = system(cmd, *args, **redirect)
  return 127 if ok.nil?

  $?.exitstatus || 1
end

out = 'a.out'
files = []
fl = []
only_c = false
argv = ARGV.dup
until argv.empty?
  a = argv.shift
  case a
  when '-o'
    if argv.empty?
      # bash (set -u) reports the unset $2 of a -o without its value, and exits 1
      $stderr.puts '$2: unbound variable'
      exit 1
    end
    out = argv.shift
  when '-c'
    only_c = true
  when /\A-std=/, /\A-[IDU]./m
    fl << a
  else
    files << a
  end
end

if files.empty?
  $stderr.puts 'usage: scripts/pathb-cil.rb [-o OUT] [-std=STD] [-Idir] [-Dmacro] file.cpp|file.c...'
  exit 2
end

Dir.mktmpdir('pathb-cil') do |tmp|
  dump = File.join(ROOT, 'scripts/pathb-dump.rb')
  frags = []
  files.each_with_index do |f, index|
    i = index + 1
    std = f.end_with?('.c') ? ['-std=c11', '-D_DEFAULT_SOURCE'] : []
    ir = File.join(tmp, "ir#{i}")
    dump_err = File.join(tmp, 'dump.err')
    unless run([dump, dump], '--ir', *std, *fl, f, out: ir, err: dump_err).zero?
      $stderr.write(File.binread(dump_err))
      exit 1
    end

    # The unit name of the fragment: the file's basename, as scripts/qbe-cc names it (a static name of the unit is name@UNIT).
    tu = File.basename(f).sub(/\.[^.]*\z/, '').b.gsub(/[^A-Za-z0-9_.-]/, '_')
    tu = "#{tu}.#{i}" unless only_c
    frag = File.join(tmp, "frag#{i}.json")
    status = run([MRB, MRB], File.join(ROOT, 'scripts/pathb-cil-emit.rb'), ir, frag, tu)
    exit status unless status.zero?
    frags << frag
  end

  if only_c
    unless files.size == 1
      $stderr.puts 'pathb-cil: -c takes one file'
      exit 2
    end
    FileUtils.cp(frags[0], out)
    exit 0
  end

  # The link takes its settings as arguments (the mruby interpreter has no environment): ILASM, CC and NFCXX_KEEP_IL.
  keep = ENV['NFCXX_KEEP_IL'].to_s.empty? ? [] : ['--keep-il']
  ilasm = ENV['ILASM'].to_s.empty? ? File.join(ROOT, 'build/cil/ilasm') : ENV['ILASM']
  cc = ENV['CC'].to_s.empty? ? 'cc' : ENV['CC']
  status = run([MRB, MRB], File.join(ROOT, 'scripts/cil-link.rb'), '--ilasm', ilasm, '--cc', cc, *keep,
               '-o', out, *frags)
  exit status
end
