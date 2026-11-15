#!/usr/bin/env ruby
# The pieces the launcher ports share (scripts/nfcxx-cpp.rb, nfcxx-ast-dump.rb, libclang-cursors.rb and
# build-libclang-edg.rb): the checkout root as the bash scripts compute it, ${VAR:-default}, a child's exit status as a
# shell reports it, realpath(1), and running a child (stdio inherited, or captured with stderr discarded). The host
# probes are scripts/host-sys.rb (HostSys). Originals: tests/launch/oracle/.
require "open3"
require_relative "host-sys"

module Launch
  module_function

  # the checkout root of a script run as FILE: the parent of its directory, with the path as given (no symlink
  # resolution, as bash's cd "$(dirname "$0")/.." && pwd)
  def root_of(file)
    File.expand_path("..", File.dirname(File.expand_path(file)))
  end

  # ${NAME:-default}
  def env_or(name, default)
    v = ENV[name]
    v.nil? || v.empty? ? default : v
  end

  # the status a shell reports for a child: its exit code, or 128 + the signal number
  def status_of(st)
    st.exitstatus || 128 + st.termsig
  end

  # the value of a flag that takes one; a missing value is an error (bash's unbound $2): exit 1
  def value!(rest, flag, name)
    return rest.shift unless rest.empty?

    warn "#{name}: #{flag} needs an argument"
    exit 1
  end

  # realpath(1) of FILE, which must exist; its own message is on stderr when it fails, and we exit with its status
  def realpath!(file)
    out, st = Open3.capture2("realpath", file)
    exit(status_of(st)) unless st.success?
    out.chomp
  end

  # run ARGV with stdio inherited, in DIR when given; returns its status. A DIR that does not exist fails with 1 (bash's
  # cd), a command that cannot run with 127.
  def run(argv, env: {}, dir: nil)
    if dir && !File.directory?(dir)
      warn "cd: #{dir}: No such file or directory"
      return 1
    end
    ok = system(env, *argv, **(dir ? { chdir: dir } : {}))
    if ok.nil?
      warn "#{argv[0]}: No such file or directory"
      return 127
    end

    status_of($?)
  end

  # run ARGV in DIR with its stderr discarded and its stdout returned: [stdout, status]
  def capture(argv, dir: nil, env: {})
    out, st = Open3.capture2(env, *argv, **(dir ? { chdir: dir } : {}), err: File::NULL)
    [out, status_of(st)]
  rescue SystemCallError
    ["", 1]
  end
end
