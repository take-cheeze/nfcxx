#!/usr/bin/env ruby
# nfcxx's compile cache: the key of a -c compile, the lookup, the copy of a hit back beside the output, and the store of a new
# object. The bash driver (nfcxx) calls these; the bash originals are frozen in tests/nfcxx-cache/nfcxx-bash (the oracle of
# tests/nfcxx-cache/run.sh). Without a cache directory nfcxx starts no Ruby.
#
#   ruby scripts/nfcxx-cache.rb lookup --cache-dir=DIR [--cache-log=FILE] --out=OUT --src=SRC --cwd=DIR
#                                      [--cpp=ARG]... [--arg=ARG]... [--var=NAME=VALUE]...
#   ruby scripts/nfcxx-cache.rb hit --out=OUT --entry=DIR
#   ruby scripts/nfcxx-cache.rb store --out=OUT --entry=DIR
#
# lookup: a compile is cached when the loop state says so (--var: compile_only, ncpp, outset, nobj, cfiles_n, modules, cu_n,
# cpp2_n, depmode, preprocess, stdin_src, backend; the conditions of nfcxx's cache_check). Then the host preprocessor runs as
# "$NFCXX_CXX -M ARG... SRC" (--cpp gives the ARGs; stderr is dropped), its header list is hashed with the rest of the key,
# and the key is the first 40 hex digits of the SHA-256 of the key inputs. stdout is the --cache-log block when --cache-log
# is given (the text nfcxx's cache_log appends: the key inputs, the key, hit or miss), then one line "hit KEY" or "miss KEY".
# Nothing is printed when the compile is not cached or its headers cannot be listed.
# hit: exit 0 when the entry holds an object: the object goes to OUT, and the entry's .ti and .ii beside it (OUT's own .ti and
# .ii are removed first). Exit 1 when the entry holds no object, with nothing changed.
# store: exit 0 when the entry had no object and now has one: OUT and the .ti and .ii beside it that exist are copied under a
# temporary name and moved into place, so a whole entry appears at once. Exit 1 otherwise.
#
# The key covers what the bash covered (docs/notes/cxx-driver.md): the argv (--cache=, --cache-log=, --time-log= and --trace=
# left out, as nfcxx passes them), the working directory, the absolute output and source, every NFCXX_* environment variable
# but the logs, the remote tier's and the driver-to-body handoffs (KEY_ENV_LEFT_OUT), nfcxx and scripts/, the EDG binaries,
# build/qbe/qbe, tools/weak-symbols, the EDG driver and its configuration, the host compiler versions, the Path B front end
# when backend=pathb, and each header (hashed).
#
# Not covered: the GitHub Actions calls (nfcxx runs scripts/nfcxx-cache-io.rb between a miss and the hit check, and after a
# store), the device image cache, and the CUDA second pass.

require "digest"
require "fileutils"
require "find"
require "open3"

ROOT = File.expand_path("..", __dir__)

# The environment variables the key leaves out: the logs and the remote tier's (the bash's grep -Ev names), and the handoffs
# the Ruby driver and the body pass each other. A handoff is not an input to the object: NFCXX_TRACE_PENDING is a per-run
# file (its name carries the driver's pid and temporary directory), so a key that took it would never repeat when the
# trace is on. NFCXX_TMP_OWNED and the body's own handoffs (fallback marker, owned directories, loop and setup records)
# say who removes what, not what is compiled.
KEY_ENV_LEFT_OUT = %w[NFCXX_CACHE_LOG NFCXX_CACHE_REMOTE NFCXX_TIME_LOG NFCXX_TRACE NFCXX_TRACE_OWNER NFCXX_TRACE_UNIT
                      NFCXX_TRACE_PENDING NFCXX_TMP_OWNED NFCXX_FALLBACK_MARKER NFCXX_OWNED_CUDATMP NFCXX_OWNED_TMP
                      NFCXX_OWNED_CTMP NFCXX_OWNED_PTMP NFCXX_OWNED_ECCP NFCXX_LOOP_STATUS NFCXX_LOOP_STATE].freeze
# the handoff prefixes: the setup records the Ruby driver passes the body (NFCXX_SETUP_*), unset by the body when it reads them
KEY_ENV_LEFT_OUT_PREFIXES = %w[NFCXX_SETUP_].freeze

# A usage error: nfcxx prints it and exits 2.
class Fatal < StandardError
end

# The bash's printf %q for ASCII text: a word of safe characters is printed as it is, others get a backslash.
def shell_quote(text)
  return "''" if text.empty?

  text.gsub(/[^A-Za-z0-9_.\/=:+@%~-]/) { |c| "\\#{c}" }
end

# cache_sha on the bytes of data, as sha256sum prints it.
def sha_line(data)
  "#{Digest::SHA256.hexdigest(data)}  -"
