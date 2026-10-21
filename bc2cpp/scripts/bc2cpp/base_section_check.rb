#!/usr/bin/env ruby
# frozen_string_literal: true

# Fails when the base section of sig/bc2cpp/declarations.rbs is not what the base generators write now: a native block
# that differs from its regenerated body, or a Ruby declaration the generator no longer writes (or writes and the file
# lacks). Host plus the closed build's headers, a few minutes (base_rbs_all.rb preprocesses every native gem).
#
#   ruby scripts/bc2cpp/base_section_check.rb [--output DIR] CLOSED_BUILD_DIR [DECLARATIONS]
#   ruby scripts/bc2cpp/base_section_check.rb --write CLOSED_BUILD_DIR [DECLARATIONS]
#
# DECLARATIONS defaults to sig/bc2cpp/declarations.rbs; a fixture passes a copy. --write rewrites that file's base section
# from the generators instead of checking it (the rest of the file is kept byte for byte). See tools/bc2cpp/base_section.rb
# and scripts/bc2cpp/base_section_regen_check.rb.

require 'open3'
require 'optparse'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/bc2cpp/base_section'

ROOT = File.expand_path('../..', __dir__)
GENERATOR = File.join(ROOT, 'scripts/bc2cpp/base_rbs_all.rb')
output = nil
write = false
parser = OptionParser.new do |opts|
  opts.banner = 'usage: base_section_check.rb [--output DIR | --write] CLOSED_BUILD_DIR [DECLARATIONS]'
  opts.on('--output DIR', 'Keep freshly generated base RBS in DIR') { |dir| output = File.expand_path(dir) }
  opts.on('--write', 'Rewrite the base section of DECLARATIONS from the generators instead of checking it') { write = true }
end
parser.parse!(ARGV)
abort parser.to_s unless (1..2).cover?(ARGV.size)
abort 'base_section_check: --write and --output are exclusive' if write && output
abort 'base_section_check: output directory must be absent or empty' if output && File.exist?(output) &&
                                                                        (!File.directory?(output) || !Dir.empty?(output))

closed = File.expand_path(ARGV[0])
declarations = File.expand_path(ARGV[1] || File.join(ROOT, 'sig/bc2cpp/declarations.rbs'))
committed = BaseSection.section_of(File.read(declarations))

failures = []
Dir.mktmpdir('base-section-check') do |temporary|
  gen = output || temporary
  out, err, status = Open3.capture3(RbConfig.ruby, GENERATOR, gen, closed)
  $stdout.write(out)
  $stderr.write(err)
  abort "base_section_check: base_rbs_all.rb failed (#{status})" unless status.success?

  if write
    File.write(declarations, BaseSection.regenerate(File.read(declarations), gen))
    puts "base section check: rewrote the base section of #{declarations}"
    exit 0
  end

  regenerated = BaseSection.regenerate_native(committed, gen)
  committed_native = BaseSection.native_text(committed)
  regenerated_native = BaseSection.native_text(regenerated)
  if committed_native != regenerated_native
    failures << "native blocks differ from the generator's output:\n" \
                "#{BaseSection.first_differences(committed_native, regenerated_native).join("\n")}"
  end

  committed_ruby = BaseSection.ruby_decls(committed)
  generated_ruby = BaseSection.generated_ruby_decls(gen)
  missing = generated_ruby - committed_ruby
  stale = committed_ruby - generated_ruby
  unless missing.empty? && stale.empty?
    failures << "Ruby declarations differ: #{missing.size} missing from the file, #{stale.size} the generator no longer writes"
    missing.first(3).each { |d| failures << "  missing: #{d.lines.first.strip}" }
    stale.first(3).each { |d| failures << "  stale:   #{d.lines.first.strip}" }
  end
end

if failures.empty?
  puts 'base section check: the committed base section matches the generators'
else
  warn "base section check: #{failures.size} problem(s); rewrite the base section with " \
       "ruby scripts/bc2cpp/base_section_check.rb --write #{ARGV[0]}"
  failures.each { |f| warn f }
  exit 1
end
