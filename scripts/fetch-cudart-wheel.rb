#!/usr/bin/env ruby
# Fetches the CUDA runtime and CCCL from PyPI (the nvidia-cuda-runtime and nvidia-cuda-cccl wheels) and assembles a
# CUDA_HOME-shaped directory (include/, lib64/) that nfcxx uses in place of the toolkit's, so the build needs no
# toolkit libraries. Usage: scripts/fetch-cudart-wheel.rb [MAJOR.MINOR]
#   Prints "cuda-home: DIR"; use it as NFCXX_CUDA_WHEEL (or CUDA_HOME). Default MAJOR.MINOR is the toolkit's in CUDA_HOME.
#   For each package the release with that MAJOR.MINOR is picked, else the newest of the same major. sha256 is checked
#   against PyPI's JSON before anything is unpacked.
require "digest"
require "fileutils"
require "json"
require "tempfile"
require "zlib"

$stdout.sync = true
PKG_SUFFIXES = ["manylinux_2_17_x86_64.manylinux2014_x86_64.whl", "manylinux2014_x86_64.manylinux_2_17_x86_64.whl"].freeze

# ${VAR:-default} for a variable: the default when it is unset or empty
def or_default(value, default)
  value.nil? || value.empty? ? default : value
end

# Runs a command as the script's `set -e` does: when it fails, the script ends with its status.
def run!(*cmd)
  system(*cmd)
  status = $?
  exit(status.exitstatus || 1) unless status.success?
end

# cp -a SRC DST, with the symlinks kept (cp -a)
def cp_a!(src, dst)
  FileUtils.cp_r(src, dst, preserve: true)
rescue SystemCallError
  warn "cp: cannot stat '#{src}': No such file or directory"
  exit 1
end

# The index of the first directory under DIR named NAME whose path contains "nvidia" (find DIR -type d -name NAME -path
# '*nvidia*' | head -1), or nil. The directories are taken in sorted order.
def find_dir(dir, name)
  Dir.glob("#{dir}/**/*/", File::FNM_DOTMATCH).map { |d| d.chomp("/") }.sort
     .find { |d| File.basename(d) == name && d.include?("nvidia") }
end

# Extracts the zip archive PATH into DIR (zipfile's extractall): stored and deflated entries
def extract_zip(path, dir)
  data = File.binread(path)
  eocd = data.rindex("PK\x05\x06".b)
  cd_off = data.unpack1("@#{eocd + 16}V")
  count = data.unpack1("@#{eocd + 10}v")
  pos = cd_off
  count.times do
    name_len, extra_len, comment_len = data.unpack("@#{pos + 28}vvv")
    method = data.unpack1("@#{pos + 10}v")
    csize = data.unpack1("@#{pos + 20}V")
    local = data.unpack1("@#{pos + 42}V")
    name = data.byteslice(pos + 46, name_len).force_encoding("UTF-8")
    pos += 46 + name_len + extra_len + comment_len
    target = File.join(dir, name)
    if name.end_with?("/")
      FileUtils.mkdir_p(target)
      next
    end
    l_name, l_extra = data.unpack("@#{local + 26}vv")
    raw = data.byteslice(local + 30 + l_name + l_extra, csize)
    body = method == 8 ? Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(raw) : raw
    FileUtils.mkdir_p(File.dirname(target))
    File.binwrite(target, body)
  end
end