end

def read_or_empty(path)
  File.file?(path) ? File.binread(path) : "".b
end

def concat_files(paths)
  paths.inject("".b) { |acc, p| acc << File.binread(p) }
end

# find DIR -type f | sort LC_ALL=C: the regular files (not symlinks) under DIR, bytewise by path.
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

# cp SRC DST as GNU cp makes it without -p: DST keeps its mode when it exists; a new file gets SRC's mode less the umask.
# A failure is a note on stderr, as cp's is, and the caller goes on.
def copy_file(src, dst)
  File.open(dst, "wb", File.stat(src).mode & 0o777) { |f| IO.copy_stream(src, f) }
rescue SystemCallError => e
  warn "cp: #{e.message}"
end

def env_value(name, default = "")
  value = ENV[name]
  value.nil? || value.empty? ? default : value
end

# The header list of the -M output: the target (the first token) and the continuation backslashes are left out; the words are
# split as the bash's for loop splits them.
def header_list(deps)
  joined = deps.split("\n", -1).map { |l| l.sub(/\\\z/, "") }.join("\n")
  joined.split(/[ \t\n]+/).reject(&:empty?).drop(1)
end

# The key inputs, as the bash's cache_lookup printed them (without the newlines that $(...) drops).
def key_inputs(opt, deps)
  cxx = env_value("NFCXX_CXX", "g++")
  edg = "#{env_value('EDG_BUILD', File.join(ROOT, 'build/edg'))}/bin"
  lines = ["nfcxx-cache-1", "argv:" + opt[:args].map { |a| " #{shell_quote(a)}" }.join,
           "cwd: #{opt[:cwd]}", "out: #{realpath_m(opt[:out], opt[:cwd])}", "src: #{realpath_m(opt[:src], opt[:cwd])}"]
  lines.concat(nfcxx_env_lines)
  lines << sha_line(File.binread(File.join(ROOT, "scripts", "nfcxx-body.rb")))
  lines << sha_line(concat_files(regular_files_under(File.join(ROOT, "scripts"))))
  lines << sha_line(concat_files(regular_files_directly_in(edg)))
  qbe = File.join(ROOT, "build/qbe/qbe")
  lines << sha_line(File.binread(qbe)) if File.file?(qbe)
  lines << sha_line(read_or_empty(File.join(ROOT, "tools/weak-symbols/weak_symbols.cpp")))
  lines.concat(driver_lines(edg))
  [cxx, "cc"].each do |c|
    line = first_line_of(c)
    lines << line if line
  end
  lines.concat(pathb_lines) if opt[:vars]["backend"] == "pathb"
  header_list(deps).each do |f|
    lines << "#{f} #{File.file?(f) ? sha_line(File.binread(f)) : 'missing'}"
  end
  lines.join("\n").sub(/\n+\z/, "")
end

# env | grep '^NFCXX_' | grep -Ev the left-out names | LC_ALL=C sort
def nfcxx_env_lines
  ENV.keys.select do |k|
    k.start_with?("NFCXX_") && !KEY_ENV_LEFT_OUT.include?(k) && KEY_ENV_LEFT_OUT_PREFIXES.none? { |p| k.start_with?(p) }
  end
     .map { |k| "#{k}=#{ENV[k]}" }
     .sort
end

# The EDG driver: the executables and the sourced files that bin/eccp names, and the configuration it reads
def driver_lines(edg)
  eccp = File.join(edg, "eccp")
  text = File.file?(eccp) ? File.binread(eccp) : "".b
  execs = text.lines.filter_map { |l| l[/\Aexec "([^"]*)"/, 1] }.join("\n")
  dots = text.lines.filter_map { |l| l[/\A\. "([^"]*)"/, 1] }.join("\n")
  config = File.join(env_value("EDG_BASE", File.join(ROOT, "build/edg-base")), "edg_eccp_config")
  [execs, dots, config].map { |f| File.file?(f) ? sha_line(File.binread(f)) : "missing #{f}" }
end

# "$1 --version | head -1": the first line, or nothing when the command cannot run
def first_line_of(command)
  out, = Open3.capture2(command, "--version")
  out.lines.first&.chomp
rescue SystemCallError
  nil
end

# a Path B object's key: the backend, the Path B front end (PATHB_CPFE) and its base files (PATHB_BASE)
def pathb_lines
  cpfe = env_value("PATHB_CPFE", File.join(ROOT, "build/pathb/cmake/bin/cpfe"))
  base = env_value("PATHB_BASE", File.join(ROOT, "build/pathb/edg-base"))
  ["backend: pathb",
   File.file?(cpfe) ? sha_line(File.binread(cpfe)) : "missing #{cpfe}",
   sha_line(concat_files(regular_files_directly_in(base)))]
