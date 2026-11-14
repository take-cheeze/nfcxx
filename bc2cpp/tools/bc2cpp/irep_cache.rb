# frozen_string_literal: true

require_relative 'world_root'
require_relative 'scan_cache'
require_relative 'toolchain'
require 'digest'
require 'fileutils'
require 'tempfile'

module IrepCache
  module_function

  # The decoder's sources and its toolchain. The decode follows require_relative chains (insn_decoder.rb loads
  # bytecode_ir_ops.rb, for one), so the fingerprint is ScanCache's digest of every tool source, not a list of files.
  def fingerprint
    @fingerprint ||= Digest::SHA256.hexdigest([ScanCache.tools_digest, *Toolchain.versions].join("\0"))
  end

  # Temporary fixture filenames make unique RITE images, so retaining their trees adds work without reuse.
  def directory_for_sources(paths)
    dir = ENV['BC2CPP_IREP_CACHE_DIR']
    root = BC2CPP_WORLD_ROOT
    dir if dir && !dir.empty? && Array(paths).all? { |path| File.expand_path(path).start_with?("#{root}/") }
  end

  # Only the decoded tree is shared; each hit restores private mutable objects.
  def fetch(bytes, dir)
    FileUtils.mkdir_p(dir)
    key = Digest::SHA256.hexdigest(Marshal.dump([fingerprint, RUBY_ENGINE, RUBY_VERSION, RUBY_PLATFORM,
                                               Marshal::MAJOR_VERSION, Marshal::MINOR_VERSION,
                                               InsnDecoder.fold_ext_prefix?, bytes]))
    path = File.join(dir, "#{key}.marshal")
    cached = read_snapshot(path)
    return cached if cached

    File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
      raise "bc2cpp: cannot lock decoded tree #{path}" unless lock.flock(File::LOCK_EX)

      cached = read_snapshot(path)
      return cached if cached

      result = yield
      temporary = Tempfile.new(['decoded-tree-', '.marshal'], dir)
      begin
        temporary.binmode
        snapshot = Marshal.dump(result)
        temporary.write("#{Digest::SHA256.hexdigest(snapshot)}\n")
        temporary.write(snapshot)
        temporary.close
        File.rename(temporary.path, path)
      ensure
        temporary.close!
      end
      result
    end
  end
  def read_snapshot(path)
    return nil unless File.exist?(path)

    checksum, snapshot = File.binread(path).split("\n", 2)
    raise ArgumentError, 'snapshot checksum mismatch' unless snapshot && Digest::SHA256.hexdigest(snapshot) == checksum

    result = Marshal.load(snapshot)
    raise TypeError, 'invalid decoded tree' unless result.is_a?(Array) && result.size == 2 && result[0].is_a?(Hash)

    result[0].each_value do |irep|
      # Marshal restores containers unfrozen; decoded operand lists remain read-only.
      BytecodeIR.for(irep).each_source do |insn, _index|
        operands = insn.typed
        operands.each(&:deduplicate_name!)
        insn.typed = operands
      end
    end
    result
  rescue ArgumentError, TypeError, EOFError, Errno::ENOENT => e
    warn "[bc2cpp] decoded-tree cache #{path}: #{e.message}; rebuilding"
    nil
  end

end
