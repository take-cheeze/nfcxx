#!/usr/bin/env ruby
# frozen_string_literal: true

# Check the bc2cpp type check (docs/adr/0412, scripts/bc2cpp/type_check.rb, tools/bc2cpp/type_facts.rb and
# type_check_report.rb).
#
# 1. The report front-end on a hand-written facts file (no MRBC): the exact `file:line:col: severity: message [CODE]`
#    lines, errors before warnings before info, the exit status (1 with an error, 0 without), the TSV and JSON shapes,
#    the ranking of the signature suggestions (most by-name lines first) and what is NOT a suggestion (an already typed
#    parameter, a block parameter, a source no signature can name).
# 2. The analysis on fixture programs (needs MRBC): a declared type that disagrees with the inference is reported with
#    the exact message and the file:line of its annotation (a fixnum/symbol argument, a class argument and a class
#    return), an annotation token bc2cpp ignores and an annotation with the wrong parameter count are errors, inferred
#    parameter / ivar / return types and their reasons are in the facts, a by-name send ranks its parameter, and the
#    facts change no generated code (the C++ is byte-identical with BC2CPP_TYPE_FACTS on and off).
#
# BC2CPP_TOOLS_DIR points the script at a mutant copy of tools/bc2cpp (type_check_mutation_check.rb).
#
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/type_check_check.rb [--render-only]

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

ROOT = File.expand_path('../..', __dir__)
TOOLS = ENV['BC2CPP_TOOLS_DIR'] || File.join(ROOT, 'tools/bc2cpp')
$LOAD_PATH.unshift(TOOLS)
require 'receiver_proof_report_columns'

SCRIPT = File.join(ROOT, 'scripts/bc2cpp/type_check.rb')
RENDER_ONLY = ARGV.include?('--render-only')

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

type_check = lambda do |*args, chdir: nil|
  env = { 'BC2CPP_TOOLS_DIR' => TOOLS }
  env['MRBC'] = ENV['MRBC'] if ENV['MRBC']
  opts = chdir ? { chdir: chdir } : {}
  Open3.capture3(env, RbConfig.ruby, SCRIPT, *args, **opts)
end

# ------------------------------------------------------------------------------------------------ 1. front-end
def param(pos, name, type, source, reason = nil)
  { 'pos' => pos, 'name' => name, 'type' => type, 'source' => source, 'reason' => reason }
end

def meth(owner, name, line, params, ret, scope: 'engine')
  { 'owner' => owner, 'name' => name, 'file' => 'app/shape.rb', 'line' => line, 'col' => 3, 'scope' => scope, 'req' => params.size,
    'opt' => 0, 'rest' => false, 'visibility' => 'public', 'params' => params, 'return' => ret, 'annotated' => false }
end

FACTS = {
  'version' => 1,
  'methods' => [
    meth('Shape', 'area', 10, [param(1, 'scale', 'Integer', 'annotation'), param(2, 'unit', nil, nil, 'poly:3')],
         { 'type' => 'Integer', 'source' => 'inferred:return-analysis', 'reason' => nil }),
    meth('Shape', 'label', 20, [], { 'type' => nil, 'source' => nil, 'reason' => 'send_result:to_s(native)' }),
    meth('Shape', 'draw', 30, [param(1, 'canvas', nil, nil, 'no_candidate:outside_token')],
         { 'type' => nil, 'source' => nil, 'reason' => 'ivar:@sprite+param' }),
    meth('Shape', 'each_cell', 40, [param(1, 'cell', nil, nil, 'no_candidate:block_param')],
         { 'type' => 'Array', 'source' => 'inferred:return-analysis', 'reason' => nil }),
    meth('Array', 'sum2', 5, [param(1, 'x', nil, nil, 'poly:2')], { 'type' => nil, 'reason' => 'unreadable' }, scope: 'core')
  ],
  'ivars' => [
    { 'owner' => 'Shape', 'name' => '@sprite', 'type' => nil, 'element' => nil, 'source' => nil, 'reason' => 'opaque:parameter',
      'file' => 'app/shape.rb', 'line' => 12, 'col' => 5, 'scope' => 'engine' },
    { 'owner' => 'Shape', 'name' => '@w', 'type' => 'Integer', 'element' => nil, 'source' => 'inferred:ivar-layout',
      'reason' => nil, 'file' => 'app/shape.rb', 'line' => 11, 'col' => 5, 'scope' => 'engine' }
  ],
  'constants' => [{ 'name' => 'Shape::ORIGIN', 'owner' => 'Shape', 'type' => 'Point', 'source' => 'inferred:constructed', 'file' => 'app/shape.rb', 'line' => 3, 'col' => 1, 'scope' => 'engine' }],
  'annotations' => [
    { 'owner' => 'Shape', 'name' => 'area', 'file' => 'app/shape.rb', 'line' => 9, 'col' => 1, 'source' => 'annotation', 'tokens' => ['fixnum'],
      'return_token' => nil, 'ignored' => ['Gizmo'], 'arity_mismatch' => 'lists 1 parameter(s), method takes 2' }
  ],
  'contradictions' => [
    { 'owner' => 'Shape', 'name' => 'area', 'slot' => '1', 'declared' => 'Symbol', 'inferred' => 'Integer', 'file' => 'app/shape.rb',
      'line' => 9, 'col' => 1, 'source' => 'annotation', 'message' => 'Shape#area parameter 1: declared Symbol, inferred Integer' }
  ],
  'signature_diagnostics' => [
    { 'file' => 'sig/shape.rbs', 'line' => 4, 'col' => 3, 'severity' => 'error', 'code' => 'TC1002', 'message' => 'unsupported RBS syntax: intersection type' }
  ]
}.freeze