# fetch PKG: downloads and unpacks the chosen wheel into $out/PKG/VERSION; prints that directory.
def fetch(pkg, want, out)
  Tempfile.create("fetch") do |json|
    json.close
    run!("curl", "-sSfL", "https://pypi.org/pypi/#{pkg}/json", "-o", json.path)
    rel = []
    JSON.parse(File.read(json.path))["releases"].each do |v, files|
      files.each do |f|
        n = f["filename"]
        rel << [v, n, f["url"], f["digests"]["sha256"]] if PKG_SUFFIXES.any? { |s| n.end_with?(s) }
      end
    end
    if rel.empty?
      warn "no x86_64 wheel on PyPI for this package"
      exit 1
    end
    key = ->(v) { v.split(".").select { |x| x.match?(/\A[0-9]+\z/) }.map(&:to_i) }
    rel = rel.each_with_index.sort_by { |r, i| [key.(r[0]), i] }.map(&:first)
    exact = want.empty? ? [] : rel.select { |r| r[0].start_with?("#{want}.") }
    major = (want.empty? ? rel.last[0] : want).split(".", -1)[0] || ""
    pick = exact.last || rel.select { |r| (r[0].split(".", -1)[0] || "") == major }.last
    if pick.nil?
      warn "fetch-cudart-wheel: no release of #{pkg} for #{major}"
      exit 1
    end
    ver, name, url, sha = pick
    FileUtils.mkdir_p("#{out}/#{pkg}")
    whl = "#{out}/#{pkg}/#{name}"
    run!("curl", "-sSfL", url, "-o", whl)
    unless Digest::SHA256.file(whl).hexdigest == sha
      warn "fetch-cudart-wheel: sha256 mismatch for #{name}"
      FileUtils.rm_f(whl)
      exit 1
    end
    dest = "#{out}/#{pkg}/#{ver}"
    FileUtils.rm_rf(dest)
    FileUtils.mkdir_p(dest)
    extract_zip(whl, dest)
    dest
  end
end

want = ARGV[0].to_s
cuda = or_default(ENV["CUDA_HOME"], "/usr/local/cuda")
if want.empty? && File.file?("#{cuda}/version.json")
  File.foreach("#{cuda}/version.json") do |line|
    m = line.match(/.*"cuda_cudart" *: *\{[^}]*"version" *: *"([0-9]*\.[0-9]*).*/)
    if m
      want = m[1]
      break
    end
  end
end
out = or_default(ENV["CUDART_WHEEL_DIR"], "#{or_default(ENV["XDG_CACHE_HOME"], "#{ENV.fetch("HOME")}/.cache")}/nfcxx/cudart-wheel")

rt = fetch("nvidia-cuda-runtime", want, out)
cc = fetch("nvidia-cuda-cccl", want, out)
crt = fetch("nvidia-cuda-crt", want, out)
rt_inc = find_dir(rt, "include")
rt_lib = find_dir(rt, "lib")
cc_inc = find_dir(cc, "include")
unless rt_inc && rt_lib && cc_inc
  warn "fetch-cudart-wheel: include/ or lib/ missing in a wheel"
  exit 1
end

# The CUDA_HOME shape: include/ (runtime headers, with CCCL's cccl/ beside them) and lib64/ (libcudart.so and its .so.N).
home = "#{out}/cuda-home"
FileUtils.rm_rf(home)
FileUtils.mkdir_p("#{home}/lib64")
cp_a!(rt_inc, "#{home}/include")
# crt/ (host_config.h and the device-side headers) ships in its own package.
crt_inc = find_dir(crt, "include")
cp_a!("#{crt_inc}/.", "#{home}/include/") if crt_inc
unless File.exist?("#{home}/include/cccl")
  if File.exist?("#{cc_inc}/cccl") then cp_a!("#{cc_inc}/cccl", "#{home}/include/cccl")
  else cp_a!(cc_inc, "#{home}/include/cccl")
  end
end
# nv/ (the target macros the runtime headers include) is beside cccl/ in the CCCL wheel.
cp_a!("#{cc_inc}/nv", "#{home}/include/nv") if Dir.exist?("#{cc_inc}/nv")
libs = Dir.glob("#{rt_lib}/libcudart.so*").sort
if libs.empty?
  warn "cp: cannot stat '#{rt_lib}/libcudart.so*': No such file or directory"
  exit 1
end
libs.each { |f| cp_a!(f, "#{home}/lib64/") }
so = Dir.children("#{home}/lib64").sort.find { |f| f.match?(/\Alibcudart\.so\.[0-9]+\z/) }
FileUtils.ln_sf(so, "#{home}/lib64/libcudart.so") if so
puts "cuda-home: #{home}"
puts "runtime: #{File.basename(rt)}"
puts "cccl: #{File.basename(cc)}"
puts "crt: #{File.basename(crt)}"
