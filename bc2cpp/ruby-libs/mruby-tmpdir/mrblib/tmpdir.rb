# Dir.mktmpdir and Dir.tmpdir for the generator. Dir.tmpdir is /tmp: the environment variable TMPDIR is not read
# until the mruby-env gem exists in this build.
class Dir
  def self.tmpdir
    "/tmp"
  end

  # Makes a new directory under tmpdir with a random name. With a block, yields its path and removes the
  # directory afterwards; without one, returns the path and the caller removes it.
  def self.mktmpdir(prefix = "d")
    path = nil
    while path.nil?
      candidate = File.join(tmpdir, "#{prefix}#{rand(0x100000000).to_s(36)}")
      next if File.exist?(candidate)

      Dir.mkdir(candidate)
      path = candidate
    end
    return path unless block_given?

    begin
      yield path
    ensure
      FileUtils.rm_rf(path)
    end
  end
end

MRubyRequire.provide('tmpdir') { defined?(Dir.mktmpdir) } if defined?(MRubyRequire)