def row(owner, source, detail, before, why: '-', existing: '-', floor_after: '-', after: '-', hyp: '-', where: 'app/shape.rb:1', answerers: '-')
  cols = ReceiverProofReport::COLUMNS
  vals = cols.to_h { |c| [c, '-'] }
  vals.merge!('irep' => '1', 'idx' => '1', 'gem' => 'x', 'owner' => owner, 'name' => 'size', 'argc' => '0', 'source' => source,
              'detail' => detail, 'existing' => existing, 'why' => why, 'before' => before.to_s, 'floor_after' => floor_after.to_s,
              'after' => after.to_s, 'hyp' => hyp, 'where' => where, 'answerers' => answerers)
  cols.map { |c| vals[c] }.join("\t")
end

ROWS = [
  row('Shape#draw', 'argument', 'arg1', 2, floor_after: 0, where: 'app/shape.rb:31', answerers: 'Canvas|Image'),
  row('Shape#draw', 'argument', 'arg1', 1, floor_after: 1, where: 'app/shape.rb:32', answerers: 'Canvas|Image'),
  row('Shape#draw', 'call', 'label', 5, floor_after: 0, where: 'app/shape.rb:21'),
  row('Shape#draw', 'ivar', 'sprite', 4, floor_after: 0, where: 'app/shape.rb:33'),
  row('Shape#each_cell', 'argument', 'arg1', 9, why: 'no_candidate:block_param', where: 'app/shape.rb:41'),
  row('Shape#area', 'argument', 'arg1', 7, where: 'app/shape.rb:11'),
  row('Shape#draw', 'merge', 'Array|call:x', 6, where: 'app/shape.rb:34'),
  row('Shape#draw', 'argument', 'arg1', 50, existing: 'Canvas', where: 'app/shape.rb:35')
].freeze

