#!/usr/bin/env ruby
# frozen_string_literal: true

# Fetches the CUDA libraries that the library-link tests need from PyPI (NVIDIA's wheels) and assembles a
# CUDA_HOME-shaped directory: include/ (cuda_runtime.h, the crt/ headers, cccl/ under include/cccl, cublas_v2.h,
# cudnn.h), lib64/ (libcudart, libcublas, libcudnn, with unversioned names) and bin/ptxas. Nothing is run on a GPU:
# the directory is for compiling and linking. Usage: scripts/fetch-cuda-libs.rb [DIR]   (default: $CUDA_LIBS_DIR or
# ~/.cache/nfcxx/cuda-libs). Prints "cuda-home: DIR"; use it as CUDA_HOME.
# Wheel versions are pinned, so the directory is the same from run to run. Each wheel is a zip; the files are
# copied out of it and the libraries get the unversioned symlinks that -lcublas, -lcudnn and -lcudart need.
#
# The Ruby port of tests/fetch/oracle/fetch-cuda-libs.sh; tests/fetch/run.sh checks that the output and the tree match.
# Differences: no pip. Each pinned wheel is looked up in PyPI's JSON API and downloaded with Net::HTTP; a wheel already in
# the directory with the right sha256 is not downloaded again, and a wheel that does not match is.
require 'fileutils'
require_relative 'fetch-lib'

PROG = 'fetch-cuda-libs'

# The pins. PyPI has one x86_64 wheel for each, which is the one pip took.
PINS = [
  ['nvidia-cuda-runtime-cu12', '12.9.79'],
  ['nvidia-cuda-cccl-cu12', '12.9.27'],
  ['nvidia-cuda-nvcc-cu12', '12.9.86'],
  ['nvidia-cublas-cu12', '12.9.2.10'],
  ['nvidia-cudnn-cu12', '9.27.0.42']
].freeze

# The libraries and headers the tree must have (the bash checked these after the layout).
REQUIRED = %w[
  include/cuda_runtime.h include/crt/host_config.h include/cccl/nv/target include/cublas_v2.h include/cudnn.h
  lib64/libcudart.so lib64/libcublas.so lib64/libcudnn.so bin/ptxas
].freeze

def download_pinned(project, version, wheels)
  files = FetchLib.pypi_json(project, version).fetch('urls')
  candidates = files.select { |f| f['packagetype'] == 'bdist_wheel' && f['filename'].end_with?('x86_64.whl') }
  raise "#{project}==#{version}: #{candidates.size} x86_64 wheels on PyPI, expected one" unless candidates.size == 1

  file = candidates.first
  path = "#{wheels}/#{file['filename']}"
  sha = file.dig('digests', 'sha256')
  return if File.file?(path) && FetchLib.sha256(path) == sha

  FetchLib.download(file['url'], path)
  return if FetchLib.sha256(path) == sha

  FileUtils.rm_f(path)
  raise "sha256 mismatch for #{file['filename']}"
end

def main(argv)
  out = FetchLib.present(argv[0]) || FetchLib.present(ENV['CUDA_LIBS_DIR']) ||
        "#{FetchLib.present(ENV['XDG_CACHE_HOME']) || "#{ENV.fetch('HOME')}/.cache"}/nfcxx/cuda-libs"
  wheels = "#{out}/wheels"
  FileUtils.mkdir_p(wheels)
  PINS.each { |project, version| download_pinned(project, version, wheels) }

  FileUtils.rm_rf(["#{out}/x", "#{out}/include", "#{out}/lib64", "#{out}/bin"])
  Dir.children(wheels).select { |n| File.fnmatch?('*.whl', n) }.sort.each do |w|
    FetchLib.unzip("#{wheels}/#{w}", "#{out}/x")
  end

  nv = "#{out}/x/nvidia"
  FileUtils.mkdir_p(["#{out}/include/cccl", "#{out}/lib64", "#{out}/bin"])
  FetchLib.copy_contents("#{nv}/cuda_runtime/include", "#{out}/include")
  FetchLib.copy_contents("#{nv}/cuda_nvcc/include", "#{out}/include")
  FetchLib.copy_contents("#{nv}/cuda_cccl/include", "#{out}/include/cccl")
  FetchLib.copy_contents("#{nv}/cublas/include", "#{out}/include")
  FetchLib.copy_contents("#{nv}/cudnn/include", "#{out}/include")

  %w[cuda_runtime cublas cudnn].each do |lib|
    names = Dir.children("#{nv}/#{lib}/lib").select { |f| File.fnmatch?('*.so.*', f) }.sort
    raise "cp: cannot stat '#{nv}/#{lib}/lib/*.so.*'" if names.empty?

    names.each { |f| FetchLib.copy_into("#{nv}/#{lib}/lib/#{f}", "#{out}/lib64") }
  end

  FetchLib.copy_into("#{nv}/cuda_nvcc/bin/ptxas", "#{out}/bin")
  File.chmod(File.stat("#{out}/bin/ptxas").mode | 0o111, "#{out}/bin/ptxas")

  # libfoo.so.N -> libfoo.so, the name -lfoo asks for. Each name is taken from the listing made before any link exists.
  lib64 = "#{out}/lib64"
  Dir.children(lib64).sort.select { |f| File.fnmatch?('lib*.so.*', f) }.each do |f|
    link = "#{lib64}/#{f.sub(/\.so\..*\z/m, '.so')}"
    FileUtils.rm_f(link)
    File.symlink(f, link)
  end

  FileUtils.rm_rf("#{out}/x")
  REQUIRED.each { |f| raise "#{f} missing from the wheels" unless File.exist?("#{out}/#{f}") }
  puts "cuda-home: #{out}"
end

begin
  main(ARGV)
rescue StandardError => e
  warn "#{PROG}: #{e.message}"
  exit 1
end