end

# cache_check's conditions: one -c compile of one source with -o, with no other input or option that the cache does not keep
def eligible?(opt)
  v = opt[:vars]
  count = ->(name) { v.fetch(name, "0").to_i }
  count.call("compile_only") == 1 && count.call("ncpp") == 1 && count.call("outset") == 1 &&
    count.call("nobj") == 0 && count.call("cfiles_n") == 0 && count.call("modules") == 0 &&
    count.call("cu_n") == 0 && count.call("cpp2_n") == 0 && v.fetch("depmode", "").empty? &&
    count.call("preprocess") == 0 && count.call("stdin_src") == 0 && opt[:out].include?(".") && !opt[:src].empty?
end

# The host preprocessor's dependency output, or nil when it fails (the bash drops stderr and returns 1 then).
def dependency_text(opt)
  cxx = env_value("NFCXX_CXX", "g++")
  out, status = Open3.capture2(cxx, "-M", *opt[:cpp], opt[:src], err: File::NULL)
  status.success? ? out : nil
rescue SystemCallError
  nil
end

def lookup(opt)
  return unless eligible?(opt)

  deps = dependency_text(opt)
  return if deps.nil?

  inputs = key_inputs(opt, deps)
  key = Digest::SHA256.hexdigest(inputs + "\n")[0, 40]
  state = File.file?(File.join(opt[:cache_dir], "objects", key, "obj")) ? "hit" : "miss"
  puts "== #{opt[:out]} (#{opt[:src]})\n#{inputs}\nkey #{key}\n#{state}" unless opt[:cache_log].empty?
  puts "#{state} #{key}"
end

def hit(opt)
  obj = File.join(opt[:entry], "obj")
  return 1 unless File.file?(obj)

  stem = strip_ext(opt[:out])
  ["#{stem}.ti", "#{stem}.ii"].each { |f| FileUtils.rm_f(f) }
  copy_file(obj, opt[:out])
  %w[ti ii].each do |x|
    rec = File.join(opt[:entry], x)
    copy_file(rec, "#{stem}.#{x}") if File.file?(rec)
  end
  0
end

def store(opt)
  entry = opt[:entry]
  return 1 if File.file?(File.join(entry, "obj"))

  tmp = "#{entry}.tmp.#{Process.pid}"
  FileUtils.mkdir_p(tmp)
  FileUtils.mkdir_p(File.dirname(entry))
  copy_file(opt[:out], File.join(tmp, "obj"))
  stem = strip_ext(opt[:out])
  %w[ti ii].each do |x|
    rec = "#{stem}.#{x}"
    copy_file(rec, File.join(tmp, x)) if File.file?(rec)
  end
  begin
    File.rename(tmp, entry) unless File.exist?(entry)
  rescue SystemCallError
    nil
  end
  FileUtils.rm_rf(tmp)
  File.file?(File.join(entry, "obj")) ? 0 : 1
end

def parse(argv)
  cmd, *rest = argv
  opt = { args: [], cpp: [], vars: {}, cache_dir: "", cache_log: "", out: "", src: "", cwd: Dir.pwd, entry: "" }
  rest.each do |a|
    case a
    when /\A--cache-dir=(.*)\z/m then opt[:cache_dir] = Regexp.last_match(1)
    when /\A--cache-log=(.*)\z/m then opt[:cache_log] = Regexp.last_match(1)
    when /\A--out=(.*)\z/m then opt[:out] = Regexp.last_match(1)
    when /\A--src=(.*)\z/m then opt[:src] = Regexp.last_match(1)
    when /\A--cwd=(.*)\z/m then opt[:cwd] = Regexp.last_match(1)
    when /\A--entry=(.*)\z/m then opt[:entry] = Regexp.last_match(1)
    when /\A--arg=(.*)\z/m then opt[:args] << Regexp.last_match(1)
    when /\A--cpp=(.*)\z/m then opt[:cpp] << Regexp.last_match(1)
    when /\A--var=([^=]*)=(.*)\z/m then opt[:vars][Regexp.last_match(1)] = Regexp.last_match(2)
    else raise Fatal, "usage: nfcxx-cache.rb lookup|hit|store [options] (got #{a})"
    end
  end
  raise Fatal, "nfcxx-cache.rb: no command" if cmd.nil?

  [cmd, opt]
end

if $PROGRAM_NAME == __FILE__
  begin
    cmd, opt = parse(ARGV)
    case cmd
    when "lookup"
      lookup(opt)
      exit 0
    when "hit"
      exit(hit(opt))
    when "store"
      exit(store(opt))
    else
      raise Fatal, "usage: nfcxx-cache.rb lookup|hit|store [options] (got #{cmd})"
    end
  rescue Fatal => e
    warn e.message
    exit 2
  end
end