puts '== front-end on a hand-written facts file'
Dir.mktmpdir do |dir|
  facts = File.join(dir, 'facts.json')
  rows = File.join(dir, 'rows.tsv')
  File.write(facts, JSON.generate(FACTS))
  File.write(rows, "#{ROWS.join("\n")}\n")
  out, err, st = type_check.call('--facts', facts, '--rows', rows, '--top', '3')
  check.call("exit status 1 with an error diagnostic (#{st.exitstatus}: #{err.lines.first&.strip})", st.exitstatus == 1)
  lines = out.lines.map(&:chomp)
  diag = lines.take_while { |l| !l.empty? }
  check.call('the contradiction is an exact tsc-style line',
             diag.include?('app/shape.rb:9:1: error: Shape#area parameter 1: declared Symbol, inferred Integer (annotation) [TC1001]'))
  check.call('an unusable signature file is an error at its own file:line:col',
             diag.include?('sig/shape.rbs:4:3: error: unsupported RBS syntax: intersection type [TC1002]'))
  check.call('an ignored annotation token is an error',
             diag.any? { |l| l.start_with?('app/shape.rb:9:1: error: Shape#area: annotation token `Gizmo` is ignored') && l.end_with?('[TC1004]') })
  check.call('an annotation with the wrong parameter count is an error',
             diag.include?('app/shape.rb:9:1: error: Shape#area: annotation lists 1 parameter(s), method takes 2 [TC1004]'))
  sev = diag.map { |l| l[/: (error|warning|info): /, 1] }
  check.call('errors come before warnings before info', sev == sev.sort_by { |s| %w[error warning info].index(s) })
  check.call('every diagnostic matches file:line:col: severity: message [CODE]',
             diag.all? { |l| l.match?(/\A[^:\s]+:\d+:\d+: (error|warning|info): .+ \[TC\d{4}\]\z/) })
  tops = diag.grep(/\[TC3001\]/)
  check.call('--top 3 prints three suggestions, the most by-name lines first',
             tops.size == 3 && tops.map { |l| l[/act on (\d+)/, 1].to_i }.sort.reverse == [5, 4, 3] &&
             tops.any? { |l| l.start_with?('app/shape.rb:20:3: info: suggestion #1: a signature for return of #label (1 definition) would act on 5 by-name send line(s) at 1 site(s)') } &&
             tops.any? { |l| l.include?('suggestion #3: a signature for Shape#draw parameter 1 (canvas) would act on 3 by-name send line(s) at 2 site(s); up to 2 removable') })
  ranked = lines.grep(/\A\s+\d+\.\s+\d+ lines/)
  check.call('the ranked list is ordered by by-name lines', ranked.map { |l| l[/\A\s+\d+\.\s+(\d+) lines/, 1].to_i } == [5, 4, 3])
  check.call('a source no signature can name (merge) and an already proven receiver are not suggestions',
             ranked.size == 3 && ranked.none? { |l| l.include?('53 lines') || l.include?('9 lines') })
  check.call('a typed parameter is not a suggestion', ranked.none? { |l| l.include?('Shape#area') })
  check.call('a block parameter is not a suggestion', ranked.none? { |l| l.include?('each_cell') })
  check.call('the summary counts engine scope only (core method excluded)', out.include?('methods                      4'))
  check.call('typed parameter percentage is exact (1 of 4)', out.include?('parameters typed             1 of      4  25.0%'))
  check.call('the reason bucket of an untyped ivar is listed', out.include?('opaque:parameter'))

  q, _e, qs = type_check.call('--facts', facts, '--rows', rows, '-q')
  check.call('-q prints diagnostics only', qs.exitstatus == 1 && q.lines.all? { |l| l.match?(/\A\S+:\d+:\d+: /) })

  # One warning keeps "warnings do not fail" a real case: the annotation diagnostics are errors now, and the
  # signature warning (TC1006) is the only warning source the render-only facts can carry.
  clean = FACTS.merge('contradictions' => [],
                      'signature_diagnostics' => [{ 'file' => 'app/shape.rb', 'line' => 9, 'col' => 1, 'severity' => 'warning',
                                                    'code' => 'TC1006', 'message' => 'Shape#area parameter 1: the `# bc2cpp:` comment wins over signature type Symbol' }],
                      'annotations' => Array(FACTS['annotations']).map { |a| a.merge('ignored' => [], 'arity_mismatch' => nil) })
  File.write(facts, JSON.generate(clean))
  _o, _e, st2 = type_check.call('--facts', facts, '--rows', rows)
  check.call('no error diagnostics: exit status 0 (warnings and info do not fail)', st2.exitstatus.zero?)

  tsv, _e, _s = type_check.call('--facts', facts, '--format', 'tsv')
  tl = tsv.lines.map { |l| l.chomp.split("\t", -1) }
  check.call('TSV header', tl.first == %w[kind owner name slot type source reason file line col])
  check.call('TSV param row', tl.include?(['param', 'Shape', 'draw', 'canvas', '', '', 'no_candidate:outside_token', 'app/shape.rb', '30', '3']))
  check.call('TSV return row carries the reason', tl.include?(['return', 'Shape', 'label', 'return', '', '', 'send_result:to_s(native)', 'app/shape.rb', '20', '3']))
  check.call('TSV ivar row', tl.include?(['ivar', 'Shape', '@w', '', 'Integer', 'inferred:ivar-layout', '', 'app/shape.rb', '11', '5']))
  check.call('TSV: core scope methods are left out', tl.none? { |r| r[1] == 'Array' })

  js, _e, _s = type_check.call('--facts', facts, '--rows', rows, '--format', 'json')
  doc = JSON.parse(js)
  check.call('JSON summary', doc['summary']['params'] == 4 && doc['summary']['params_typed'] == 1 && doc['summary']['ivars_typed'] == 1)
  check.call('JSON suggestions are ranked and carry the sites',
             doc['suggestions'].map { |s| s['by_name_lines'] } == [5, 4, 3] && doc['suggestions'].first['where'] == ['app/shape.rb:21'])
  check.call('JSON diagnostics are structured', doc['diagnostics'].all? { |d| %w[file line col severity code message].all? { |k| d.key?(k) } })
