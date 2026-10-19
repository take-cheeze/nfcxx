#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the TC1017 constant ratchet (docs/adr/0491, tools/bc2cpp/constant_reviewed.rb):
#
#   - the gate logic on hand-built constant rows: an unlisted untyped constant fails; a listed untyped one passes; a
#     listed constant that is typed, or gone, fails (stale); a typed unlisted one passes; core constants are not judged;
#     an empty list with every constant typed passes (the plain "no untyped constants" check);
#   - the gate end to end on fixture programs through scripts/bc2cpp/type_check.rb (the real analysis, needs MRBC):
#     an untyped constant not on the list fails, a listed constant that is typed fails, a clean program passes, and a
#     --files program with no --constants is not gated;
#   - the list file is in its generated form and loads (what constant_reviewed_update.rb --write writes).
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/constant_reviewed_check.rb

require 'json'
require 'open3'
require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/constant_reviewed'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def row(name, type: nil, scope: 'engine', file: 'a.rb', line: 3)
  { 'name' => name, 'type' => type, 'source' => type && 'inferred:literal', 'scope' => scope, 'file' => file,
    'line' => line, 'col' => 1 }
end

# -- the gate on hand-built rows ------------------------------------------------------

puts '== ConstantReviewed.violations'
rows = [row('K::A'), row('K::B', type: 'Integer'), row('K::C'), row('CoreX', scope: 'core')]
unlisted = ConstantReviewed.violations(rows, reviewed: Set[])
check.call('an untyped engine constant that is not listed is one TC1017 violation',
           unlisted.map { |v| v[:message][/constant (\S+) has no type/, 1] } == %w[K::A K::C])
check.call('a typed or core constant is never a violation without a list entry',
           unlisted.none? { |v| v[:message].include?('K::B') || v[:message].include?('CoreX') })
check.call('a listed untyped constant passes', ConstantReviewed.violations(rows, reviewed: Set['K::A', 'K::C']).empty?)
stale = ConstantReviewed.violations(rows, reviewed: Set['K::A', 'K::C', 'K::B'])
check.call('a listed constant that is now typed is a stale violation at its line',
           stale.size == 1 && stale.first[:message].start_with?('listed constant K::B is typed') && stale.first[:line] == 3)
gone = ConstantReviewed.violations(rows, reviewed: Set['K::A', 'K::C', 'K::Gone'])
check.call('a listed name that is no longer an engine constant is a stale violation',
           gone.size == 1 && gone.first[:message].start_with?('listed constant K::Gone is not an engine constant'))
core = ConstantReviewed.violations(rows, reviewed: Set['K::A', 'K::C', 'CoreX'])
check.call('a listed core constant is stale (the list judges engine constants only)',
           core.size == 1 && core.first[:message].start_with?('listed constant CoreX'))
clean = [row('K::B', type: 'Integer'), row('K::D', type: 'Array')]
check.call('every constant typed and an empty list pass (plain "no untyped constants")',
           ConstantReviewed.violations(clean, reviewed: Set[]).empty?)
check.call('the same rows give the same violations in any order',
           ConstantReviewed.violations(rows.reverse, reviewed: Set['K::B', 'K::Gone']).map { |v| v[:message] }.sort ==
             ConstantReviewed.violations(rows, reviewed: Set['K::B', 'K::Gone']).map { |v| v[:message] }.sort)

# -- the list file -------------------------------------------------------------------

puts '== the list file'
Dir.mktmpdir('constant-reviewed-list') do |dir|
  path = File.join(dir, 'list.rb')
  File.write(path, ConstantReviewed.list_source(%w[K::Z K::A]))
  check.call('a written list loads back as the same set', ConstantReviewed.load(path) == Set['K::A', 'K::Z'])
  check.call('list_source is canonical: sorted, one name per line',
             File.read(path).include?("Set[\n  \"K::A\",\n  \"K::Z\",\n].freeze"))
  File.write(path, ConstantReviewed.list_source([]))
  check.call('an empty list loads as an empty set', ConstantReviewed.load(path).empty?)
end
checked_in = ConstantReviewed.load
check.call("the checked-in list is in generated form (#{checked_in.size} name(s))",
           File.read(ConstantReviewed::DEFAULT_LIST) == ConstantReviewed.list_source(checked_in.to_a))

# -- the gate through scripts/bc2cpp/type_check.rb on fixture programs -----------------

mrbc = ENV['MRBC']
abort 'constant_reviewed_check: set MRBC to the host mrbc (the closed build makes it)' unless mrbc && !mrbc.empty?
mrbc = File.expand_path(mrbc)
type_check = File.join(root, 'scripts/bc2cpp/type_check.rb')
env = { 'MRBC' => mrbc, 'BC2CPP_SIG_DIRS' => '' }

FIXTURE = <<~'RUBY'
  class CrHolder
    CR_TYPED = 1
    CR_UNTYPED = CrSource.cr_produce
  end
  class CrSource
    def self.cr_produce
      [1, 2].cr_unknown_send
    end
  end
