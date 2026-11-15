#!/usr/bin/env ruby
# frozen_string_literal: true

# Fetches the CUDA runtime and CCCL from PyPI (the nvidia-cuda-runtime and nvidia-cuda-cccl wheels) and assembles a
# CUDA_HOME-shaped directory (include/, lib64/) that nfcxx uses in place of the toolkit's, so the build needs no
# toolkit libraries. Usage: scripts/fetch-cudart-wheel.rb [MAJOR.MINOR]
#   Prints "cuda-home: DIR"; use it as NFCXX_CUDA_WHEEL (or CUDA_HOME). Default MAJOR.MINOR is the toolkit's in CUDA_HOME.
#   For each package the release with that MAJOR.MINOR is picked, else the newest of the same major. sha256 is checked
#   against PyPI's JSON before anything is unpacked.
#
# The Ruby port of tests/fetch/oracle/fetch-cudart-wheel.sh; tests/fetch/run.sh checks that the output and the tree match.
# Differences: the wheels are unpacked with unzip (the bash used Python's zipfile), and a failed download exits 1 with the
# HTTP status where curl exited 22; a MAJOR.MINOR with no release exits 1 with a message where Python raised IndexError.
require 'fileutils'
require 'find'
require_relative 'fetch-lib'

PROG = 'fetch-cudart-wheel'

# The two spellings of the x86_64 wheel tag that the bash matched (PyPI names them either way).
X86_WHEEL_SUFFIXES = %w[manylinux_2_17_x86_64.manylinux2014_x86_64.whl manylinux2014_x86_64.manylinux_2_17_x86_64.whl].freeze

# The release of PKG for WANT ("MAJOR.MINOR", or "" for the newest): the newest with that MAJOR.MINOR, else the newest of
# the same major. Returns [version, filename, url, sha256].
def pick(pkg, want)
  rel = []
  FetchLib.pypi_json(pkg).fetch('releases').each do |version, files|
    files.each do |f|
      name = f['filename']
      next unless X86_WHEEL_SUFFIXES.any? { |s| name.end_with?(s) }

      rel << [version, name, f['url'], f.dig('digests', 'sha256')]
    end
  end
  raise 'no x86_64 wheel on PyPI for this package' if rel.empty?

  # Python's sort is stable and the key drops the non-numeric parts: the same order here.
  key = ->(v) { v.split('.').select { |x| x.match?(/\A[0-9]+\z/) }.map(&:to_i) }
  rel = rel.each_with_index.sort_by { |r, i| [key.call(r[0]), i] }.map(&:first)
  exact = want.empty? ? [] : rel.select { |r| r[0].start_with?("#{want}.") }
  major = (want.empty? ? rel.last[0] : want).split('.')[0]
  exact.last || rel.select { |r| r[0].split('.')[0] == major }.last ||
    raise("no release of #{pkg} for major #{major}")
end

def fetch(out, pkg, want)
  ver, name, url, sha = pick(pkg, want)
  FileUtils.mkdir_p("#{out}/#{pkg}")
  whl = "#{out}/#{pkg}/#{name}"
  FetchLib.download(url, whl)
  unless FetchLib.sha256(whl) == sha
    FileUtils.rm_f(whl)
    raise "sha256 mismatch for #{name}"
  end

  dest = "#{out}/#{pkg}/#{ver}"
  FileUtils.rm_rf(dest)
  FileUtils.mkdir_p(dest)
  FetchLib.unzip(whl, dest)
  FetchLib.zipfile_modes(dest)
  dest
end

# find ROOT -type d -name NAME -path '*nvidia*' | head -1 (find lists a directory before its children).
def first_dir(root, name)
  Find.find(root).find do |p|
    File.lstat(p).directory? && File.basename(p) == name && p.include?('nvidia')
  end
end

# The MAJOR.MINOR of cuda_cudart in CUDA_HOME/version.json, read line by line as the bash's sed did: a line holding
# "cuda_cudart" and its "version" gives it; a pretty-printed file, with the version on another line, gives "".
def want_from_cuda(cuda)
  path = "#{cuda}/version.json"
  return '' unless File.file?(path)

  re = /"cuda_cudart" *: *\{[^}]*"version" *: *"([0-9]*\.[0-9]*)/
  File.foreach(path) do |line|
    m = re.match(line)
    return m[1] if m
  end
  ''
end

def main(argv)
  out = FetchLib.present(ENV['CUDART_WHEEL_DIR']) ||
        "#{FetchLib.present(ENV['XDG_CACHE_HOME']) || "#{ENV.fetch('HOME')}/.cache"}/nfcxx/cudart-wheel"
  cuda = FetchLib.present(ENV['CUDA_HOME']) || '/usr/local/cuda'
  want = argv[0] || ''
  want = want_from_cuda(cuda) if want.empty?

  rt = fetch(out, 'nvidia-cuda-runtime', want)
  cc = fetch(out, 'nvidia-cuda-cccl', want)
  crt = fetch(out, 'nvidia-cuda-crt', want)
  rt_inc = first_dir(rt, 'include')
  rt_lib = first_dir(rt, 'lib')
  cc_inc = first_dir(cc, 'include')
  raise 'include/ or lib/ missing in a wheel' unless rt_inc && rt_lib && cc_inc

  # The CUDA_HOME shape: include/ (runtime headers, with CCCL's cccl/ beside them) and lib64/ (libcudart.so and its .so.N).
  home = "#{out}/cuda-home"
  FileUtils.rm_rf(home)
  FileUtils.mkdir_p("#{home}/lib64")
  FetchLib.copy_a(rt_inc, "#{home}/include")
  # crt/ (host_config.h and the device-side headers) ships in its own package.
  crt_inc = first_dir(crt, 'include')
  FetchLib.copy_contents(crt_inc, "#{home}/include", preserve: true) if crt_inc
  unless File.exist?("#{home}/include/cccl")
    if File.exist?("#{cc_inc}/cccl")
      FetchLib.copy_a("#{cc_inc}/cccl", "#{home}/include/cccl")
    else
      FetchLib.copy_a(cc_inc, "#{home}/include/cccl")
    end
  end
  # nv/ (the target macros the runtime headers include) is beside cccl/ in the CCCL wheel.
  FetchLib.copy_a("#{cc_inc}/nv", "#{home}/include/nv") if File.directory?("#{cc_inc}/nv")

  libs = Dir.children(rt_lib).select { |f| File.fnmatch?('libcudart.so*', f) }.sort
  raise "cp: cannot stat '#{rt_lib}/libcudart.so*'" if libs.empty?

  libs.each { |f| FetchLib.copy_a("#{rt_lib}/#{f}", "#{home}/lib64") }
  so = Dir.children("#{home}/lib64").sort.find { |n| n.match?(/\Alibcudart\.so\.[0-9]+\z/) }
  if so
    FileUtils.rm_f("#{home}/lib64/libcudart.so")
    File.symlink(so, "#{home}/lib64/libcudart.so")
  end

  puts "cuda-home: #{home}"
  puts "runtime: #{File.basename(rt)}"
  puts "cccl: #{File.basename(cc)}"
  puts "crt: #{File.basename(crt)}"
end

begin
  main(ARGV)
rescue StandardError => e
  warn "#{PROG}: #{e.message}"
  exit 1
end
