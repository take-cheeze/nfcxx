#!/usr/bin/env ruby
# frozen_string_literal: true

# bc2cpp coverage probe for optcarrot: runs tools/bc2cpp/bc2cpp.rb against
# optcarrot's own real source (3rd/optcarrot/lib) as its OWN closed world --
# entirely separate from the real project's mruby-lcf/rgss/rpg2k registry --
# and reports the same method-level attempted/compiled-clean/#error-reason
# breakdown scripts/bc2cpp/coverage_report.rb produces for the real gems
# (same parsing logic, reused directly from that script). See
# tools/optcarrot_probe/README.md for what this is and isn't.
#
# MRBC must be built from a 3rd/mruby checkout with
# the pinned fork commit (mruby-parser-dump-back-nth-ref) applied -- unpatched, mrbc's
# own `-v` disassembly dump crashes outright on optcarrot's real
# lib/optcarrot/opt.rb:74 (a `$'`/`$1` use), which this script cannot work
# around from the outside (the crash is inside mrbc's own process, before
# any output reaches this script). See that patch's own preamble.
# the pinned fork commit (mruby-module-function-scope) is NOT needed for this script
# specifically (verified) -- mrbc only compiles here, never runs the
# result, so that runtime-only gap never gets exercised.
#
# Usage: MRBC=path/to/host/mrbc ruby tools/optcarrot_probe/bc2cpp_probe.rb

require 'shellwords'
require 'open3'
require 'tmpdir'
require 'set'

ROOT = File.expand_path('../..', __dir__)
require_relative '../bc2cpp/compiled_gems'
require_relative 'sealed_build'
require 'fileutils'

BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC = ENV['MRBC'] || 'mrbc'
OPTCARROT_LIB = File.join(ROOT, '3rd/optcarrot/lib')
MRUBY_DIR = File.join(ROOT, '3rd/mruby')

unless Dir.exist?(OPTCARROT_LIB)
  abort "#{OPTCARROT_LIB} is empty -- run `git submodule update --init 3rd/optcarrot` first"
end

# Idempotent safety net, same as build_bundle.rb's -- only actually fixes
# anything if it runs BEFORE MRBC itself was built from this checkout (a
# rebuild picks the patch up; an already-built MRBC binary does not).

# bc2cpp compiles closed-world programs only: the probe compiles the sealed benchmark world
# whose outside sources are its build's mruby core and gems.
world_dir = Dir.mktmpdir('optcarrot-world-')
at_exit { FileUtils.rm_rf(world_dir) }
srcs, world_env = OptcarrotSealedBuild.bc2cpp_world(ROOT, world_dir)
env = world_env.merge('MRBC' => MRBC, 'OUT_SYMBOL' => 'optcarrot_probe')
cmd = [RbConfig.ruby, BC2CPP, '--annotated', *srcs].shelljoin
Dir.mktmpdir do |dir|
  env['OUT_DIR'] = dir
  @stdout, @stderr, status = Open3.capture3(env, cmd)
  raise "bc2cpp.rb failed (exit #{status.exitstatus}):\n#{@stderr[-6000..]}" unless status.success?
end

# Same section_lines/count helpers scripts/bc2cpp/coverage_report.rb uses.
def section_lines(text, header)
  start = text.index("== #{header} ==")
  raise "section #{header.inspect} not found in bc2cpp.rb's own diagnostic" unless start

  rest = text[start..]
  stop = rest.index("\n==", 1)
  body = stop ? rest[0...stop] : rest
  body.lines.drop(1).map(&:strip).reject(&:empty?)
end

def count(text, header, placeholder: nil)
  lines = section_lines(text, header)
  return 0 if placeholder && lines == [placeholder]

  lines.size
end

err = @stderr

compiled_lines = section_lines(err, 'compiled entry points')
compiled_names = compiled_lines.filter_map { |l| (m = l.match(/\((\S+)#(\S+),/)) && "#{m[1]}##{m[2]}" }.to_set

attempted_names = Set.new
errored_names = Set.new
error_reasons = Hash.new(0)
@stdout.split(/^(?=\/\/ (\S+#\S+) \(compiled from irep \d+, \d+ insns\)$)/).drop(1).each_slice(2) do |name, chunk|
  attempted_names << name
  chunk.each_line do |line|
    m = line.match(/#error (.+?) -- not in this prototype/)
    next unless m

    errored_names << name
    reason = m[1].sub(/^SEND\/SSEND :\S+ /, 'SEND/SSEND ').sub(/\(n=[^)]*\)/, '(n=...)')
    error_reasons[reason] += 1
  end
end
attempted = attempted_names.size
errored = errored_names.size
clean_names = compiled_names - errored_names
synthesized_count = (compiled_names - attempted_names).size

puts 'bc2cpp coverage probe -- optcarrot (tools/optcarrot_probe), own closed world'
puts
puts "compiled entry points (clean, zero #error): #{clean_names.size}"
puts "  from bytecode: #{clean_names.size - synthesized_count}"
puts "  synthesized accessor overrides (ATTR_STRUCT_DEVIRT): #{synthesized_count}"
puts
puts '-- method-level coverage --'
puts "methods attempted: #{attempted}"
puts "  compiled clean: #{attempted - errored}"
puts "  left on the interpreter (>=1 #error): #{errored}"
puts format('  coverage: %.1f%%', attempted.zero? ? 0.0 : 100.0 * (attempted - errored) / attempted)
puts
puts '-- #error reasons --'
error_reasons.sort_by { |_, n| -n }.each { |reason, n| puts format('  %4d  %s', n, reason) }
puts format('  %4d  total', error_reasons.values.sum)
puts
puts '-- errored methods (owner#name) --'
errored_names.sort.each { |n| puts "  #{n}" }
