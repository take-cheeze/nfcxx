#!/usr/bin/env ruby
# frozen_string_literal: true

# Candidate RBS against runtime evidence. A candidate directory (type_check.rb --emit-rbs or --emit-rbs-suggestions)
# must not declare a required parameter or a return type that a BC2CPP_TRACE_TYPES dump observed a different runtime
# class at. `type_check.rb --all` against the same sources cannot see this: it reads the same inference that wrote the
# candidate. Host only; it needs the pinned RBS and Prism gems.
#
#   bundle exec ruby scripts/bc2cpp/rbs_suggestion_trace_check.rb CANDIDATE_DIR DUMP.tsv... [--hierarchy TSV]
#   bundle exec ruby scripts/bc2cpp/rbs_suggestion_trace_check.rb      # the fixture self-test (no arguments)
#
# Exit status: 0 no contradiction, 1 at least one contradiction (one line each, `[TRACE_CONTRADICTION]`), 2 usage or
# unreadable input.
#
# Compared: each required positional parameter (trace kind `req`, index = position) and each method return, except
# `initialize` (Ruby discards its value). Not compared, and counted in the summary: a site with no calls, a site whose
# class table overflowed (its classes are unknown), singleton methods (the trace key `X.singleton#m` is dropped by
# trace_types.rb), optional / rest / keyword parameters, ivars and constants (not traced), and array elements and hash
# keys / values (the PARAM_ELEM rows, which TraceTypes::Candidates.read_dumps does not read).
#
# A class is a contradiction only when the lookup order it is checked against is complete: a core class (mruby's
# hierarchy from CoreHierarchySigs), or a program class whose superclass chain reaches a core class through --hierarchy.
# Modules are never decided (a program may include one into a core class). Anything else is unknown, not a failure.
TOOLS = File.expand_path('../../tools/bc2cpp', __dir__)
$LOAD_PATH.unshift(TOOLS) unless $LOAD_PATH.include?(TOOLS)

require 'optparse'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'rbs'
require_relative 'trace_types'
require 'core_hierarchy_sigs'