end

# ------------------------------------------------------------------------------------------------ 2. analysis
if RENDER_ONLY || !ENV['MRBC']
  puts(RENDER_ONLY ? '-- analysis half skipped (--render-only)' : '-- SKIP analysis half: set MRBC')
else
  CONTRA = <<~RUBY
    class TcSym
      # bc2cpp: (symbol)
      def take(n)
        n
      end

      # bc2cpp: (TcOther)
      def pick(o)
        o
      end

      # bc2cpp: () -> TcOther
      def make
        TcSym.new
      end

      # bc2cpp: (String) -> String
      def label(s)
        s
      end

      # bc2cpp: (Nonesuch, fixnum)
      def two(a)
        a
      end

      def go
        take(3)
        pick(TcSym.new)
        make
        two(1)
      end
    end

    class TcOther
      def hi
        1
      end
    end
  RUBY
  SENDS = <<~RUBY
    class TcA
      def size
        1
      end
    end

    class TcB
      def size
        2
      end
    end

    class TcUse
      def initialize
        @h = {}
        @w = 4
      end

      def put(k, v)
        @h[k] = v
      end

      def run(k)
        use(@h[k])
      end

      def use(o)
        o.size
      end

      def width
        @w
      end
    end

    class TcMain
      def go
        u = TcUse.new
        u.put(1, TcA.new)
        u.put(2, TcB.new)
        u.run(1)
        u.width
      end
    end
  RUBY

  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'contra.rb'), CONTRA)
    File.write(File.join(dir, 'sends.rb'), SENDS)
    line_of = ->(src, text) { src.lines.index { |l| l.include?(text) } + 1 }

    # TC1005 (ADR 0439): an index op on a receiver no nil check dominates is an error; a nil check first clears it.
    NILIDX = <<~RUBY
      class TcNil
        def initialize
          @items = nil
        end

        def fill
          @items = [1, 2]
        end

        def first_unguarded
          @items[0]
        end

        def first_guarded
          return nil unless @items
          @items[0]
        end

        def set_unguarded(v)
          @items[0] = v
        end
      end
    RUBY
    File.write(File.join(dir, 'nilidx.rb'), NILIDX)
    puts '== nilable index (fixture nilidx.rb)'
    nout, _nerr, nst = type_check.call('--files', 'nilidx.rb', '--no-sends', '-q', chdir: dir)
    nlines = nout.lines.map(&:chomp)
    nu = line_of.(NILIDX, 'def first_unguarded') + 1
    ng = line_of.(NILIDX, 'def first_guarded') + 2
    check.call('an unguarded index read on a nilable ivar is a TC1005 warning',
               nlines.include?("nilidx.rb:#{nu}:1: warning: TcNil#first_unguarded: index `[]` on a receiver that may be nil; check it for nil first (ADR 0439) [TC1005]"))
    check.call('an unguarded index write on a nilable ivar is a TC1005 warning',
               nlines.any? { |l| l.start_with?("nilidx.rb:#{line_of.(NILIDX, 'def set_unguarded') + 1}:1: warning: TcNil#set_unguarded: index `[]=`") })
    check.call('a nil check before the index clears TC1005', nlines.none? { |l| l.start_with?("nilidx.rb:#{ng}:") })
    check.call('the nilable-index fixture exits 0 (a warning does not fail)', nst.exitstatus.zero?)

    puts '== contradictions and annotation warnings (fixture contra.rb)'
    out, err, st = type_check.call('--files', 'contra.rb', '--no-sends', '-q', chdir: dir)
    check.call("exit status 1 (#{st.exitstatus}) #{err.lines.first&.strip}", st.exitstatus == 1)
    lines = out.lines.map(&:chomp)
    check.call('fixnum/symbol argument contradiction, exact text and the annotation line',
               lines.include?("contra.rb:#{line_of.(CONTRA, 'bc2cpp: (symbol)')}:1: error: TcSym#take parameter 1: declared Symbol, inferred Integer (annotation) [TC1001]"))
    check.call('class argument contradiction',
               lines.include?("contra.rb:#{line_of.(CONTRA, 'bc2cpp: (TcOther)')}:1: error: TcSym#pick parameter 1: declared TcOther, inferred TcSym (annotation) [TC1001]"))
    check.call('class return contradiction',
               lines.include?("contra.rb:#{line_of.(CONTRA, 'bc2cpp: () -> TcOther')}:1: error: TcSym#make return type: declared TcOther, inferred TcSym (annotation) [TC1001]"))
    two = line_of.(CONTRA, 'bc2cpp: (Nonesuch, fixnum)')
    check.call('an unknown class token is an error at the annotation line',
               lines.any? { |l| l.start_with?("contra.rb:#{two}:1: error: TcSym#two: annotation token `Nonesuch` is ignored") })
    check.call('an annotation with too many parameters is an error',
               lines.include?("contra.rb:#{two}:1: error: TcSym#two: annotation lists 2 parameter(s), method takes 1 [TC1004]"))
    check.call('nothing else is an error', lines.count { |l| l.include?(': error: ') } == 5)
    check.call('a String token is a known class, not an ignored token', lines.none? { |l| l.include?('`String` is ignored') })

    puts '== inferred types, reasons and send ranking (fixture sends.rb)'
    keep = File.join(dir, 'keep')
    js, err, st = type_check.call('--files', 'sends.rb', '--format', 'json', '--keep', keep, chdir: dir)
    check.call("clean fixture exits 0 (#{st.exitstatus}) #{err.lines.first&.strip}", st.exitstatus.zero?)
    doc = begin
      JSON.parse(js)
    rescue JSON::ParserError
      { 'methods' => [], 'ivars' => [], 'suggestions' => [], 'summary' => {} }
    end
    m = ->(owner, name) { doc['methods'].find { |x| x['owner'] == owner && x['name'] == name } }
    use = m.call('TcUse', 'use')
    check.call('the unresolved parameter has a reason bucket', use && use['params'][0]['type'].nil? && use['params'][0]['reason'].to_s.start_with?('no_candidate'))
    check.call('its declaration site is def line:col', use && use['line'] == line_of.(SENDS, 'def use(o)') && use['col'] == 3 && use['file'] == 'sends.rb')
    check.call('a parameter every call site fills with a Fixnum is typed Integer from call-sites',
               (m.call('TcUse', 'put')['params'][0]['type'] == 'Integer'))
    ivw = doc['ivars'].find { |i| i['owner'] == 'TcUse' && i['name'] == '@w' }
    check.call('an ivar only ever assigned a Fixnum is typed Integer', ivw && ivw['type'] == 'Integer')
    check.call('the Fixnum-returning reader has an inferred return type', m.call('TcUse', 'width')['return']['type'] == 'Integer')
    sug = doc['suggestions'].first
    check.call('the by-name send ranks its parameter', sug && sug['target'] == 'TcUse#use parameter 1 (o)' && sug['by_name_lines'] >= 1 &&
                                                       sug['file'] == 'sends.rb' && sug['line'] == use['line'])

    puts '== the facts change no generated code'
    run_gen = lambda do |facts_on|
      env = { 'MRBC' => ENV.fetch('MRBC') }
      env['BC2CPP_TYPE_FACTS'] = File.join(dir, 'gen_facts.json') if facts_on
      require File.join(ROOT, 'scripts/bc2cpp/fixture_runtime')
      gen = Dir.mktmpdir { |d| Bc2cppFixtureRuntime.generate(SENDS, d).first }
      gen
    end
    off = run_gen.call(false)
    ENV['BC2CPP_TYPE_FACTS'] = File.join(dir, 'gen_facts.json')
    ENV['BC2CPP_TYPE_FACTS_ROOT'] = dir
    on = run_gen.call(true)
    ENV.delete('BC2CPP_TYPE_FACTS')
    check.call('byte-identical C++ with BC2CPP_TYPE_FACTS on and off', on == off && File.exist?(File.join(dir, 'gen_facts.json')))
  end
end

if failures.empty?
  puts 'ok'
else
  warn "FAILED: #{failures.size}"
  failures.each { |f| warn "  - #{f}" }
  exit 1
end
