#!/usr/bin/env ruby
# nfcxx's compile cache, ported from the bash in nfcxx: the records removal before and after a link (link_records_rm, and the
# removal before a compile), cache_lookup (the key), the hit copy, and the store behind the one-step build. Checked against the
# bash by tests/nfcxx-cache/run.sh, which runs nfcxx's own setup and loop with the cache block run and the build and the remote
# helper stubbed (tests/nfcxx-cache/bash-decision.sh).
#
# It prints the decision and the commands the bash would run, in the bash's order:
#   RUN ARGV...           a command the bash runs (rm, mkdir, mv, python3 for the remote helper, build for the one-step build)
#   CP SRC DST            a copy into or out of the cache
#   EXIT 0                a hit: the bash exits after the copy
#   KEY HEX               the cache key (not a bash line: the runner reads it)
#   CAT PATH / BODY / END the --cache-log write: BODY is the text the bash appends to PATH
#
# The loop's state that the cache reads goes on the command line; the environment (NFCXX_CACHE, NFCXX_CACHE_LOG,
# NFCXX_CACHE_REMOTE, TMPDIR, NFCXX_CXX, EDG_BUILD, EDG_BASE, and the NFCXX_* variables the key lists) goes in as --env. The
# NFCXX_* variables are those the setup leaves: the key lists them, and the setup exports some (NFCXX_CC for --backend=gcc,
# NFCXX_SYSTEM_PATHS, NFCXX_GCC for cosmo and k1om), so the caller passes them.
#
#   ruby scripts/nfcxx-cache.rb [--arg=ARG]... [--env=NAME=VALUE]... [--var=NAME=VALUE]... [--src=SRC]... [--file=FILE]...
#                               [--mdeps=PATH | --mdeps-failed] [--records=ti,ii] [--remote=hit|miss] [--uid=N] [--cwd=DIR]
#   --arg       the command line as given (nfcxx_argv; --cache=, --cache-log=, --time-log= and --trace= are left out of the key)
#   --var       loop state: out, compile_only, ncpp, outset, nobj, modules, preprocess, stdin_src, depmode (empty when unset),
#               cfiles_n, cu_n, cpp2_n (the counts of cfiles, cu_inputs and cpp2_inputs)
#   --src       the sources (srcs), in order; --file the link's files (files), for the .o removal
#   --mdeps     the output of the host preprocessor's -M: the headers the key lists; --mdeps-failed when that command failed
#   --records   the records the build leaves beside the object: ti and ii
#   --remote    the remote helper's answer on a local miss (only read with NFCXX_CACHE_REMOTE=gha; default miss)
#   --uid       id -u (the default cache directory when NFCXX_CACHE is empty)
#   --cwd       the working directory (default: the process's)
#
# Not covered: the GitHub Actions calls (the helper's answer is --remote), the device image cache, the CUDA second pass, -MD
# (its dependency file), -E and stdin inputs (not cached: the lookup is skipped, which the port does too), and arguments
# that are not ASCII (the %q quoting below handles ASCII only).

require "digest"
require "find"
require "open3"

ROOT = File.expand_path("..", __dir__)

# The environment lines the key leaves out (cache_lookup's grep -Ev).
KEY_ENV_LEFT_OUT = %w[NFCXX_CACHE_LOG NFCXX_CACHE_REMOTE NFCXX_TIME_LOG NFCXX_TRACE NFCXX_TRACE_OWNER NFCXX_TRACE_UNIT].freeze

# An error that nfcxx prints and exits 2 for.
class Fatal < StandardError
end

# The bash's printf %q for ASCII text: a word of safe characters is printed as it is, others get a backslash.
def shell_quote(text)
  return "''" if text.empty?

  text.gsub(/[^A-Za-z0-9_.\/=:+@%~-]/) { |c| "\\#{c}" }
end

# cache_sha on stdin, as sha256sum prints it.
def sha_line(data)
  "#{Digest::SHA256.hexdigest(data)}  -"
end

def read_or_empty(path)
  File.file?(path) ? File.binread(path) : "".b
end

def concat_files(paths)
  paths.inject("".b) { |acc, p| acc << File.binread(p) }
end

# find DIR -type f | sort: the regular files (not symlinks) under DIR, sorted bytewise by path.
def regular_files_under(dir)
  return [] unless File.directory?(dir)

  paths = []
  Find.find(dir) { |p| paths << p if File.file?(p) && !File.symlink?(p) }
  paths.sort
