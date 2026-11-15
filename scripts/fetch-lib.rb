# frozen_string_literal: true

# Shared by scripts/fetch-cuda-libs.rb and scripts/fetch-cudart-wheel.rb, the Ruby ports of the bash scripts whose originals
# are in tests/fetch/oracle/: PyPI's JSON API, the wheel downloads (sha256 checked), the extraction (unzip) and the cp
# semantics the bash relied on for the modes of the CUDA_HOME tree (cp -r and cp -a). Stdlib only.
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'net/http'
require 'open3'
require 'uri'

module FetchLib
  class Error < StandardError; end

  module_function

  # An empty value is unset, as in the bash ${VAR:-default}.
  def present(value)
    value.nil? || value.empty? ? nil : value
  end

  # NFCXX_PYPI_URL replaces https://pypi.org; tests/fetch/run.sh points it at a local stub.
  def pypi_base
    present(ENV['NFCXX_PYPI_URL']) || 'https://pypi.org'
  end

  # PyPI's JSON API for a project, or for one release of it (its files are then under 'urls').
  def pypi_json(project, version = nil)
    path = version ? "#{project}/#{version}/json" : "#{project}/json"
    JSON.parse(get("#{pypi_base}/pypi/#{path}"))
  end

  def get(url)
    open_url(url) { |res| res.body }
  end

  # Yields the 2xx response of a GET. Redirects are followed (curl -L); any other status is an error (curl -f).
  def open_url(url, redirects = 5, &block)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.request(Net::HTTP::Get.new(uri)) do |res|
        if res.is_a?(Net::HTTPRedirection) && redirects.positive?
          return open_url(URI.join(url, res['location']).to_s, redirects - 1, &block)
        end
        raise Error, "#{url}: #{res.code} #{res.message}" unless res.is_a?(Net::HTTPSuccess)

        return block.call(res)
      end
    end
  end

  # curl -sSfL URL -o PATH: the file is written beside PATH and renamed when complete, so PATH never holds a partial file.
  def download(url, path)
    part = "#{path}.part"
    open_url(url) { |res| File.open(part, 'wb') { |f| res.read_body { |chunk| f.write(chunk) } } }
    File.rename(part, path)
  rescue StandardError
    FileUtils.rm_f(part)
    raise
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  # unzip -oq WHEEL -d DIR (the extractor of the bash cuda-libs script; it restores the zip's file modes).
  def unzip(wheel, dir)
    _out, err, status = Open3.capture3('unzip', '-oq', wheel, '-d', dir)
    raise Error, "unzip #{File.basename(wheel)}: #{err.strip}" unless status.success?
  end

  # Python's zipfile (the extractor of the bash cudart script) creates each file as 0666 minus the umask and never restores
  # the zip's modes. The port sets the same modes after unzip, so the two trees agree.
  def zipfile_modes(dir)
    mode = 0o666 & ~File.umask
    Find.find(dir) { |p| File.chmod(mode, p) if File.file?(p) && !File.symlink?(p) }
  end

  # cp SRC DIR/ for one file: follows a symlink, and the new file gets SRC's mode minus the umask.
  def copy_into(src, dir)
    dst = File.join(dir, File.basename(src))
    File.open(src, 'rb') { |i| File.open(dst, 'wb', File.stat(src).mode & 0o7777) { |o| IO.copy_stream(i, o) } }
  end

  # cp -a SRC DST: DST, or SRC inside DST when DST is a directory.
  def copy_a(src, dst)
    dst = File.join(dst, File.basename(src)) if File.directory?(dst)
    copy_entry(src, dst, preserve: true)
  end

  # cp -r SRC/. DST/ (preserve: false) or cp -a SRC/. DST/: the children of SRC are merged into DST, which is made if missing.
  def copy_contents(src, dst, preserve: false)
    FileUtils.mkdir_p(dst)
    Dir.children(src).sort.each { |name| copy_entry(File.join(src, name), File.join(dst, name), preserve: preserve) }
  end

  # One entry of cp -r (preserve: false: a new entry gets SRC's mode minus the umask) or cp -a (preserve: true: SRC's mode).
  def copy_entry(src, dst, preserve:)
    st = File.lstat(src)
    if st.symlink?
      File.symlink(File.readlink(src), dst)
    elsif st.directory?
      Dir.mkdir(dst, st.mode & 0o7777) unless File.directory?(dst)
      copy_contents(src, dst, preserve: preserve)
      File.chmod(st.mode & 0o7777, dst) if preserve
    else
      File.open(src, 'rb') { |i| File.open(dst, 'wb', st.mode & 0o7777) { |o| IO.copy_stream(i, o) } }
      File.chmod(st.mode & 0o7777, dst) if preserve
    end
  end
end
