#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the source-annotation review gates (tools/bc2cpp/source_review.rb; NOMETHOD ADR 0226, PROVEN_MISS ADR 0275,
# STRICT_HINT ADR 0419).
#
#   - fixtures (no compiler): annotation parsing, the lookup through backslash continuations, the DIRECT_RAISE rewrite,
#     the unreviewed-site gates, the listing parsers, and source_review_migrate.rb writing and merging comments;
#   - with MRBC (a host mrbc, the closed build makes one): a full engine run's review sites must each carry their
#     annotation, and every gate annotation in the engine sources must name a site of this run (no stale ones).
#
#   ruby scripts/bc2cpp/source_review_check.rb            # fixtures only
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/source_review_check.rb
require 'json'
require 'open3'
require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/review_sites'
require_relative '../../tools/bc2cpp/proven_miss_reviewed'
require_relative '../../tools/bc2cpp/strict_hints'
require_relative '../../tools/bc2cpp/source_review'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end

GATES = %w[nomethod proven_miss strict_hint constant].freeze

puts '== annotation parsing'
check.call('a comment names its keys, split on commas, before the reason',
           SourceReview.annotation_keys('  # bc2cpp-reviewed: nomethod a, nomethod b -- dead') == ['nomethod a', 'nomethod b'])
check.call('a comment with no reason names its key',
           SourceReview.annotation_keys("# bc2cpp-reviewed: constant\n") == ['constant'])
check.call('a string that mentions the tag is not an annotation',
           SourceReview.annotation_keys("x = 'bc2cpp-reviewed: nomethod a'") == [])
check.call('an ordinary comment is not an annotation', SourceReview.annotation_keys('# see bc2cpp-reviewed docs') == [])

