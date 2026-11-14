#!/usr/bin/env ruby
# Fetches the CUDA libraries that the library-link tests need from PyPI (NVIDIA's wheels) and assembles a
# CUDA_HOME-shaped directory: include/ (cuda_runtime.h, the crt/ headers, cccl/ under include/cccl, cublas_v2.h,
# cudnn.h), lib64/ (libcudart, libcublas, libcudnn, with unversioned names) and bin/ptxas. Nothing is run on a GPU:
# the directory is for compiling and linking. Usage: scripts/fetch-cuda-libs.rb [DIR]   (default: $CUDA_LIBS_DIR or
# ~/.cache/nfcxx/cuda-libs). Prints "cuda-home: DIR"; use it as CUDA_HOME.
# Wheel versions are pinned, so the directory is the same from run to run. Each wheel is a zip; the files are
# copied out of it and the libraries get the unversioned symlinks that -lcublas, -lcudnn and -lcudart need.
require "fileutils"

$stdout.sync = true
PKGS = %w[nvidia-cuda-runtime-cu12==12.9.79 nvidia-cuda-cccl-cu12==12.9.27 nvidia-cuda-nvcc-cu12==12.9.86
          nvidia-cublas-cu12==12.9.2.10 nvidia-cudnn-cu12==9.27.0.42].freeze
CHECK = %w[include/cuda_runtime.h include/crt/host_config.h include/cccl/nv/target include/cublas_v2.h include/cudnn.h
           lib64/libcudart.so lib64/libcublas.so lib64/libcudnn.so bin/ptxas].freeze

# The first value that is set and not empty, as the shell's ${VAR:-default} takes it.
def first_set(*values)
  values.find { |v| v && !v.empty? }
end

# Runs a command as the script's `set -e` does: when it fails, the script ends with its status.
def run!(*cmd)
  system(*cmd)
  status = $?
  exit(status.exitstatus || 1) unless status.success?
end

# cp -r SRC/. DST: the entries of SRC, copied into DST
def copy_contents(src, dst)
  unless Dir.exist?(src)
    warn "cp: cannot stat '#{src}/.': No such file or directory"
    exit 1
  end
  Dir.children(src).sort.each { |c| FileUtils.cp_r("#{src}/#{c}", dst) }
end

# cp SRC DST: a failed copy ends the script with cp's status, as under `set -e`
def cp!(src, dst)
  FileUtils.cp(src, dst)
rescue SystemCallError
  warn "cp: cannot stat '#{src}': No such file or directory"
  exit 1
end

# cp SRC... DST, for shell globs: an unmatched pattern fails the copy, as cp does with the literal pattern
def copy_globs(patterns, dst)
  files = patterns.flat_map do |pat|
    matches = Dir.glob(pat).sort
    if matches.empty?
      warn "cp: cannot stat '#{pat}': No such file or directory"
      exit 1
    end
    matches
  end
  files.each { |f| cp!(f, dst) }
end

out = first_set(ARGV[0], ENV["CUDA_LIBS_DIR"])
out ||= "#{first_set(ENV["XDG_CACHE_HOME"]) || "#{ENV.fetch("HOME")}/.cache"}/nfcxx/cuda-libs"
wheels = "#{out}/wheels"

FileUtils.mkdir_p(wheels)
run!("python3", "-m", "pip", "download", "--no-deps", "-q", "-d", wheels, *PKGS)
FileUtils.rm_rf(["#{out}/x", "#{out}/include", "#{out}/lib64", "#{out}/bin"])
whls = Dir.glob("#{wheels}/*.whl").sort
whls = ["#{wheels}/*.whl"] if whls.empty?
whls.each { |w| run!("unzip", "-oq", w, "-d", "#{out}/x") }
n = "#{out}/x/nvidia"
FileUtils.mkdir_p(["#{out}/include/cccl", "#{out}/lib64", "#{out}/bin"])
copy_contents("#{n}/cuda_runtime/include", "#{out}/include/")
copy_contents("#{n}/cuda_nvcc/include", "#{out}/include/")
copy_contents("#{n}/cuda_cccl/include", "#{out}/include/cccl/")
copy_contents("#{n}/cublas/include", "#{out}/include/")
copy_contents("#{n}/cudnn/include", "#{out}/include/")
copy_globs(["#{n}/cuda_runtime/lib/*.so.*", "#{n}/cublas/lib/*.so.*", "#{n}/cudnn/lib/*.so.*"], "#{out}/lib64/")
cp!("#{n}/cuda_nvcc/bin/ptxas", "#{out}/bin/")
File.chmod(File.stat("#{out}/bin/ptxas").mode | (0o111 & ~File.umask), "#{out}/bin/ptxas")
Dir.chdir("#{out}/lib64") do
  Dir.glob("lib*.so.*").sort.each { |f| FileUtils.ln_sf(f, "#{f.split(".so.", 2).first}.so") }
end
FileUtils.rm_rf("#{out}/x")

CHECK.each do |f|
  next if File.exist?("#{out}/#{f}")
  warn "fetch-cuda-libs: #{f} missing from the wheels"
  exit 1
end
puts "cuda-home: #{out}"