module RbsSuggestionTrace
  Error = Class.new(StandardError)
  Sig = Struct.new(:owner, :name, :params, :ret, :file, :line)
  Ctx = Struct.new(:classes, :hierarchy)
  Ancestry = Struct.new(:names, :complete, :core)

  module_function

  # ---- the candidate side -------------------------------------------------------------------------------------------

  # [class name => :class | :module, [Sig]] for every .rbs under dir. Singleton and overloaded methods are not compared.
  def read_candidates(dir)
    files = Dir.glob(File.join(dir, '**', '*.rbs')).sort
    raise Error, "#{dir}: no .rbs files" if files.empty?

    classes = {}
    sigs = []
    files.each do |path|
      begin
        _buffer, _directives, decls = RBS::Parser.parse_signature(File.read(path))
      rescue RBS::ParsingError => e
        raise Error, "#{path}: #{e.message}"
      end
      walk(decls, '', path, classes, sigs)
    end
    [classes, sigs]
  end

  def walk(nodes, owner, file, classes, sigs)
    nodes.each do |node|
      case node
      when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
        name = [owner, node.name.to_s.delete_prefix('::')].reject(&:empty?).join('::')
        classes[name] = node.is_a?(RBS::AST::Declarations::Class) ? :class : :module
        walk(node.members, name, file, classes, sigs)
      when RBS::AST::Members::MethodDefinition
        next if node.singleton? || node.overloads.size != 1

        fn = node.overloads.first.method_type.type
        sigs << Sig.new(owner, node.name.to_s, fn.required_positionals.map(&:type), fn.return_type, file,
                        node.location.start_line)
      end
    end
  end

  # ---- the trace side -----------------------------------------------------------------------------------------------

  # [method => index => site, method => site] merged over the dumps with the reader trace_types.rb candidates uses.
  def read_observed(dumps)
    params, rets = TraceTypes::Candidates.read_dumps(dumps)
    by_param = {}
    params.each do |(method, kind, index, _name), site|
      next unless kind == 'req'

      slot = ((by_param[method] ||= {})[index] ||= { calls: 0, overflow: 0, classes: Hash.new(0) })
      slot[:calls] += site[:calls]
      slot[:overflow] += site[:overflow]
      site[:classes].each { |klass, count| slot[:classes][klass] += count }
    end
    [by_param, rets]
  end

  # ---- class membership ---------------------------------------------------------------------------------------------

  def same_class?(observed, declared)
    observed == declared || observed.end_with?("::#{declared}")
  end

  def core?(name)
    CoreHierarchySigs.hierarchy.first.key?(name)
  end

  # The lookup order of an observed class, and whether that order is complete for classes.
  def ancestry(name, ctx)
    return Ancestry.new(CoreHierarchySigs.ancestors(name), true, true) if core?(name)
    return nil unless ctx.hierarchy

    chain = ctx.hierarchy.chain(name)
    last = chain.last
    return Ancestry.new(chain, false, false) unless core?(last)

    Ancestry.new(chain[0...-1] + CoreHierarchySigs.ancestors(last), true, false)
  end

  # :class only for a class the candidate or mruby names as a class; a module is never decided.
  def declared_kind(name, ctx)
    return :class if core?(name)
    return ctx.classes[name] == :class ? :class : nil
  end

  def class_verdict(observed, declared, ctx)
    return :ok if same_class?(observed, declared)

    anc = ancestry(observed, ctx)
    return :unknown unless anc
    return :ok if anc.names.any? { |name| same_class?(name, declared) }
    return :unknown unless anc.complete

    declared_kind(declared, ctx) == :class ? :contradiction : :unknown
  end

  # Ok when any alternative admits the class, a contradiction when every alternative excludes it.
  def combine(verdicts)
    return :ok if verdicts.include?(:ok)
    return :contradiction if verdicts.all?(:contradiction)

    :unknown
  end

  def type_verdict(observed, type, owner, ctx)
    case type
    when RBS::Types::Bases::Any, RBS::Types::Bases::Void then :ok
    when RBS::Types::Bases::Nil then observed == 'NilClass' ? :ok : :contradiction
    when RBS::Types::Bases::Bool then %w[TrueClass FalseClass].include?(observed) ? :ok : :contradiction
    when RBS::Types::Bases::Self then class_verdict(observed, owner, ctx)
    when RBS::Types::Optional
      combine([type_verdict(observed, type.type, owner, ctx),
               type_verdict(observed, RBS::Types::Bases::Nil.new(location: nil), owner, ctx)])
    when RBS::Types::Union then combine(type.types.map { |t| type_verdict(observed, t, owner, ctx) })
    when RBS::Types::ClassInstance then class_verdict(observed, type.name.to_s.delete_prefix('::'), ctx)
    else :unknown
    end
  end

  # ---- the comparison -----------------------------------------------------------------------------------------------

  Result = Struct.new(:findings, :stats)

  def compare(classes, sigs, by_param, rets, hierarchy)
    ctx = Ctx.new(classes, hierarchy)
    findings = []
    stats = Hash.new(0)
    sigs.each do |sig|
      key = "#{sig.owner}##{sig.name}"
      stats[:methods] += 1
      sig.params.each_with_index do |type, i|
        site = (by_param[key] || {})[i + 1]
        label = "parameter #{i + 1}"
        check_site(sig, label, type, site, ctx, findings, stats)
      end
      next if sig.name == 'initialize'

      check_site(sig, 'return', sig.ret, rets[key], ctx, findings, stats)
    end
    Result.new(findings, stats)
  end

  def check_site(sig, label, type, site, ctx, findings, stats)
    if site.nil? || site[:calls].zero?
      stats[:unreached] += 1
      return
    end
    if site[:overflow].positive?
      stats[:overflowed] += 1
      return
    end
    return if type.is_a?(RBS::Types::Bases::Any) || type.is_a?(RBS::Types::Bases::Void)

    stats[:sites] += 1
    bad = site[:classes].filter_map do |observed, count|
      verdict = type_verdict(observed, type, sig.owner, ctx)
      stats[:undecided_classes] += 1 if verdict == :unknown
      [observed, count] if verdict == :contradiction
    end
    return if bad.empty?

    seen = bad.map { |observed, count| "#{observed} (#{count})" }.join(', ')
    findings << "#{sig.file}:#{sig.line}: #{sig.owner}##{sig.name} #{label} declared #{type}, but the trace observed " \
                "#{seen} [TRACE_CONTRADICTION]"
  end

  def run(dir, dumps, hierarchy_path: nil)
    classes, sigs = read_candidates(dir)
    by_param, rets = read_observed(dumps)
    hierarchy = hierarchy_path && TraceTypes::Candidates::Hierarchy.read(hierarchy_path)
    compare(classes, sigs, by_param, rets, hierarchy)
  end

  def summary(result)
    s = result.stats
    "rbs suggestion trace check: #{s[:methods]} method(s), #{s[:sites]} site(s) compared, " \
      "#{s[:unreached]} unreached, #{s[:overflowed]} overflowed, #{s[:undecided_classes]} class(es) undecided, " \
      "#{result.findings.size} contradiction(s)"
  end

  # The core hierarchy is parsed lazily, by RBS 4 (Gemfile); RBS 3 reads it as a syntax error.
  def ensure_core_hierarchy!
    CoreHierarchySigs.hierarchy
  rescue RBS::ParsingError => e
    raise Error, "core hierarchy unreadable, run with `bundle exec` (pinned RBS 4): #{e.message}"
  end

  def main(argv)
    hierarchy = nil
    OptionParser.new do |o|
      o.banner = 'usage: rbs_suggestion_trace_check.rb CANDIDATE_DIR DUMP... [--hierarchy TSV]'
      o.on('--hierarchy TSV', 'class_hierarchy.rb rows of the program sources (decides program superclass chains)') { |v| hierarchy = v }
    end.parse!(argv)
    dir, *dumps = argv
    usage = 'usage: rbs_suggestion_trace_check.rb CANDIDATE_DIR DUMP... [--hierarchy TSV]'
    raise Error, usage if dir.nil? || dumps.empty?

    (dumps + [hierarchy].compact).each { |path| raise Error, "#{path}: no such file" unless File.file?(path) }
    ensure_core_hierarchy!
    result = run(dir, dumps, hierarchy_path: hierarchy)
    result.findings.each { |line| warn line }
    puts summary(result)
    exit(result.findings.empty? ? 0 : 1)
  rescue Error => e
    warn "rbs_suggestion_trace_check: #{e.message}"
    exit 2
  end

  # ---- the fixture self-test ----------------------------------------------------------------------------------------

  def method_fact(owner, name, params, ret)
    { 'owner' => owner, 'name' => name, 'scope' => 'engine', 'params' => params.map { |t| { 'type' => t } }, 'opt' => 0,
      'optional_params' => [], 'rest' => false, 'keyword_params' => [], 'kdict' => false, 'key' => 0,
      'return' => { 'type' => ret, 'source' => 'inferred:bytecode-ir', 'reason' => nil }, 'visibility' => 'public' }
  end

  # The candidates the emitter writes for these facts: the same files `type_check.rb --emit-rbs` produces.
  def write_candidates(dir, methods, classes: [])
    require 'type_check_rbs'
    facts = { 'classes' => classes.map { |n| { 'name' => n, 'kind' => 'class', 'superclass' => nil } },
              'methods' => methods, 'ivars' => [], 'constants' => [] }
    TypeCheckRbs.emit(facts, dir, scope: 'engine')
  end

  def param_rows(id, method, index, calls, overflow, classes)
    rows = ["PARAM_SITE\tfx\t#{id}\t#{calls}\t#{overflow}\t#{method}\tfn\tmethod\treq\t#{index}\tv\tnone:mono"]
    classes.each { |klass, count| rows << "PARAM_CLASS\tfx\t#{id}\t#{klass}\t#{count}" }
    rows
  end

  def return_rows(id, method, calls, overflow, classes)
    rows = ["RETURN_SITE\tfx\t#{id}\t#{calls}\t#{overflow}\t#{method}\tfn\tmethod\treturn\t0\treturn#1\tret=none"]
    classes.each { |klass, count| rows << "RETURN_CLASS\tfx\t#{id}\t#{klass}\t#{count}" }
    rows
  end

  def self_test
    failures = []
    check = ->(name, ok) { failures << name unless ok }
    methods = [
      method_fact('Box', 'put', ['Integer'], 'Integer'),
      method_fact('Box', 'find', ['Integer?'], 'Integer?'),
      method_fact('Box', 'scale', ['Numeric'], 'Numeric'),
      method_fact('Box', 'count', ['Integer'], 'Integer'),
      method_fact('Box', 'take', ['Game::Actor'], 'bool'),
      method_fact('Box', 'label', ['String'], 'String'),
      method_fact('Box', 'overflowed', ['Integer'], 'Integer'),
      method_fact('Box', 'initialize', ['Integer'], 'void'),
      method_fact('Box', 'draw', ['Numeric'], 'bool'),
      method_fact('Game::Actor', 'hp', [], 'Integer')
    ]
    hierarchy = <<~TSV
      SUPER\tGame::Sprite\tNumeric
      SUPER\tGame::Plain\tGame::Base
      DEF\tGame::Sprite\tdraw
    TSV

    Dir.mktmpdir('rbs-suggestion-trace') do |tmp|
      candidates = File.join(tmp, 'candidates')
      write_candidates(candidates, methods, classes: ['Game::Actor'])
      put_text = File.read(File.join(candidates, 'Box.rbs'))
      check.call('the emitted candidate declares the Integer parameter', put_text.include?('def put: (Integer)'))
      check.call('a nilable parameter is emitted nilable', put_text.include?('def find: (Integer?)'))

      hier_path = File.join(tmp, 'hierarchy.tsv')
      File.write(hier_path, hierarchy)

      contradict = File.join(tmp, 'contradict.tsv')
      File.write(contradict, (param_rows(0, 'Box#put', 1, 3, 0, 'String' => 3) +
                              return_rows(1, 'Box#put', 2, 0, 'Integer' => 2)).join("\n") << "\n")
      r = run(candidates, [contradict])
      check.call('an observed String against a declared Integer parameter is a contradiction',
                 r.findings.size == 1 && r.findings.first.include?('Box#put parameter 1 declared Integer') &&
                 r.findings.first.include?('observed String (3)'))
      check.call('the finding names the candidate file and line',
                 r.findings.first.start_with?(File.join(candidates, 'Box.rbs') + ':'))

      consistent = File.join(tmp, 'consistent.tsv')
      File.write(consistent, (param_rows(0, 'Box#put', 1, 3, 0, 'Integer' => 3) +
                              return_rows(1, 'Box#put', 2, 0, 'Integer' => 2) +
                              param_rows(2, 'Box#find', 1, 2, 0, 'NilClass' => 1, 'Integer' => 1) +
                              return_rows(3, 'Box#find', 2, 0, 'NilClass' => 1, 'Integer' => 1) +
                              param_rows(4, 'Box#scale', 1, 2, 0, 'Integer' => 1, 'Float' => 1) +
                              param_rows(5, 'Box#take', 1, 1, 0, 'Game::Actor' => 1) +
                              return_rows(6, 'Box#initialize', 1, 0, 'NilClass' => 1)).join("\n") << "\n")
      r = run(candidates, [consistent])
      check.call('a trace the candidates admit (nil in a nilable, Integer and Float under Numeric) has no findings',
                 r.findings.empty? && r.stats[:sites] == 6)

      count_float = File.join(tmp, 'count.tsv')
      File.write(count_float, param_rows(0, 'Box#count', 1, 2, 0, 'Float' => 2).join("\n") << "\n")
      r = run(candidates, [count_float])
      check.call('a Float under a declared Integer is a contradiction', r.findings.one? { |line| line.include?('observed Float (2)') })

      pass = File.join(tmp, 'pass.tsv')
      File.write(pass, (param_rows(0, 'Box#put', 1, 3, 0, 'Integer' => 3) +
                        param_rows(1, 'Box#scale', 1, 2, 0, 'Integer' => 1, 'Float' => 1) +
                        param_rows(2, 'Box#find', 1, 2, 0, 'NilClass' => 1, 'Integer' => 1)).join("\n") << "\n")
      r = run(candidates, [pass])
      check.call('the CLI-pass fixture has no findings', r.findings.empty?)

      overflow = File.join(tmp, 'overflow.tsv')
      File.write(overflow, (param_rows(0, 'Box#overflowed', 1, 3, 1, 'String' => 3) +
                            return_rows(1, 'Box#overflowed', 2, 0, 'Integer' => 2)).join("\n") << "\n")
      r = run(candidates, [overflow])
      check.call('a site whose class table overflowed is not compared', r.findings.empty? && r.stats[:overflowed] == 1)

      unknown_class = File.join(tmp, 'unknown.tsv')
      File.write(unknown_class, (param_rows(0, 'Box#draw', 1, 2, 0, 'Game::Sprite' => 2) +
                                 param_rows(1, 'Box#label', 1, 2, 0, 'Game::Sprite' => 2)).join("\n") << "\n")
      r = run(candidates, [unknown_class])
      check.call('a program class without a hierarchy is undecided, not a contradiction',
                 r.findings.empty? && r.stats[:undecided_classes] == 2)
      r = run(candidates, [unknown_class], hierarchy_path: hier_path)
      check.call('a program subclass of Numeric admits a Numeric parameter through --hierarchy',
                 r.findings.none? { |line| line.include?('Box#draw') })
      check.call('the same subclass contradicts a declared String parameter through --hierarchy',
                 r.findings.one? { |line| line.include?('Box#label parameter 1 declared String') && line.include?('Game::Sprite (2)') })

      program_class = File.join(tmp, 'program.tsv')
      File.write(program_class, param_rows(0, 'Box#take', 1, 1, 0, 'Integer' => 1).join("\n") << "\n")
      r = run(candidates, [program_class])
      check.call('an Integer under a declared program class is a contradiction (core ancestry is complete)',
                 r.findings.one? { |line| line.include?('Box#take parameter 1 declared Game::Actor') })

      ret_bad = File.join(tmp, 'ret.tsv')
      File.write(ret_bad, return_rows(0, 'Box#label', 2, 0, 'Integer' => 2).join("\n") << "\n")
      r = run(candidates, [ret_bad])
      check.call('a return observed as Integer under a declared String is a contradiction',
                 r.findings.one? { |line| line.include?('Box#label return declared String') })

      cli_bad = Open3.capture3(RbConfig.ruby, __FILE__, candidates, contradict)
      check.call('the CLI exits 1 on a contradiction and names it',
                 !cli_bad[2].success? && cli_bad[1].include?('[TRACE_CONTRADICTION]') && cli_bad[0].include?('contradiction(s)'))
      cli_ok = Open3.capture3(RbConfig.ruby, __FILE__, candidates, pass)
      check.call('the CLI exits 0 on a consistent trace', cli_ok[2].success?)
      cli_usage = Open3.capture3(RbConfig.ruby, __FILE__, candidates)
      check.call('the CLI exits 2 with no dump', cli_usage[2].exitstatus == 2)
    end

    if failures.empty?
      puts 'rbs suggestion trace check: PASS'
    else
      warn "rbs suggestion trace check: FAIL\n  #{failures.join("\n  ")}"
      exit 1
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    RbsSuggestionTrace.ensure_core_hierarchy!
  rescue RbsSuggestionTrace::Error => e
    warn "rbs_suggestion_trace_check: #{e.message}"
    exit 2
  end
  if ARGV.empty?
    RbsSuggestionTrace.self_test
  else
    RbsSuggestionTrace.main(ARGV)
  end
end
