# Helpers for the setup scripts ported from bash (scripts/setup-*.rb). The commands run as the bash ran them: the same argv,
# in the same order, with no shell. A failing `must` command ends the script with its status (set -e); `capture` is
# $(...); with_tmp is `tmp=$(mktemp -d)` with trap 'rm -rf "$tmp"' EXIT.
module SetupCommon
  module_function

  # The repository root of a script in the scripts directory: $(cd "$(dirname "$0")/.." && pwd)
  def root_of(file)
    File.expand_path("..", File.dirname(File.expand_path(file)))
  end

  # ${NAME:-default}: the default when NAME is unset or empty
  def env_or(name, default)
    value = ENV[name].to_s
    value.empty? ? default : value
  end

  # Runs argv (a leading Hash sets environment variables, nil unsets one) and returns its Process::Status
  def run(*argv, **opts)
    system(*argv, **opts)
    $?
  end

  # The exit status a shell reports for a child process status
  def status_of(status)
    status.exitstatus || 128 + status.termsig
  end

  # A command of set -e: a failure ends the script with its status
  def must(*argv, **opts)
    status = run(*argv, **opts)
    exit(status_of(status)) unless status.success?
    status
  end

  # $(...): the stdout of argv (not trailing-newline-trimmed) and its status
  def capture(*argv, **opts)
    io = IO.popen(argv, **opts)
    out = io.read
    io.close
    [out, $?]
  end

  # $(...) of a command that must succeed
  def capture!(*argv, **opts)
    out, status = capture(*argv, **opts)
    exit(status_of(status)) unless status.success?
    out
  end

  # The text of $(...): the trailing newlines removed
  def chomp_all(text)
    text.sub(/\n+\z/, "")
  end

  # $(cat FILE 2>/dev/null)
  def read_or_empty(path)
    File.read(path)
  rescue SystemCallError
    ""
  end

  # tmp=$(mktemp -d), removed when the block ends (trap 'rm -rf "$tmp"' EXIT)
  def with_tmp
    tmp = chomp_all(capture!("mktemp", "-d"))
    yield tmp
  ensure
    run("rm", "-rf", tmp) if tmp
  end

  # command -v NAME, for a command on PATH
  def command?(name)
    ENV.fetch("PATH", "").split(":").any? do |dir|
      File.executable?("#{dir}/#{name}") && !File.directory?("#{dir}/#{name}")
    end
  end

  # echo MESSAGE >&2; exit STATUS
  def die(message, status = 1)
    $stderr.puts message
    exit status
  end
end
