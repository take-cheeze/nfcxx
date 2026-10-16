# frozen_string_literal: true

require 'digest'
require 'fileutils'

# A disk memo of the scans that read only the outside-world sources (mruby C and gem C/C++), ADR 0415 and ADR 0462.
# Every generator run starts a new process and repeats those scans over the same files, so the result of a scan is
# stored under a digest of everything it reads and is loaded instead of recomputed. It is always on, with no
# environment switch: the entries live in DEFAULT_DIR (the repository's own git-ignored build/ directory). A check
# that needs its own directory sets ScanCache.directory_override from Ruby.
#
# The key covers the scan's name, the digest of every tools/bc2cpp source (so a changed or mutated scanner never sees
# an older result), the Ruby version and Marshal format, and the digest of each input file. An input that does not
# exist is part of the key too (a scan that skips it gives the same answer every time), unless the scan reports it:
# those pass cache_absent: false and are computed.
#
# A miss computes and stores. Anything else that goes wrong is a hard failure (ScanCache::Error): an entry that does not
# load, an entry whose stored key is not the key it was read under, a value that cannot be stored, a directory that
# cannot be written. None of them is papered over by recomputing.
#
# Entries are Marshal dumps, so the cache directory must be one only this user writes.
module ScanCache
  VERSION = 2
  DEFAULT_DIR = File.expand_path('../../build/bc2cpp-cache', __dir__)
  MAGIC = 'bc2cpp-scan-cache'

  class Error < RuntimeError; end

  # The key holds no environment because a cached scan may not read any: ENV read while a scan computes is an Error.
  # (ADR 0415 rule 2, enforced.)
  module EnvGuard
    %i[[] fetch key? has_key? include? member? assoc values_at slice to_h to_hash each each_pair select filter reject
       filter_map map keys values].each do |name|
      define_method(name) do |*args, **opts, &block|
        if ScanCache.computing.positive?
          raise Error, "bc2cpp: a cached scan read ENV.#{name}(#{args.map(&:inspect).join(', ')}); its key holds no " \
                       'environment, so it may not read one'
        end
        super(*args, **opts, &block)
      end
    end
  end

  # An in-process memo with the same keys (ADR 0416). WarmGenerator's server fills it before it forks, so every
  # forked generation finds the scans in memory. nil (the default) leaves it off.
  class << self
    attr_accessor :memory, :directory_override

    # The checks' Ruby-level switch: inside the block every scan is computed and nothing is read or written.
    def bypass
      saved = @bypass
      @bypass = true
      yield
    ensure
      @bypass = saved
    end

    def bypassed? = @bypass == true

    # How many cached scans are computing in this process (nested scans count once each).
    def computing = @computing || 0

    def compute
      ENV.singleton_class.prepend(EnvGuard) unless ENV.singleton_class.include?(EnvGuard)
      @computing = computing + 1
      yield
    ensure
      @computing -= 1
    end
  end

  module_function

  def directory
    return nil if ScanCache.bypassed?

    ScanCache.directory_override || DEFAULT_DIR
  end

  # The value of the scan `name` over `inputs` (file paths, in the order it reads them): the stored one when the
  # key is known, else the block's, which is stored for the next process.
  def fetch(name, inputs, cache_absent: true)
    dir = directory
    memo = ScanCache.bypassed? ? nil : memory
    return yield unless dir || memo

    key = key_for(name, inputs, cache_absent)
    return yield unless key

    return memo.fetch(key) if memo&.key?(key)

    value = dir ? fetch_entry(dir, name, key) { ScanCache.compute { yield } } : ScanCache.compute { yield }
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
    digest << "#{VERSION}\0#{RUBY_VERSION}\0#{RUBY_PLATFORM}\0#{Marshal::MAJOR_VERSION}.#{Marshal::MINOR_VERSION}\0"
    digest << "#{name}\0#{tools_digest}\0"
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

  # [value] for a stored entry, nil for none (a miss). An entry that does not load, or that was stored under another
  # key, is an Error.
  def load_entry(path)
    return nil unless File.file?(path)

    key = File.basename(path, '.bin').split('-').last
    begin
      magic, stored_key, value = Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad
    rescue TypeError, ArgumentError, EOFError, NoMethodError => e
      raise Error, "bc2cpp: scan cache entry #{path} is unreadable (#{e.class}: #{e.message}); delete it and find out what wrote it"
    end
    unless magic == MAGIC && stored_key == key
      raise Error, "bc2cpp: scan cache entry #{path} was stored under key #{stored_key.inspect}, not #{key}"
    end

    [value]
  end

  # Written to a private name and renamed, so a concurrent reader sees a whole entry or none. A value that cannot be
  # dumped, or a directory that cannot be written, is an Error.
  def store_entry(dir, path, value)
    key = File.basename(path, '.bin').split('-').last
    begin
      FileUtils.mkdir_p(dir)
      temp = "#{path}.#{Process.pid}.#{rand(0x1_0000_0000)}.tmp"
      File.binwrite(temp, Marshal.dump([MAGIC, key, value]))
      File.rename(temp, path)
    rescue SystemCallError, TypeError => e
      FileUtils.rm_f(temp) if temp
      raise Error, "bc2cpp: scan cache entry #{path} could not be stored (#{e.class}: #{e.message})"
    end
  end
end
