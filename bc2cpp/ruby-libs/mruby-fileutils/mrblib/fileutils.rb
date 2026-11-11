# FileUtils: the operations bc2cpp uses (mkdir_p, rm_f, rm_rf, remove_entry), on mruby-io and mruby-dir.
module FileUtils
  # Creates the directory and its parents; returns the path.
  def self.mkdir_p(path)
    path = path.to_s
    return path if Dir.exist?(path)

    parent = File.dirname(path)
    mkdir_p(parent) unless parent == path
    Dir.mkdir(path) unless Dir.exist?(path)
    path
  end

  # Deletes a file if it exists; a missing file is not an error.
  def self.rm_f(path)
    File.delete(path) if File.exist?(path)
    path
  end

  # Deletes a file or a directory tree; a missing path raises, as in CRuby's remove_entry.
  def self.remove_entry(path)
    if File.directory?(path)
      Dir.entries(path).each do |name|
        next if name == "." || name == ".."

        remove_entry(File.join(path, name))
      end
      Dir.rmdir(path)
    else
      File.delete(path)
    end
    path
  end

  # Like remove_entry, but a missing path is not an error.
  def self.rm_rf(path)
    remove_entry(path) if File.exist?(path)
    path
  end
end

MRubyRequire.provide('fileutils') { defined?(FileUtils) } if defined?(MRubyRequire)
