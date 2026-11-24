# The host C and C++ library discovery, ported to Ruby from the bash host-sys.sh (its original is tests/host-sys/oracle.sh):
# abs_path, host_dialect, host_clang_version, host_gnu_version, host_qbe_target and host_sys_includes, with the same probes
# and the same values. A module for the Ruby scripts; the bash scripts call its command line (see the end of this file).
# tests/host-sys/run.sh is the differential test.
require "open3"

module HostSys
  module_function

  # abs_path PATH: the absolute path of PATH, which need not exist (what realpath -m does)
  # a directory that exists without search permission is not entered (bash's cd fails), so the path is returned as it is
  def abs_path(path)
    dir = File.dirname(path)
    base = File.basename(path)
    return path unless File.directory?(dir) && File.executable?(dir)

    "#{File.realpath(dir)}/#{base}"
  rescue SystemCallError
    path
  end

  # the host C++ compiler (NFCXX_CXX, default g++)
  def cxx
    ENV["NFCXX_CXX"].to_s.empty? ? "g++" : ENV["NFCXX_CXX"]
  end

  # the first line of a command's --version (empty when it cannot run)
  def version_line(cmd)
    out, _err, _st = Open3.capture3(cmd, "--version")
    out.lines.first.to_s.chomp
  rescue SystemCallError
    ""
  end

  def dialect
    version_line(cxx).match?(/clang/i) ? "clang" : "g++"
  end

  # --clang_version value (major*10000 + minor*100 + patch, capped at 20.0.0) or nil
  def clang_version
    ver = version_line(cxx)[/version ([0-9][0-9.]*)/, 1]
    return nil if ver.nil? || ver.empty?

    maj, min, pat = ver.split(".")
    v = maj.to_i * 10000 + min.to_i * 100 + pat.to_i
    v = 200000 if v > 200000
    v.to_s
  end

  # --gnu_version value (major*10000 + minor*100 + patch of -dumpfullversion), 150000 for clang without a version, or nil
  def gnu_version
    ver = begin
      out, _err, st = Open3.capture3(cxx, "-dumpfullversion")
      st.success? ? out.chomp : ""
    rescue SystemCallError
      ""
    end
    return "150000" if ver.empty? && dialect == "clang"
    return nil if ver.empty?

    maj, min, pat = ver.split(".")
    (maj.to_i * 10000 + min.to_i * 100 + pat.to_i).to_s
  end

  # host_qbe_target: QBE's default target for this host (arm64_apple, arm64, amd64_apple or amd64_sysv)
  def qbe_target
    m = IO.popen(["uname", "-m"], &:read).chomp
    s = IO.popen(["uname", "-s"], &:read).chomp
    case m
    when "arm64", "aarch64" then s == "Darwin" ? "arm64_apple" : "arm64"
    else s == "Darwin" ? "amd64_apple" : "amd64_sysv"
    end
  end

  # the include directories of the host compiler's search list, one per entry (NFCXX_SYS_INCLUDES overrides them)
  def sys_includes(lang = "c++")
    if !ENV["NFCXX_SYS_INCLUDES"].to_s.empty?
      return ENV["NFCXX_SYS_INCLUDES"].split(":", -1)
    end

    cmd = lang == "c" ? (ENV["NFCXX_CC"].to_s.empty? ? "gcc" : ENV["NFCXX_CC"]) : cxx
    _out, err, _st = Open3.capture3(cmd, "-E", "-x", lang, "-v", "-", stdin_data: "")
    dirs = []
    on = false
    err.each_line do |l|
      if l.include?("search starts here:") then on = true
      elsif l.include?("End of search list") then on = false
      elsif on && !l.include?("framework directory")
        dirs << (l.start_with?(" ") ? l.sub(/\A +/, "").chomp : l.chomp)
      end
    end
    dirs
  rescue SystemCallError
    []
  end
end

# The command line the bash scripts call (one function per run, the bash name and arguments):
#   ruby scripts/host-sys.rb host_dialect | host_clang_version | host_gnu_version | host_qbe_target
#   ruby scripts/host-sys.rb host_sys_includes [c]      one directory per line
#   ruby scripts/host-sys.rb abs_path PATH
if $PROGRAM_NAME == __FILE__
  fn, *args = ARGV
  case fn
  when "abs_path"
    puts HostSys.abs_path(args.fetch(0) { abort "host-sys: abs_path needs a path" })
  when "host_dialect"
    puts HostSys.dialect
  when "host_clang_version"
    v = HostSys.clang_version
    puts v if v
  when "host_gnu_version"
    v = HostSys.gnu_version
    puts v if v
  when "host_qbe_target"
    puts HostSys.qbe_target
  when "host_sys_includes"
    HostSys.sys_includes(args.fetch(0, "c++")).each { |d| puts d }
  else
    abort "host-sys: unknown function #{fn.inspect}"
  end
end
