#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes the stub PyPI that tests/fetch/run.sh serves for fetch-cudart-wheel (the port and its bash original, which reaches
# it through a curl shim):
#   DIR/pypi/PROJECT/json  the JSON API, with the file URLs at BASE
#   DIR/files/NAME         the wheels, as symlinks to the cached runtime and cccl wheels and to the synthetic crt wheel
# MODE: normal; badsha (the sha256 of runtime 12.9.79 is wrong); missing (runtime 12.9.79's file is not served).
# Usage: stub.rb DIR BASE MODE RUNTIME_WHEEL CCCL_WHEEL CRT_WHEEL
require 'digest'
require 'fileutils'
require 'json'

abort 'usage: stub.rb DIR BASE MODE RUNTIME_WHEEL CCCL_WHEEL CRT_WHEEL' unless ARGV.size == 6

dir, base, mode, *sources = ARGV
abort "stub.rb: MODE must be normal, badsha or missing, not #{mode}" unless %w[normal badsha missing].include?(mode)

# project => [wheel name prefix, source wheel, the versions served]. Versions share a source file: the bytes are the same.
PROJECTS = {
  'nvidia-cuda-runtime' => ['nvidia_cuda_runtime', sources[0], %w[12.8.90 12.9.10 12.9.79 13.0.1]],
  'nvidia-cuda-cccl' => ['nvidia_cuda_cccl', sources[1], %w[12.8.90 12.9.5 12.9.27]],
  'nvidia-cuda-crt' => ['nvidia_cuda_crt', sources[2], %w[12.8.1 12.9.1]]
}.freeze
TAG = 'py3-none-manylinux2014_x86_64.manylinux_2_17_x86_64.whl'

FileUtils.rm_rf(["#{dir}/pypi", "#{dir}/files"])
FileUtils.mkdir_p(["#{dir}/files"])
PROJECTS.each do |project, (prefix, src, versions)|
  FileUtils.mkdir_p("#{dir}/pypi/#{project}")
  src_sha = Digest::SHA256.file(src).hexdigest
  releases = versions.to_h do |ver|
    name = "#{prefix}-#{ver}-#{TAG}"
    broken = project == 'nvidia-cuda-runtime' && ver == '12.9.79'
    FileUtils.rm_f("#{dir}/files/#{name}")
    File.symlink(File.expand_path(src), "#{dir}/files/#{name}") unless mode == 'missing' && broken
    sha = mode == 'badsha' && broken ? '0' * 64 : src_sha
    [ver, [{ 'filename' => name, 'url' => "#{base}/files/#{name}", 'packagetype' => 'bdist_wheel',
             'digests' => { 'sha256' => sha } }]]
  end
  File.write("#{dir}/pypi/#{project}/json", JSON.generate({ 'info' => { 'name' => project }, 'releases' => releases }))
end
