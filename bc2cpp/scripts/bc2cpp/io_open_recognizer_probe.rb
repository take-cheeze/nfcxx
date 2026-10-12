#!/usr/bin/env ruby
# encoding: UTF-8
# REPRODUCTION HARNESS: what the two ensure/rescue recognizers say about the two
# REAL core `singleton#open` methods, on the wio closed world.
#
# This is the measurement `IO.singleton#open`'s two `#error EXCEPT` markers come
# from. It installs a one-line probe into compile_method, asks each recognizer
# for its verdict, prints it, and restores the file. It changes nothing else and
# asserts nothing -- it is a report, because the finding is a fact to read, not a
# condition to gate on.
#
#   StringIO.singleton#open  core=true  handlers=[[:ensure, 22, 55, 55]]                  ensure=yes
#   IO.singleton#open        core=true  handlers=[[:ensure, 30, 40, 40],
#                                                 [:rescue, 42, 63, 66]]                ensure=no
#
# Same construct, same compiler, opposite verdict. The only structural difference
# is the second catch handler: IO's ensure body is itself a `rescue`.
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'shellwords'

ROOT = File.expand_path('../..', __dir__)
METHOD = File.join(ROOT, 'tools/bc2cpp/codegen_method.rb')
BACKUP = "#{METHOD}.repro.bak"
REPORT = ENV['BC2CPP_REPRO_REPORT'] || '/tmp/bc2cpp_io_open_recognizers.txt'

ANCHOR = '    ensure_region = recognize_ensure_region(irep)'
PROBE = [
  ANCHOR,
  '    if ENV["BC2CPP_REPRO"] == "1"',
  '      File.open(ENV.fetch("BC2CPP_REPRO_FILE"), "a") do |f|',
  '        begin',
  '          _h = Array(irep.catch_handlers).compact.map { |c| [c.type.to_s, c.begin_addr, c.end_addr, c.target] }',
  '          _r = recognize_rescue_regions(irep).map { |r| [r[:begin_addr], r[:end_addr], r[:raise_addr]] }',
  '          f.puts("VERDICT " + d.owner.to_s + "#" + d.name.to_s +',
  '                 " core=" + d.core.to_s +',
  '                 " ensure=" + (ensure_region ? "yes" : "no") +',
  '                 " rescues=" + _r.inspect +',
  '                 " handlers=" + _h.inspect)',
  '        rescue StandardError => e',
  '          f.puts("VERDICT-ERR " + d.owner.to_s + "#" + d.name.to_s + " " + e.class.to_s)',
  '        end',
  '      end',
  '    end'
].join("\n")

require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'

srcs = closed_world_mrblib_srcs(ROOT)
native = Dir["#{ROOT}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
owners = BC2CPP_COMPILED_GEMS.values.flat_map { |g| g[:owners] }

FileUtils.cp(METHOD, BACKUP)
begin
  src = File.read(METHOD)
  abort "probe anchor missing in #{METHOD}" unless src.include?(ANCHOR)

  File.write(METHOD, src.sub(ANCHOR, PROBE))
  FileUtils.rm_f(REPORT)

  Dir.mktmpdir do |dir|
    env = {
      'MRBC' => ENV['MRBC'], 'OUT_SYMBOL' => 'repro', 'OUT_DIR' => dir,
      'ONLY_OWNERS' => owners.join(','),
      'NATIVE_SRCS' => Shellwords.join(native),
      'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
      'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
      'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.wio_gems(ROOT).map { |n, d| "#{n}=#{d}" }),
      'BC2CPP_ALLOW_REVIEWED_NOMETHOD' => 'allow',
      'BC2CPP_REPRO' => '1', 'BC2CPP_REPRO_FILE' => REPORT
    }
    cmd = [RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), *srcs].shelljoin
    _out, err, st = Open3.capture3(env, cmd)
    abort "bc2cpp failed (exit #{st.exitstatus}); see the report file for detail" unless st.success?
  end

  lines = File.readlines(REPORT).map(&:chomp)
  wanted = lines.select { |l| l.match?(/VERDICT (?:IO|StringIO)\.singleton#open\b/) }.uniq
  abort "the probe reported nothing; is #{REPORT} writable?" if wanted.empty?

  puts '== recognizer verdicts, wio closed world =='
  wanted.sort.each { |l| puts "  #{l}" }
  puts
  puts 'IO.singleton#open is refused because its irep carries a SECOND catch handler'
  puts "(the ensure body is itself a `rescue`). Both guards that reject it are one line:"
  puts
  puts '  recognize_ensure_region   return nil unless irep.catch_handlers.size == 1'
  puts '  recognize_rescue_regions  return [] unless every handler is a :rescue'
ensure
  FileUtils.mv(BACKUP, METHOD)
end