RUBY
CLEAN = <<~'RUBY'
  class CrClean
    CR_CLEAN = 2
  end
RUBY

# The gate's result for a list: the exit status and the TC1017 diagnostics of a re-render of the kept facts.
render = lambda do |dir, facts, list|
  report = File.join(dir, "render-#{File.basename(list, '.rb')}.json")
  _out, err, status = Open3.capture3(env, RbConfig.ruby, type_check, '--facts', facts, '--constants', list,
                                     '--format', 'json', '--out', report, chdir: dir)
  abort "constant_reviewed_check: re-render failed: #{err}" unless status.exitstatus <= 1
  [status.exitstatus, JSON.parse(File.read(report))['diagnostics'].select { |d| d['code'] == ConstantReviewed::CODE }]
end

Dir.mktmpdir('constant-reviewed-fixture') do |dir|
  File.write(File.join(dir, 'fixture.rb'), FIXTURE)
  File.write(File.join(dir, 'clean.rb'), CLEAN)
  write_list = lambda do |name, names|
    File.join(dir, "list-#{name}.rb").tap { |path| File.write(path, ConstantReviewed.list_source(names)) }
  end

  # One analysis of the fixture (no list: a --files program is not gated), kept for the re-renders below.
  _out, err, status = Open3.capture3(env, RbConfig.ruby, type_check, '--files', 'fixture.rb', '--keep', File.join(dir, 'kept'),
                                     '--no-sends', '--format', 'json', '--out', File.join(dir, 'fixture.json'), chdir: dir)
  check.call('the fixture analysis runs (its stderr is quiet on success)', status.success?)
  facts = File.join(dir, 'kept', 'facts.json')
  constants = JSON.parse(File.read(facts))['constants']
  untyped = constants.find { |c| c['name'].end_with?('CR_UNTYPED') }
  typed = constants.find { |c| c['name'].end_with?('CR_TYPED') }
  check.call('the fixture has an untyped constant and a typed one', untyped && untyped['type'].nil? && typed && typed['type'])
  untyped_name = untyped['name']
  typed_name = typed['name']

  puts '== the gate on the fixture (type_check.rb --facts --constants)'
  status_none, diags_none = render.call(dir, facts, write_list.call('empty', []))
  check.call('an untyped constant not on the list fails: exit 1 with one TC1017 error',
             status_none == 1 && diags_none.size == 1 && diags_none.first['message'].include?(untyped_name) &&
               diags_none.first['severity'] == 'error')
  status_listed, diags_listed = render.call(dir, facts, write_list.call('listed', [untyped_name]))
  check.call('a listed untyped constant passes: exit 0 with no TC1017', status_listed.zero? && diags_listed.empty?)
  status_stale, diags_stale = render.call(dir, facts, write_list.call('stale', [untyped_name, typed_name]))
  check.call('a listed constant that is now typed fails (stale): exit 1 with one TC1017 at its line',
             status_stale == 1 && diags_stale.size == 1 && diags_stale.first['message'].include?(typed_name) &&
               diags_stale.first['line'].positive?)
  status_gone, diags_gone = render.call(dir, facts, write_list.call('gone', [untyped_name, 'CrHolder::CR_NO_SUCH']))
  check.call('a listed name the program does not have fails (stale): exit 1',
             status_gone == 1 && diags_gone.size == 1 && diags_gone.first['message'].include?('CR_NO_SUCH'))

  puts '== a clean program and a program of your own'
  _o, _e, clean_status = Open3.capture3(env, RbConfig.ruby, type_check, '--files', 'clean.rb', '--no-sends', '--format', 'json',
                                        '--out', File.join(dir, 'clean.json'), '--constants', write_list.call('clean', []),
                                        chdir: dir)
  clean_diags = JSON.parse(File.read(File.join(dir, 'clean.json')))['diagnostics'].select { |d| d['code'] == ConstantReviewed::CODE }
  check.call("a clean program with an empty list passes: exit 0 with no TC1017 (exit #{clean_status.exitstatus}, #{clean_diags.size} TC1017, #{_e.lines.first.to_s.strip})", clean_status.success? && clean_diags.empty?)
  _o, _e, own_status = Open3.capture3(env, RbConfig.ruby, type_check, '--files', 'fixture.rb', '--no-sends', '--format', 'json',
                                      '--out', File.join(dir, 'own.json'), chdir: dir)
  own = JSON.parse(File.read(File.join(dir, 'own.json')))['diagnostics'].select { |d| d['code'] == ConstantReviewed::CODE }
  check.call('a --files program with no --constants is not gated (exit 0, no TC1017)', own_status.success? && own.empty?)
end

if failures.empty?
  puts "constant_reviewed_check: ok (#{checked_in.size} listed)"
else
  abort "constant_reviewed_check: #{failures.size} failure(s): #{failures.join('; ')}"
end
