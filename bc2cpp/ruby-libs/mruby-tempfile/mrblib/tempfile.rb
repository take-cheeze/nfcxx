# Tempfile: a file in the temporary directory that Tempfile.create removes after its block, and Tempfile.new
# returns for the caller to close and unlink. Names are prefix plus a random string plus suffix.
class Tempfile
  def path
    @path
  end

  def self.create(basename = "", tmpdir = nil)
    path = Tempfile.make_path(basename, tmpdir)
    file = File.open(path, "w+")
    return file unless block_given?

    begin
      yield file
    ensure
      file.close unless file.closed?
      File.delete(path) if File.exist?(path)
    end
  end

  def self.new(basename = "", tmpdir = nil)
    allocate.tap { |temp| temp.send(:setup, basename, tmpdir) }
  end

  def self.make_path(basename, tmpdir)
    prefix, suffix = basename.is_a?(Array) ? basename : [basename, ""]
    dir = tmpdir || Dir.tmpdir
    20.times do
      candidate = File.join(dir, "#{prefix}#{Time.now.to_i}-#{rand(0x100000000).to_s(36)}#{suffix}")
      return candidate unless File.exist?(candidate)
    end
    raise "Tempfile: could not find a free name in #{dir}"
  end

  # mruby-io has no File#binmode. On POSIX binary and text mode are the same, so this only records the request.
  def binmode
    @binmode = true
    self
  end

  def write(data)
    @file.write(data)
  end

  def read
    @file.read
  end

  def rewind
    @file.rewind
  end

  def flush
    @file.flush
    self
  end

  def close
    @file.close
    nil
  end

  def closed?
    @file.closed?
  end

  def unlink
    File.delete(@path) if @path && File.exist?(@path)
    @path = nil
    nil
  end

  def close!
    close
    unlink
  end

  private

  def setup(basename, tmpdir)
    @path = Tempfile.make_path(basename, tmpdir)
    @file = File.open(@path, "w+")
  end
end

MRubyRequire.provide('tempfile') { defined?(Tempfile) } if defined?(MRubyRequire)
