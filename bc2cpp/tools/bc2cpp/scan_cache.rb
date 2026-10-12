# frozen_string_literal: true

require 'digest'
require 'fileutils'

# A disk memo of the scans that read only the outside-world sources (mruby C and gem C/C++), ADR 0415. Every
# closed-world generator run starts a new process and repeats those scans over the same files; with
# BC2CPP_SCAN_CACHE_DIR set, the result of a scan is stored under a digest of everything it reads and is
# loaded instead of recomputed. Without the variable nothing is read or written.
#
# The key covers the scan's name, the digest of every tools/bc2cpp source (so a changed or mutated scanner
# never sees an older result), and the digest of each input file. An input that does not exist is part of
# the key too (a scan that skips it gives the same answer every time), unless the scan reports it: those
# pass cache_absent: false and are computed.
#
# Entries are Marshal dumps, so BC2CPP_SCAN_CACHE_DIR must be a directory only this user writes.
module ScanCache
  VERSION = 1
  ENV_NAME = 'BC2CPP_SCAN_CACHE_DIR'

  # An in-process memo with the same keys (ADR 0416). WarmGenerator's server fills it before it forks, so every
  # forked generation finds the scans in memory. nil (the default) leaves it off.
  class << self
    attr_accessor :memory
  end

  module_function

  def directory
    dir = ENV.fetch(ENV_NAME, nil)
    dir unless dir.nil? || dir.empty?
  end

  # The value of the scan `name` over `inputs` (file paths, in the order it reads them): the stored one when the
  # key is known, else the block's, which is stored for the next process.
  def fetch(name, inputs, cache_absent: true)
    dir = directory
    memo = memory
    return yield unless dir || memo

    key = key_for(name, inputs, cache_absent)
    return yield unless key

    return memo.fetch(key) if memo&.key?(key)

    value = dir ? fetch_entry(dir, name, key) { yield } : yield
    memo[key] = value if memo
    value
  end

  def fetch_entry(dir, name, key)
    path = File.join(dir, "#{name}-#{key}.bin")
    stored = load_entry(path)
    return stored.first if stored

    value = yield
    store_entry(dir, path, value)
    value
  end

  # nil when the scan cannot be keyed (an input is a directory, or is absent and the scan reports that).
  def key_for(name, inputs, cache_absent)
    digest = Digest::SHA256.new
    digest << "#{VERSION}\0#{name}\0#{tools_digest}\0"
    Array(inputs).each do |input|
      digest << "#{input}\0"
      if File.file?(input)
        digest << file_digest(input)
      elsif !File.exist?(input) && cache_absent
        digest << 'absent'
      else
        return nil
      end
    end
    digest.hexdigest
  end

  # One process hashes a file once (the scans share most of their inputs), keyed by file identity.
  def file_digest(path)
    stat = File.stat(path)
    (@file_digests ||= {})[[path, stat.mtime, stat.size]] ||= Digest::SHA256.file(path).digest
  end

  def tools_digest
    @tools_digest ||= begin
      digest = Digest::SHA256.new
      Dir[File.join(__dir__, '*.rb')].sort.each do |file|
        digest << "#{File.basename(file)}\0"
        digest << Digest::SHA256.file(file).digest
      end
      digest.hexdigest
    end
  end

  # [value] for a readable entry, nil for none. An entry that cannot be loaded is reported and recomputed.
  def load_entry(path)
    return nil unless File.file?(path)

    [Marshal.load(File.binread(path))] # rubocop:disable Security/MarshalLoad
  rescue TypeError, ArgumentError, EOFError => e
    warn "[bc2cpp] scan cache entry #{path} is unreadable (#{e.class}: #{e.message}); recomputing"
    nil
  end

  # Written to a private name and renamed, so a concurrent reader sees a whole entry or none.
  def store_entry(dir, path, value)
    FileUtils.mkdir_p(dir)
    temp = "#{path}.#{Process.pid}.#{rand(0x1_0000_0000)}.tmp"
    File.binwrite(temp, Marshal.dump(value))
    File.rename(temp, path)
  rescue SystemCallError, TypeError => e
    warn "[bc2cpp] scan cache entry #{path} was not stored (#{e.class}: #{e.message})"
    FileUtils.rm_f(temp) if temp
  end
end
