#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates CONSTANT_REVIEWED (tools/bc2cpp/constant_reviewed_list.rb) from the engine's bc2cpp type check
# (docs/adr/0491): the list is the set of engine constants the analysis leaves untyped, as type_check.rb --no-sends
# sees them under the closed build.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/constant_reviewed_update.rb [--write]
#
# Without --write it prints the untyped constants and the diff against the checked-in list. Writing is not a review:
# read the source of every added constant first, and list one only when the analysis cannot type it.
require 'json'
require 'tmpdir'
require_relative '../../tools/bc2cpp/type_check_run'
require_relative '../../tools/bc2cpp/constant_reviewed'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
facts = Dir.mktmpdir('constant_reviewed') do |dir|
  result = TypeCheckRun.run(root: root, mrbc: mrbc, workdir: dir, sends: false)
  JSON.parse(File.read(result.facts_path))
end

# An analysis that silently produced no constants would list nothing and --write would empty the list: refuse.
abort 'constant_reviewed_update: the analysis produced no constants; not regenerating the list' if facts['constants'].empty?

untyped = ConstantReviewed.untyped_names(facts['constants'])
listed = ConstantReviewed.load.to_a.sort
engine_count = facts['constants'].count { |c| c['scope'] == 'engine' }
warn "#{engine_count} engine constant(s), #{untyped.size} untyped; listed #{listed.size}"

(untyped - listed).each do |name|
  row = facts['constants'].find { |c| c['name'] == name }
  puts "#{name}\t#{row['file']}:#{row['line']}"
  warn "  + #{name}"
end
(listed - untyped).each { |name| warn "  - #{name} (typed now or gone: prune it)" }

if ARGV.include?('--write')
  File.write(ConstantReviewed::DEFAULT_LIST, ConstantReviewed.list_source(untyped))
  warn "wrote #{untyped.size} name(s) to #{ConstantReviewed::DEFAULT_LIST}"
end