end

# find DIR -maxdepth 1 -type f | sort
def regular_files_directly_in(dir)
  return [] unless File.directory?(dir)

  Dir.children(dir).map { |n| "#{dir}/#{n}" }.select { |p| File.file?(p) && !File.symlink?(p) }.sort
end

# realpath -m: the path made absolute against cwd, with the symlinks of its existing part resolved.
def realpath_m(path, cwd)
  full = File.expand_path(path, cwd)
  rest = []
  pre = full
  until pre == "/" || File.exist?(pre)
    rest.unshift(File.basename(pre))
    pre = File.dirname(pre)
  end
  File.join(File.realpath(pre), *rest)
end

# ${x%.*}: x without its last extension (x itself when it has no dot).
def strip_ext(text)
  text.include?(".") ? text[0...text.rindex(".")] : text
end

class Cache
  def initialize(opt)
    @args = opt[:args]
    @env = opt[:env]
    @vars = opt[:vars]
    @srcs = opt[:srcs]
    @files = opt[:files]
    @mdeps = opt[:mdeps]
    @mdeps_failed = opt[:mdeps_failed]
    @records = opt[:records]
    @remote_answer = opt[:remote]
    @uid = opt[:uid]
    @cwd = opt[:cwd]
  end

  def run
    # the setup: NFCXX_CACHE_REMOTE is checked first, and the default directory is made when there is none
    remote = env_value("NFCXX_CACHE_REMOTE")
    raise Fatal, "nfcxx: NFCXX_CACHE_REMOTE takes gha (got '#{remote}')" unless ["", "gha"].include?(remote)

    cache_dir = env_value("NFCXX_CACHE")
    cache_log = env_value("NFCXX_CACHE_LOG")
    cache_dir = "#{env_value('TMPDIR', '/tmp')}/nfcxx-cache-#{@uid}" if cache_dir.empty? && !remote.empty?
    # the loop's --cache= and --cache-log= (the last one wins)
    @args.each do |a|
      case a
      when /\A--cache=(.*)\z/m then cache_dir = Regexp.last_match(1)
      when /\A--cache-log=(.*)\z/m then cache_log = Regexp.last_match(1)
      end
    end

    out = var("out", "a.out")
    srcs = @srcs
    # A Path B compile (backend=pathb) has no removals before the compile and none after it: it writes no records.
    pathb = backend == "pathb"
    unless pathb
      removals_before_compile(srcs, out)
      link_records_rm
    end
    cache_entry = nil
    key = nil
    if eligible?(cache_dir, out, srcs)
      key = lookup(srcs.first, out, cache_dir, cache_log)
      if key
        entry = "#{cache_dir}/objects/#{key}"
        cache_entry = entry
        remote_hit = !remote.empty? && !File.file?("#{entry}/obj") && remote_get(key, entry)
        if File.file?("#{entry}/obj") || remote_hit
          hit(out, entry, pathb)
          return
        end
      end
    end
    puts "RUN build #{out}"
    link_records_rm unless pathb
    store(out, cache_entry, key, remote, pathb ? [] : @records) if cache_entry && !File.file?("#{cache_entry}/obj")
  end

  private

  def backend
    var("backend", "gcc")
  end

  def env_value(name, default = "")
    value = @env[name]
    value.nil? || value.empty? ? default : value
  end

  def var(name, default)
    value = @vars[name]
    value.nil? ? default : value
  end

  def int_var(name)
    var(name, "0").to_i
  end

  def cxx
    env_value("NFCXX_CXX", "g++")
  end

  def edg
    "#{env_value('EDG_BUILD', File.join(ROOT, 'build/edg'))}/bin"
  end

  # the eligibility test of the cache block (one -c compile of one source with -o, not in any listed form)
  def eligible?(cache_dir, out, srcs)
    !cache_dir.empty? && int_var("compile_only") == 1 && int_var("ncpp") == 1 && int_var("outset") == 1 &&
      int_var("nobj") == 0 && int_var("cfiles_n") == 0 && int_var("modules") == 0 && int_var("cu_n") == 0 &&
      int_var("cpp2_n") == 0 && var("depmode", "").empty? && int_var("preprocess") == 0 &&
      int_var("stdin_src") == 0 && out.include?(".") && !srcs.empty?
  end

  # the removal before a compile: <stem>.ii and <stem>.ti (the first source takes the -o name)
  def removals_before_compile(srcs, out)
    return unless int_var("compile_only") == 1 && int_var("ncpp") > 0

    first = true
    srcs.each do |s|
      stem = strip_ext(File.basename(s))
      stem = strip_ext(out) if first && out.include?(".")
      puts "RUN rm -f #{stem}.ii #{stem}.ti"
      first = false
    end
  end

  # link_records_rm: <stem>.ii beside each object of the link
  def link_records_rm
    @files.each { |f| puts "RUN rm -f #{f[0...-2]}.ii" if f.end_with?(".o") }
  end

  def lookup(src, out, cache_dir, cache_log)
    return nil if @mdeps_failed

    inputs = key_inputs(src, out)
    key = Digest::SHA256.hexdigest(inputs + "\n")[0, 40]
    state = File.file?("#{cache_dir}/objects/#{key}/obj") ? "hit" : "miss"
    unless cache_log.empty?
      puts "CAT #{cache_log}"
      print "== #{out} (#{src})\n#{inputs}\nkey #{key}\n#{state}\n"
      puts "END"
    end
    puts "KEY #{key}"
    key
  end

  def key_argv
    @args.reject { |a| a.start_with?("--cache=", "--cache-log=", "--time-log=", "--trace=") }
  end

  def env_lines
    @env.select { |k, _| k.start_with?("NFCXX_") && !KEY_ENV_LEFT_OUT.include?(k) }
        .map { |k, v| "#{k}=#{v}" }
        .sort
  end

  # the header list: the -M output with its continuation backslashes and its target (the first token) left out
  def header_list
    text = File.binread(@mdeps)
    tokens = text.split("\n", -1).map { |l| l.sub(/\\\z/, "") }.join("\n").tr(" ", "\n").split("\n").reject(&:empty?)
    tokens.drop(1)
  end

  def driver_lines
    eccp = File.join(edg, "eccp")
    text = File.file?(eccp) ? File.binread(eccp) : "".b
    execs = text.lines.filter_map { |l| l[/\Aexec "([^"]*)"/, 1] }.join("\n")
    dots = text.lines.filter_map { |l| l[/\A\. "([^"]*)"/, 1] }.join("\n")
    config = File.join(env_value("EDG_BASE", File.join(ROOT, "build/edg-base")), "edg_eccp_config")
    [execs, dots, config].map { |f| File.file?(f) ? sha_line(File.binread(f)) : "missing #{f}" }
  end

  def first_line_of(command)
    out, = Open3.capture2(command, "--version")
    line = out.lines.first
    line&.chomp
  rescue SystemCallError
    nil
  end

  # the text that cache_lookup hashes (its inputs, without the trailing newline that $(...) drops)
  def key_inputs(src, out)
    lines = ["nfcxx-cache-1", "argv:" + key_argv.map { |a| " #{shell_quote(a)}" }.join,
             "cwd: #{@cwd}", "out: #{realpath_m(out, @cwd)}", "src: #{realpath_m(src, @cwd)}"]
    lines.concat(env_lines)
    lines << sha_line(File.binread(File.join(ROOT, "nfcxx")))
    lines << sha_line(concat_files(regular_files_under(File.join(ROOT, "scripts"))))
    lines << sha_line(concat_files(regular_files_directly_in(edg)))
    qbe = File.join(ROOT, "build/qbe/qbe")
    lines << sha_line(File.binread(qbe)) if File.file?(qbe)
    lines << sha_line(read_or_empty(File.join(ROOT, "tools/weak-symbols/weak_symbols.cpp")))
    lines.concat(driver_lines)
    [cxx, "cc"].each do |c|
      line = first_line_of(c)
      lines << line if line
    end
    lines.concat(pathb_lines) if backend == "pathb"
    header_list.each do |f|
      lines << "#{f} #{File.file?(f) ? sha_line(File.binread(f)) : 'missing'}"
    end
    lines.join("\n").sub(/\n+\z/, "")
  end

  # a Path B object's key: the backend, the Path B front end (PATHB_CPFE) and its base files (PATHB_BASE)
  def pathb_lines
    cpfe = env_value("PATHB_CPFE", File.join(ROOT, "build/pathb/cmake/bin/cpfe"))
    base = env_value("PATHB_BASE", File.join(ROOT, "build/pathb/edg-base"))
    ["backend: pathb",
     File.file?(cpfe) ? sha_line(File.binread(cpfe)) : "missing #{cpfe}",
     sha_line(concat_files(regular_files_directly_in(base)))]
  end

  # the remote tier on a local miss: the helper's get into a temporary entry, moved into place on a hit
  def remote_get(key, entry)
    tmp = "#{entry}.remote.#{Process.pid}"
    puts "RUN rm -rf #{tmp}"
    puts "RUN python3 -I #{ROOT}/scripts/nfcxx-cache-gha.py get #{key} #{tmp}"
    hit = @remote_answer == "hit"
    if hit
      puts "RUN mkdir -p #{File.dirname(entry)}"
      puts "RUN mv #{tmp} #{entry}" unless File.exist?(entry)
    end
    puts "RUN rm -rf #{tmp}"
    hit
  end

  # the hit: the object and its records go back beside the output (a Path B entry has the object only)
  def hit(out, entry, pathb)
    stem = strip_ext(out)
    puts "RUN rm -f #{stem}.ti #{stem}.ii" unless pathb
    puts "CP #{entry}/obj #{out}"
    %w[ti ii].each { |x| puts "CP #{entry}/#{x} #{stem}.#{x}" if !pathb && File.file?("#{entry}/#{x}") }
    puts "EXIT 0"
  end

  # the store: the entry appears at once (it is made under a temporary name and moved into place)
  def store(out, entry, key, remote, records)
    stem = strip_ext(out)
    tmp = "#{entry}.tmp.#{Process.pid}"
    recs = %w[ti ii].select { |x| records.include?(x) }
    puts "RUN mkdir -p #{tmp} #{File.dirname(entry)}"
    puts "CP #{out} #{tmp}/obj"
    recs.each { |x| puts "CP #{stem}.#{x} #{tmp}/#{x}" }
    moved = !File.exist?(entry)
    puts "RUN mv #{tmp} #{entry}" if moved
    puts "RUN rm -rf #{tmp}"
    return unless moved && !remote.empty?

    puts "RUN python3 -I #{ROOT}/scripts/nfcxx-cache-gha.py put #{key} #{entry} #{(['obj'] + recs).join(' ')}"
  end
