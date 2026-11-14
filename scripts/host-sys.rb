# The host C and C++ library discovery of scripts/host-sys.sh, ported to Ruby (a module for the Ruby scripts that the bash
# ones source it for): abs_path, host_dialect, host_clang_version, host_gnu_version and host_sys_includes, with the same
# probes and the same values.
require "open3"

module HostSys
  module_function

  # abs_path PATH: the absolute path of PATH, which need not exist (what realpath -m does)
  def abs_path(path)
    dir = File.dirname(path)
    base = File.basename(path)
    return path unless File.directory?(dir)

    "#{File.realpath(dir)}/#{base}"
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
