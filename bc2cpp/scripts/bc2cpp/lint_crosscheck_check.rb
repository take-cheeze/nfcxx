#!/usr/bin/env ruby
# frozen_string_literal: true

# Self-test for tools/bc2cpp/lint_crosscheck.rb: the real tree agrees with the lint
# baseline, and a lint offence or a lint/analysis disagreement is reported.

require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require_relative '../../tools/bc2cpp/lint_crosscheck'

ROOT_DIR = File.expand_path('../..', __dir__)
Fake = Struct.new(:method_missing_files)
failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

check.call('real tree and an empty analysis agree', LintCrosscheck.violations(ROOT_DIR, Fake.new([])).empty?)

p = LintCrosscheck.violations(ROOT_DIR, Fake.new(['/x/mruby-rgss/mrblib/a.rb']))
check.call('method_missing in a linted file with a clean lint cop is a disagreement', p.one? && p.first.include?('mruby-rgss/mrblib/a.rb'))
check.call('method_missing in a fixture file is outside the lint domain',
           LintCrosscheck.violations(ROOT_DIR, Fake.new(['/tmp/fixture.rb'])).empty?)

# The mutation checks run bc2cpp from a temp tree whose gem directories are symlinks to the checkout;
# the baseline's repo-relative file names must still match there.
Dir.mktmpdir do |dir|
  Dir.children(ROOT_DIR).reject { |e| %w[.git tools].include?(e) }.each { |e| FileUtils.ln_s(File.join(ROOT_DIR, e), File.join(dir, e)) }
  run = closed_world_lint_run(root: dir)
  check.call('a symlinked tree keys files like the checkout', run[:new_offences].empty? && run[:stale].empty?)
end

Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, 'scripts/rpg2k'))
  FileUtils.mkdir_p(File.join(dir, 'mruby-rpg2k/mrblib'))
  FileUtils.cp(File.join(ROOT_DIR, 'scripts/rpg2k/closed_world_lint_baseline.txt'), File.join(dir, 'scripts/rpg2k'))
  File.write(File.join(dir, 'mruby-rpg2k/mrblib/x.rb'), "class X\n  def go(o, n)\n    o.send(n)\n  end\nend\n")
  run = closed_world_lint_run(root: dir)
  check.call('an offence outside the baseline is new', run[:new_offences].any? { |o| o.cop == 'Dynamic/Send' })
  check.call('baseline entries missing from the tree are stale', !run[:stale].empty?)
end

probe = <<~'RUBY'
  require 'tmpdir'
  require 'fileutils'
  require File.join(ARGV.fetch(0), 'tools/bc2cpp/lint_crosscheck')
  $lint_scans = 0
  Object.prepend(Module.new do
    def closed_world_lint_run(**args)
      $lint_scans += 1
      super
    end
  end)
  Dir.mktmpdir do |root|
    FileUtils.ln_s(File.join(ARGV[0], 'tools'), File.join(root, 'tools'))
    folder = File.join(root, 'scripts/rpg2k')
    FileUtils.mkdir_p(folder)
    FileUtils.cp(File.join(ARGV[0], 'scripts/rpg2k/closed_world_lint.rb'), folder)
    baseline = File.join(folder, 'closed_world_lint_baseline.txt')
    File.write(baseline, '')
    sources = File.join(root, 'mruby-rpg2k/mrblib')
    FileUtils.mkdir_p(sources)
    path = File.join(sources, 'probe.rb')
    File.write(path, "class Probe; def go(o, n); o.send(n); end; end\n")
    analysis = Struct.new(:method_missing_files).new([])
    first = LintCrosscheck.violations(root, analysis)
    raise 'cold lint did not run' unless $lint_scans == 1 && first.any? { |line| line.include?('Dynamic/Send') }
    RubyParseCache.clear
    raise 'warm lint was recomputed' unless LintCrosscheck.violations(root, analysis) == first && $lint_scans == 1
    File.write(path, "class Probe; def go; eval('1'); end; end\n")
    changed = LintCrosscheck.violations(root, analysis)
    raise 'source edit was hidden' unless $lint_scans == 2 && changed.any? { |line| line.include?('Dynamic/Eval') }
    offence = closed_world_lint_run(root: root)[:offences].first
    File.write(baseline, "1\t#{offence.cop}\t#{offence.file}\t#{offence.snippet}\n")
    before = $lint_scans
    raise 'baseline edit was hidden' unless LintCrosscheck.violations(root, analysis).empty? && $lint_scans == before + 1
    before = $lint_scans
    File.open(File.join(folder, 'closed_world_lint.rb'), 'a') { |file| file.puts '# scanner input changed' }
    raise 'scanner edit was hidden' unless LintCrosscheck.violations(root, analysis).empty? && $lint_scans == before + 1
    added = File.join(sources, 'added.rb')
    File.write(added, "class Added; def go(o, n); o.send(n); end; end\n")
    raise 'new file was hidden' unless LintCrosscheck.violations(root, analysis).any? { |line| line.include?('added.rb') }
    File.delete(added)
    raise 'removed file was hidden' unless LintCrosscheck.violations(root, analysis).empty?
  end
  puts 'lint report cache invalidation: PASS'
RUBY
output, status = Open3.capture2e(RbConfig.ruby, '-e', probe, ROOT_DIR)
check.call('cached lint observes source, baseline and source-set changes', status.success? && output.include?('cache invalidation: PASS'))
warn output unless status.success?

if failures.empty?
  puts 'bc2cpp lint crosscheck check: PASS'
else
  warn "bc2cpp lint crosscheck check: FAIL (#{failures.size})"
  exit 1
end