Dir.mktmpdir('source_review_check') do |dir|
  src = File.join(dir, 'a.rb')
  File.write(src, <<~RUBY)
    def f
      # bc2cpp-reviewed: nomethod foo -- above
      x.foo
      y.bar # not annotated
      z = 1 \\
        + 2
      # bc2cpp-reviewed: nomethod baz -- above the continued statement
      w = q \\
        .baz
    end
  RUBY

  puts '== lookup'
  check.call('an annotation on the line above the site counts', SourceReview.annotated?(src, 3, 'nomethod foo'))
  check.call('a line without an annotation does not', !SourceReview.annotated?(src, 4, 'nomethod bar'))
  check.call('a key of another name does not match', !SourceReview.annotated?(src, 3, 'nomethod bar'))
  check.call('a site on the second line of a continuation finds the annotation above the statement',
             SourceReview.annotated?(src, 9, 'nomethod baz'))
  check.call('a missing file is not reviewed', !SourceReview.annotated?(File.join(dir, 'nope.rb'), 3, 'nomethod foo'))
  check.call('a line 0 site (no source line) is not reviewed', !SourceReview.annotated?(src, 0, 'nomethod foo'))

  puts '== gates'
  scope = ReviewScope::ALL
  site = ->(file, line, called) { { owner: 'A', called: called, file: file, line: line, site: "#{file}:#{line}" } }
  nom = [site.call(src, 3, 'foo'), site.call(src, 4, 'bar')].map { |s| s.merge(key: "#{s[:site]} -> #{s[:called]}") }
  viols = NomethodReviewed.violations(nom, scope: scope)
  check.call('an unannotated nomethod site is a violation, an annotated one is not',
             viols.size == 1 && viols.first.include?("#{src}:4 -> bar"))
  no_line = [site.call('?', 0, 'foo').merge(key: '?:0 -> foo')]
  check.call('a site with no source line is a violation',
             NomethodReviewed.violations(no_line, scope: scope).size == 1)

  raw = "r1 = bc2cpp_nomethod_named(M, recv, \"foo\", 0); /* CLOSED_WORLD nomethod: recv.foo @ #{src}:3 */\n" \
        "r2 = bc2cpp_nomethod_named(M, recv, \"bar\", 0); /* CLOSED_WORLD nomethod: recv.bar @ #{src}:4 */\n"
  rewritten = NomethodReviewed.direct_raise(raw)
  check.call('DIRECT_RAISE rewrites only the annotated site',
             rewritten.include?('bc2cpp_nomethod_raise_named(M, recv, "foo", 0)') &&
             rewritten.include?('bc2cpp_nomethod_named(M, recv, "bar", 0)'))

  ann = File.join(dir, 'ann.rb')
  File.write(ann, "# bc2cpp-reviewed: strict_hint typed x, proven_miss fresh_new A.foo -- r\nx.foo\n")
  hint = { owner: 'A', called: 'x', family: 'typed', file: ann, line: 2, key: 'k' }
  check.call('an annotated forced hint is not a violation, an unannotated one is',
             StrictHints.violations([hint], scope: scope).empty? &&
             StrictHints.violations([hint.merge(file: src, line: 3)], scope: scope).size == 1)
  miss = { owner: 'A', called: 'foo', kind: 'fresh_new', klass: 'A', file: ann, line: 2, key: 'k' }
  check.call('an annotated proven miss (kind and class) is not a violation, a different name is',
             ProvenMiss.violations([miss], scope: scope).empty? &&
             ProvenMiss.violations([miss.merge(called: 'bar')], scope: scope).size == 1)

  puts '== listing parsers'
  err = "  NOMETHOD a.rb:3 -> foo [self]\n  STRICT_HINT_SITE a.rb:4 -> bar (TYPED)\n  PROVEN_MISS a.rb:5 -> baz (fresh_new B)\n"
  nomethod = NomethodReviewed.parse_listing(err)
  check.call('nomethod listing: site, called name, self receiver',
             nomethod.size == 1 && nomethod.first[:file] == 'a.rb' && nomethod.first[:line] == 3 &&
             nomethod.first[:called] == 'foo' && nomethod.first[:self_receiver])
  hints = StrictHints.parse_listing(err)
  check.call('strict hint listing: family is lower case, the annotation key uses it',
             hints.size == 1 && hints.first[:family] == 'typed' && hints.first[:called] == 'bar')
  misses = ProvenMiss.parse_listing(err)
  check.call('proven miss listing: kind and class',
             misses.size == 1 && misses.first[:kind] == 'fresh_new' && misses.first[:klass] == 'B')

  puts '== migration'
  migrate = File.join(root, 'scripts/bc2cpp/source_review_migrate.rb')
  mig = File.join(dir, 'm.rb')
  File.write(mig, "def g\n  h.foo + h.bar\n  c.qux\nend\n")
  json = File.join(dir, 'sites.json')
  File.write(json, JSON.generate([
                                   { gate: 'nomethod', spec: 'foo', file: mig, line: 2, reason: 'r' },
                                   { gate: 'nomethod', spec: 'bar', file: mig, line: 2, reason: 'r' },
                                   { gate: 'nomethod', spec: 'qux', file: mig, line: 3 }
                                 ]))
  _out, _err, status = Open3.capture3(RbConfig.ruby, migrate, json, '--write')
  written = File.read(mig)
  check.call('the migration writes one comment per line, listing every key on it',
             status.success? && written.include?("  # bc2cpp-reviewed: nomethod bar, nomethod foo -- r\n  h.foo + h.bar\n") &&
             written.include?("  # bc2cpp-reviewed: nomethod qux -- reviewed before the source-annotation migration\n  c.qux\n"))
  check.call('the migrated file is annotated for every site',
             SourceReview.annotated?(mig, 3, 'nomethod foo') && SourceReview.annotated?(mig, 5, 'nomethod qux'))
end

puts '== full run'
mrbc = ENV['MRBC']
if mrbc.to_s.empty?
  puts '  (MRBC unset: the full-run exactness check is skipped)'
else
  sites = ReviewSites.all(root, mrbc)
  puts "  #{sites.size} review site(s) from the engine's full runs"
  unreviewed = sites.reject { |s| SourceReview.annotated?(s[:file], s[:line], SourceReview.key(s[:gate], s[:spec])) }
  check.call("every review site is annotated (#{unreviewed.size} unannotated)", unreviewed.empty?)
  unreviewed.first(20).each { |s| puts "    unannotated: #{s[:gate]} #{s[:spec]} at #{s[:file]}:#{s[:line]}" }

  files = Dir.glob(File.join(root, '{mruby-rpg2k,mruby-lcf,mruby-rgss}/**/*.rb')).sort
  by_file = sites.group_by { |s| s[:file] }
  stale = []
  files.each do |file|
    SourceReview.annotations(file).each do |line, key|
      next unless GATES.include?(key.split(' ', 2).first)

      used = (by_file[file] || []).any? do |s|
        SourceReview.key(s[:gate], s[:spec]) == key &&
          SourceReview.annotation_lines(file, s[:line]).include?(line)
      end
      stale << "#{file.delete_prefix("#{root}/")}:#{line} #{key}" unless used
    end
  end
  check.call("every gate annotation names a site of this run (#{stale.size} stale)", stale.empty?)
  stale.first(20).each { |s| puts "    stale: #{s}" }
end

puts
if failures.empty?
  puts 'source_review_check: ok'
else
  abort "source_review_check: #{failures.size} failure(s): #{failures.join('; ')}"
end
