# frozen_string_literal: true

require_relative 'world_root'
require_relative 'scan_cache'
require_relative 'toolchain'
require 'digest'
require 'set'
require 'fileutils'

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

  # The outside sources an analysis-only compile reads (CoreDefs.outside_compile) are the same few files every run, and
  # their decode was a fifth of a small self-compiled run: their trees are kept in ScanCache's directory unless
  # BC2CPP_IREP_CACHE_DIR names one. Those paths are the tree's and the world's own sources, never temporary fixtures.
  def analysis_directory(paths)
    dir = directory_for_sources(paths)
    return dir if dir
    return nil unless marshal_round_trips?

    (cache = ScanCache.directory) && File.join(cache, 'ireps')
  end

  # A self-compiled bc2cpp's Marshal is mruby-marshal's. Before it numbered a marshal_dump object (a Set) ahead of
  # its data and wrote an Integer past 31 bits (an object_id) as a bignum, a decoded tree did not load back, and its
  # dump took minutes; the same fixes made it fast. Without them the tree is decoded each run, as before.
  def marshal_round_trips?
    return true unless RUBY_ENGINE == 'mruby'
    return @marshal_round_trips unless @marshal_round_trips.nil?

    @marshal_round_trips = begin
      shared = +'shared'
      wide = 2**40
      back = Marshal.load(Marshal.dump([Set[shared], shared, wide]))
      back[1].equal?(back[0].to_a.first) && back[2] == wide
    rescue StandardError
      false
    end
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
      # A unique name and a rename, as ScanCache stores an entry: a self-compiled bc2cpp's Tempfile raised "closed
      # stream" from close! after the close above, so a cold run learned nothing from the outside sources.
      snapshot = Marshal.dump(result)
      temporary = "#{path}.#{Process.pid}.#{rand(0x1_0000_0000)}.tmp"
      begin
        File.binwrite(temporary, "#{Digest::SHA256.hexdigest(snapshot)}\n#{snapshot}")
        File.rename(temporary, path)
      ensure
        FileUtils.rm_f(temporary)
      end
      prune(dir, path)
      result
    end
  end
  # A tree is some 12 MB and every tool change keys a new one, so a directory keeps the KEEP newest besides the one
  # just written. A reader that loses the race finds no file and decodes again.
  KEEP = 4

  def prune(dir, written)
    trees = Dir[File.join(dir, '*.marshal')].reject { |tree| tree == written }
    # File.stat, as ScanCache reads a file's time: a self-compiled bc2cpp's File has no File.mtime.
    trees.sort_by { |tree| -File.stat(tree).mtime.to_i }.drop(KEEP).each do |stale|
      FileUtils.rm_f([stale, "#{stale}.lock"])
    end
  rescue StandardError
    # Pruning only saves disk; a failure must not fail the decode it follows.
    nil
  end

  def read_snapshot(path)
    return nil unless File.exist?(path)

    checksum, snapshot = File.binread(path).split("\n", 2)
    raise ArgumentError, 'snapshot checksum mismatch' unless snapshot && Digest::SHA256.hexdigest(snapshot) == checksum

    result = Marshal.load(snapshot)
    raise TypeError, 'invalid decoded tree' unless result.is_a?(Array) && result.size == 2 && result[0].is_a?(Hash)

    result[0].each_value do |irep|
      # Marshal restores containers unfrozen; decoded operand lists remain read-only. The instruction's kind
      # positions were marshaled with its operands and depend only on their kinds, which deduplicate_name! keeps,
      # so freezing in place is the whole fixup (installing the list again recomputed them for every instruction).
      BytecodeIR.for(irep).each_source do |insn, _index|
        operands = insn.typed
        operands.each(&:deduplicate_name!)
        operands.freeze
      end
    end
    result
  rescue ArgumentError, TypeError, EOFError, Errno::ENOENT => e
    warn "[bc2cpp] decoded-tree cache #{path}: #{e.message}; rebuilding"
    nil
  end

end