end

def parse_options(argv)
  opt = { args: [], env: {}, vars: {}, srcs: [], files: [], mdeps: nil, mdeps_failed: false, records: [],
          remote: "miss", uid: Process.uid, cwd: Dir.pwd }
  argv.each do |a|
    case a
    when /\A--arg=(.*)\z/m then opt[:args] << Regexp.last_match(1)
    when /\A--env=([^=]*)=(.*)\z/m then opt[:env][Regexp.last_match(1)] = Regexp.last_match(2)
    when /\A--var=([^=]*)=(.*)\z/m then opt[:vars][Regexp.last_match(1)] = Regexp.last_match(2)
    when /\A--src=(.*)\z/m then opt[:srcs] << Regexp.last_match(1)
    when /\A--file=(.*)\z/m then opt[:files] << Regexp.last_match(1)
    when /\A--mdeps=(.*)\z/m then opt[:mdeps] = Regexp.last_match(1)
    when "--mdeps-failed" then opt[:mdeps_failed] = true
    when /\A--records=(.*)\z/ then opt[:records] = Regexp.last_match(1).split(",")
    when /\A--remote=(.*)\z/ then opt[:remote] = Regexp.last_match(1)
    when /\A--uid=(\d+)\z/ then opt[:uid] = Regexp.last_match(1).to_i
    when /\A--cwd=(.*)\z/m then opt[:cwd] = Regexp.last_match(1)
    else raise Fatal, "usage: nfcxx-cache.rb [--arg=ARG] [--env=NAME=VALUE] [--var=NAME=VALUE] [--src=SRC] [--file=FILE] " \
                      "[--mdeps=PATH | --mdeps-failed] [--records=ti,ii] [--remote=hit|miss] [--uid=N] [--cwd=DIR] (got #{a})"
    end
  end
  raise Fatal, "nfcxx-cache.rb: --mdeps or --mdeps-failed is needed for a cached compile" if opt[:mdeps].nil? && !opt[:mdeps_failed]

  opt
end

if $PROGRAM_NAME == __FILE__
  begin
    Cache.new(parse_options(ARGV)).run
  rescue Fatal => e
    warn e.message
    exit 2
  end
end
