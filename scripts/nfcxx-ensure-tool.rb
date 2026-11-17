#!/usr/bin/env ruby
# nfcxx's ensure_tool (the driver's build of a repo C++ tool on first use, docs/notes/driver-body-port.md): OUT is built by ninja in
# DIR when it is missing, or older than a source file of DIR (the top-level .c, .cpp, .h, .hpp, .inc and .rb files). The driver runs
# in parallel (one process per source file), so the build is serialized by the lock directory OUT.lock: the first run builds, the
# others wait and find OUT (a wait of 3000 polls of 0.2 s is an error that names the lock). ninja's output goes to standard error;
# a failed build gives its status. tests/driver-ensure-tool/run.sh checks the port against the bash function verbatim.
#
#   ruby scripts/nfcxx-ensure-tool.rb DIR OUT      status 0, or the build's status, 1 when the lock is stuck

module NfcxxEnsureTool
  module_function

  SOURCES = %w[*.c *.cpp *.h *.hpp *.inc *.rb].freeze   # find -maxdepth 1 -type f -name, as the bash had it
  POLLS = 3000

  # tool_fresh: OUT is an executable file, and no source of DIR is newer than it
  def fresh?(dir, out)
    return false unless File.file?(out) && File.executable?(out)

    mtime = File.mtime(out)
    sources(dir).none? { |path| File.mtime(path) > mtime }
  end

  def sources(dir)
    Dir.children(dir).map { |n| File.join(dir, n) }
       .select { |p| File.file?(p) && SOURCES.any? { |pat| File.fnmatch?(pat, File.basename(p)) } }
  rescue SystemCallError
    []
  end

  def cxx
    value = ENV["NFCXX_CXX"]
    value.nil? || value.empty? ? "g++" : value
  end

  def ensure_tool(dir, out)
    return 0 if fresh?(dir, out)

    require "fileutils"
    FileUtils.mkdir_p(File.dirname(out))
    lock = "#{out}.lock"
    waited = 0
    until mkdir_lock(lock)
      return 0 if fresh?(dir, out)

      sleep 0.2
      waited += 1
      next if waited < POLLS

      warn "nfcxx: #{lock} is stuck (remove it if no build is running)"
      return 1
    end
    begin
      return 0 if fresh?(dir, out)

      _, status = Process.wait2(Process.spawn({ "CXX" => cxx }, "ninja", "-C", dir, err: $stderr, out: $stderr))
      status.success? ? 0 : (status.exitstatus || 1)
    rescue SystemCallError
      127
    ensure
      Dir.rmdir(lock)
    end
  end

  def mkdir_lock(lock)
    Dir.mkdir(lock)
    true
  rescue Errno::EEXIST
    false
  end
end

if $PROGRAM_NAME == __FILE__
  abort "nfcxx-ensure-tool: DIR OUT" unless ARGV.size == 2
  exit NfcxxEnsureTool.ensure_tool(ARGV[0], ARGV[1])
end
