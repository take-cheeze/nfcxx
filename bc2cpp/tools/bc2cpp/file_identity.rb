# frozen_string_literal: true

# FILE_IDENTITY: the [path, mtime, size] stat key that the source scans (ForeignDefiners, OutsideRubyOwners,
# NativeCoreDirect.audit) validate their memos with. As a library every call stats afresh, so a check that rewrites a
# fixture between calls is seen. The bc2cpp command line calls `sources_fixed!` first: within one compile the sources
# it reads do not change, so each list's key is computed once per process instead of on every scan.
module FileIdentity
  @fixed = false
  @memo = {}

  module_function

  def sources_fixed!
    @fixed = true
  end

  # [existing files among `paths`, their stat key].
  def files_and_key(paths)
    cached(:files_and_key, paths) do
      files = Array(paths).select { |path| File.file?(path) }.freeze
      [files, files.map { |path| path_key(path) }.freeze]
    end
  end

  def path_key(path)
    stat = File.stat(path)
    [path, stat.mtime, stat.size]
  end

  # The block's value for `paths`, memoized under `kind` only while the sources are fixed.
  def cached(kind, paths, &block)
    return block.call unless @fixed

    table = (@memo[kind] ||= {})
    table.fetch(paths) { table[Array(paths).dup.freeze] = block.call }
  end
end
