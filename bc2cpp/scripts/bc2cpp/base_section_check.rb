#!/usr/bin/env ruby
# frozen_string_literal: true

# Fails when the base section of sig/bc2cpp/declarations.rbs, or bc2cpp/sig/base_core.rbs, is not byte for byte what
# the base generators write now (BaseSection.write_texts: the layout is canonical, so the order counts too). Host plus the closed build's headers, a few minutes (base_rbs_all.rb preprocesses every native gem).
#
#   ruby scripts/bc2cpp/base_section_check.rb [--output DIR] [--jobs N] CLOSED_BUILD_DIR [DECLARATIONS]
#   ruby scripts/bc2cpp/base_section_check.rb --write CLOSED_BUILD_DIR [DECLARATIONS]
#
# DECLARATIONS defaults to sig/bc2cpp/declarations.rbs; a fixture passes a copy. --write rewrites that file's base section
# from the generators instead of checking it (the rest of the file is kept byte for byte). See tools/bc2cpp/base_section.rb
# and scripts/bc2cpp/base_section_regen_check.rb. --jobs sets the native-file
# workers in CI (the default of 2 stays for local runs); reverts to 2 if the
# step's timing table shows contention with the other parallel checks.

require_relative '../../tools/bc2cpp/world_root'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/bc2cpp/base_section'

ROOT = BC2CPP_WORLD_ROOT
GENERATOR = File.join(BC2CPP_TREE_ROOT, 'scripts/bc2cpp/base_rbs_all.rb')
output = nil
write = false
jobs = nil
parser = OptionParser.new do |opts|
  opts.banner = 'usage: base_section_check.rb [--output DIR] [--jobs N] CLOSED_BUILD_DIR [DECLARATIONS]'
  opts.on('--output DIR', 'Keep freshly generated base RBS in DIR') { |dir| output = File.expand_path(dir) }
  opts.on('--jobs N', Integer, 'Native file workers (default 2)') { |n| jobs = n }
  opts.on('--write', 'Rewrite the base section of DECLARATIONS from the generators instead of checking it') { write = true }
end
parser.parse!(ARGV)
abort parser.to_s unless (1..2).cover?(ARGV.size)
abort 'base_section_check: --write and --output are exclusive' if write && output
abort 'base_section_check: --write and --jobs are exclusive' if write && jobs
abort 'base_section_check: output directory must be absent or empty' if output && File.exist?(output) &&
                                                                        (!File.directory?(output) || !Dir.empty?(output))
abort 'base_section_check: --jobs must be positive' if jobs && !jobs.positive?

closed = File.expand_path(ARGV[0])
declarations = File.expand_path(ARGV[1] || File.join(ROOT, 'sig/bc2cpp/declarations.rbs'))
text = File.read(declarations, encoding: 'UTF-8')
declared_section = BaseSection.section_of(text)
# A generated stub whose method the hand sections declare is not written (see BaseSection.generated_ruby_decls): the
# hand sections are the world's declarations after the base section, and core.rbs beside it.
hand_texts = [text[declared_section.length..]]
core_rbs = File.join(File.dirname(declarations), 'core.rbs')
hand_texts << File.read(core_rbs, encoding: 'UTF-8') if File.file?(core_rbs)
hand = BaseSection.method_keys(hand_texts)

failures = []
Dir.mktmpdir('base-section-check') do |temporary|
  gen = output || temporary
  gen_args = [RbConfig.ruby, GENERATOR]
  gen_args.concat(['--jobs', jobs.to_s]) if jobs
  gen_args.concat([gen, closed])
  out, err, status = Open3.capture3(*gen_args)
  $stdout.write(out)
  $stderr.write(err)
  abort "base_section_check: base_rbs_all.rb failed (#{status})" unless status.success?

  bodies = BaseSection.native_bodies(gen)
  by_tag = BaseSection.generated_ruby_by_tag(gen, hand)
  core_text, world_text = BaseSection.write_texts(text, bodies, by_tag)
  if write
    # Only a file whose text changes is written, so a write over a current section touches nothing.
    written = [[BaseSection::CORE_FILE, core_text], [declarations, world_text]].filter_map do |path, body|
      next if File.file?(path) && File.read(path, encoding: 'UTF-8') == body

      File.write(path, body)
      path
    end
    puts "base section check: #{written.empty? ? 'nothing to rewrite' : "rewrote #{written.join(' and ')}"}"
    exit 0
  end

  [[BaseSection::CORE_FILE, BaseSection.core_file_text, core_text], [declarations, text, world_text]].each do |path, now, want|
    next if now == want

    failures << "#{path} is not what the generators write:\n#{BaseSection.first_differences(now, want).join("\n")}"
  end
  # Which declarations differ, when the difference is more than their order.
  committed_ruby = BaseSection.ruby_decls(BaseSection.core_file_text + declared_section)
  generated_ruby = BaseSection.generated_ruby_decls(gen, hand)
  missing = generated_ruby - committed_ruby
  stale = committed_ruby - generated_ruby
  missing.first(3).each { |d| failures << "  missing: #{d.lines.first.strip}" }
  stale.first(3).each { |d| failures << "  stale:   #{d.lines.first.strip}" }
end

if failures.empty?
  puts 'base section check: the committed base section matches the generators'
else
  warn "base section check: #{failures.size} problem(s); rewrite the base section with " \
       "ruby scripts/bc2cpp/base_section_check.rb --write #{ARGV[0]}"
  failures.each { |f| warn f }
  exit 1
end
