#!/usr/bin/env ruby
# nfcxx's cache configuration (docs/notes/driver-body-port.md), the lines at the top of the driver that the bash had as
#   cache_dir=${NFCXX_CACHE:-}; cache_log_file=${NFCXX_CACHE_LOG:-}         # --cache=DIR, --cache-log=FILE
#   cache_remote=${NFCXX_CACHE_REMOTE:-}
#   case $cache_remote in ""|gha) ;; *) echo "nfcxx: NFCXX_CACHE_REMOTE takes gha (got '$cache_remote')" >&2; exit 2 ;; esac
#   [ -n "$cache_dir" ] || [ -z "$cache_remote" ] || cache_dir=${TMPDIR:-/tmp}/nfcxx-cache-$(id -u)
# An empty variable counts as unset, as ${VAR:-...} makes it. Checked against the bash verbatim by tests/driver-cacheconfig/run.sh.
#
#   ruby scripts/nfcxx-cache-config.rb plan    prints the assignments of cache_dir, cache_log_file and cache_remote (for eval),
#                                              status 0; or, for a NFCXX_CACHE_REMOTE other than gha, prints the refusal to standard
#                                              error and exits 2 (nothing on standard output)
module NfcxxCacheConfig
  module_function

  # sh_quote: a shell word that eval gives back as the same string (the same quoting as scripts/cil-link.rb)
  def sh_quote(s)
    "'" + s.gsub("'") { "'\\''" } + "'"
  end

  # returns [assignments, refusal]: refusal is the message for standard error when the remote is not one this driver knows
  def plan(env, euid)
    cache_dir = env["NFCXX_CACHE"].to_s
    cache_log_file = env["NFCXX_CACHE_LOG"].to_s
    cache_remote = env["NFCXX_CACHE_REMOTE"].to_s
    unless cache_remote.empty? || cache_remote == "gha"
      return [nil, "nfcxx: NFCXX_CACHE_REMOTE takes gha (got '#{cache_remote}')"]
    end
    # the local side is a temporary directory when only the remote is asked for
    if cache_dir.empty? && !cache_remote.empty?
      tmp = env["TMPDIR"].to_s
      tmp = "/tmp" if tmp.empty?
      cache_dir = "#{tmp}/nfcxx-cache-#{euid}"
    end
    lines = [
      "cache_dir=#{sh_quote(cache_dir)}",
      "cache_log_file=#{sh_quote(cache_log_file)}",
      "cache_remote=#{sh_quote(cache_remote)}",
    ]
    [lines.join("\n") + "\n", nil]
  end
end

if $PROGRAM_NAME == __FILE__
  abort "nfcxx-cache-config: plan (got #{ARGV.first.inspect})" unless ARGV == ["plan"]
  # id -u is the effective user id
  out, refusal = NfcxxCacheConfig.plan(ENV, Process.euid)
  if refusal
    warn refusal
    exit 2
  end
  print out
end
