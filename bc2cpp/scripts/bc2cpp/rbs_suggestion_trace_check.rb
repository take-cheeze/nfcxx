#!/usr/bin/env ruby
# frozen_string_literal: true

# Candidate RBS against runtime evidence. A candidate directory (type_check.rb --emit-rbs or --emit-rbs-suggestions)
# must not declare a parameter, a return type or a container element type that a BC2CPP_TRACE_TYPES dump observed a
# different runtime class at. `type_check.rb --all` against the same sources cannot see this: it reads the same
# inference that wrote the candidate. Host only; it needs the pinned RBS and Prism gems.
#
#   bundle exec ruby scripts/bc2cpp/rbs_suggestion_trace_check.rb CANDIDATE_DIR DUMP.tsv... [--hierarchy TSV]
#   bundle exec ruby scripts/bc2cpp/rbs_suggestion_trace_check.rb      # the fixture self-test (no arguments)
#
# Exit status: 0 no contradiction, 1 at least one contradiction (one line each, `[TRACE_CONTRADICTION]`), 2 usage or
# unreadable input.
#
# Compared:
#   * each required positional parameter (trace kind `req`, index = position) and each method return, except
#     `initialize` (Ruby discards its value);
#   * the elements of a parameter or return declared Array[T] or Hash[K, V] (the PARAM_ELEM_* and RETURN_ELEM_* rows);
#   * singleton methods, `def self.x`, against the trace key `Owner.singleton#x`;
#   * a module method, against the observations of each class that includes the module (the mixins come from
#     --hierarchy). Without --hierarchy those observations are counted as undecided;
#   * a module method, against the singleton observations of each class that extends the module (the EXTEND rows of
#     --hierarchy), as the singleton method of that class. A class whose extend cannot be read (a dynamic one) is
#     counted as undecided, never a contradiction.
# Not compared, and counted in the summary where it applies: a site with no calls; an overflowed site, whose class table
# was full so its classes are unknown (counted once over the whole trace, whether or not a candidate declares it);
# optional, rest, keyword and block parameters; ivars and constants (not traced); the receiver of a singleton method
# (self is not traced); an overloaded method.
#
# A class is a contradiction only when the lookup order it is checked against is complete: a core class (mruby's
# hierarchy from CoreHierarchySigs), or a program class whose superclass chain reaches a core class through --hierarchy.
# A module is never a contradiction: a class that includes it is accepted, anything else is undecided.
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
  Sig = Struct.new(:owner, :name, :params, :ret, :file, :line, :singleton) do
    # The trace key of the method: `Owner#name`, or `Owner.singleton#name` for `def self.name`.
    def key
      singleton ? "#{owner}.singleton##{name}" : "#{owner}##{name}"
    end

    def label
      singleton ? "#{owner}.#{name}" : "#{owner}##{name}"
    end
  end
  Ctx = Struct.new(:classes, :hierarchy)
  Ancestry = Struct.new(:names, :complete)
  # by_param: method => index => site (required parameters); rets: method => site; param_elems: method => index =>
  # role => site; ret_elems: method => role => site; overflowed: the sites and element slots, of any kind, whose class
  # table overflowed.
  Observed = Struct.new(:by_param, :rets, :param_elems, :ret_elems, :overflowed)
  Result = Struct.new(:findings, :stats)

  module_function

  # ---- the candidate side -------------------------------------------------------------------------------------------

  # [class name => :class | :module, [Sig]] for every .rbs under dir. Overloaded methods are not compared.
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
        # `def self?.x` names both an instance and a singleton method, so it is not compared.
        next if node.overloads.size != 1 || !%i[instance singleton].include?(node.kind)

        fn = node.overloads.first.method_type.type
        sigs << Sig.new(owner, node.name.to_s, fn.required_positionals.map(&:type), fn.return_type, file,
                        node.location.start_line, node.kind == :singleton)
      end
    end
  end

  # ---- the trace side -----------------------------------------------------------------------------------------------

  # The dumps merged by what each site is (TraceTypes::Candidates.read_dumps and read_elements), with the element roles
  # of the required parameters and of the returns.
  def read_observed(dumps)
    params, rets = TraceTypes::Candidates.read_dumps(dumps)
    elems = TraceTypes::Candidates.read_elements(dumps)
    element_tables = [elems[:params], elems[:returns]]
    overflowed = params.count { |_, site| site[:overflow].positive? } +
                 rets.count { |_, site| site[:overflow].positive? } +
                 element_tables.sum { |table| table.sum { |_, roles| roles.count { |_, slot| slot[:overflow].positive? } } }

    by_param = {}
    params.each do |(method, kind, index, _name), site|
      next unless kind == 'req'

      merge_site(((by_param[method] ||= {})[index] ||= new_site), site)
    end
    param_elems = {}
    elems[:params].each do |(method, kind, index, _name), roles|
      next unless kind == 'req'

      target = ((param_elems[method] ||= {})[index] ||= {})
      roles.each { |role, slot| merge_site(target[role] ||= new_site, slot) }
    end
    Observed.new(by_param, rets, param_elems, elems[:returns], overflowed)
  end

  def new_site
    { calls: 0, overflow: 0, classes: Hash.new(0) }
  end

  def merge_site(site, add)
    site[:calls] += add[:calls]
    site[:overflow] += add[:overflow]
    add[:classes].each { |klass, count| site[:classes][klass] += count }
    site
  end

  # method name => the classes whose instance method of that name was observed. Singleton keys are not instance methods.
  def observers_by_name(obs)
    out = Hash.new { |h, k| h[k] = [] }
    (obs.by_param.keys + obs.rets.keys).uniq.each do |key|
      klass, name = key.split('#', 2)
      next if name.nil? || klass.end_with?('.singleton')

      out[name] << klass
    end
    out
  end

  # method name => the classes whose singleton method of that name was observed (the `Owner.singleton#name` keys).
  def singleton_observers_by_name(obs)
    out = Hash.new { |h, k| h[k] = [] }
    (obs.by_param.keys + obs.rets.keys).uniq.each do |key|
      klass, name = key.split('#', 2)
      next if name.nil? || !klass.end_with?('.singleton')

      out[name] << klass.delete_suffix('.singleton')
    end
    out
  end

  # ---- class membership ---------------------------------------------------------------------------------------------

  def same_class?(observed, declared)
    observed == declared || observed.end_with?("::#{declared}")
  end

  def core?(name)
    CoreHierarchySigs.hierarchy.first.key?(name)
  end

  # The names an instance of +name+ is an instance of (its class chain and the modules mixed into it), and whether its
  # class chain is complete. nil for a program class without --hierarchy.
  def ancestry(name, ctx)
    return Ancestry.new(CoreHierarchySigs.ancestors(name), true) if core?(name) && ctx.hierarchy.nil?
    return nil unless ctx.hierarchy

    complete = core?(ctx.hierarchy.chain(name).last)
    Ancestry.new(lookup(name, ctx.hierarchy).map(&:first), complete)
  end

  # Method lookup order of a class or module as [name, kind] pairs. kind is :program (the hierarchy names it), :core
  # (CoreHierarchySigs lists it, its own methods are not read) or :unknown. An :unknown entry ends what is known past it:
  # a name the hierarchy does not name, or a program class with no superclass row (its implicit superclass is not
  # recorded). Mixins are in lookup order: the last one included comes first.
  def lookup(name, hierarchy, path = [])
    return [[name, :unknown]] if path.include?(name)

    path += [name]
    core = core?(name)
    return [[name, :unknown]] unless core || hierarchy.program?(name)

    order = mixed_in(name, core ? :core : :program, hierarchy, path)
    if core
      order + CoreHierarchySigs.ancestors(name).drop(1).flat_map { |n| mixed_in(n, :core, hierarchy, path) }
    elsif hierarchy.module?(name)
      order
    elsif (sup = hierarchy.superclass(name))
      order + lookup(sup, hierarchy, path)
    else
      order + [['(no superclass row)', :unknown]]
    end
  end

  # +name+ with the modules prepended and included into it, placed around it in lookup order.
  def mixed_in(name, kind, hierarchy, path)
    before = hierarchy.prepends(name).reverse.flat_map { |m| lookup(m, hierarchy, path) }
    after = hierarchy.includes(name).reverse.flat_map { |m| lookup(m, hierarchy, path) }
    before + [[name, kind]] + after
  end

  # Where an observation of `klass#name` lands for the module method +sig+. :accepted when the lookup for klass reaches
  # the module before any other name that could answer `name`. :not_included when the lookup does not reach the module,
  # or a program class in front of it defines the name itself: the observation is not this module's. :undecided when
  # something in front of the module is unreadable (a core class, a native module), when the module is absent but the
  # lookup is unreadable, or when there is no hierarchy.
  def mixin_status(klass, sig, ctx)
    return :undecided unless ctx.hierarchy

    order = lookup(klass, ctx.hierarchy)
    at = order.index { |name, _| name == sig.owner }
    return order.any? { |_, kind| kind == :unknown } ? :undecided : :not_included if at.nil?

    front = order.take(at)
    return :undecided unless front.all? { |_, kind| kind == :program }
    return :not_included if front.any? { |name, _| ctx.hierarchy.defines?(name, sig.name) }

    :accepted
  end

  # The singleton lookup order of a class as [label, kind] pairs. `Name.singleton` is the class's own singleton methods
  # (SDEF rows), placed first; the modules it extends follow, last applied first (EXTEND rows), then the superclass's
  # singleton lookup. A dynamic extend is an unknown entry in front of the extended modules.
  def singleton_lookup(name, hierarchy, path = [])
    return [["#{name}.singleton", :unknown]] if path.include?(name)

    path += [name]
    return [["#{name}.singleton", :unknown]] unless hierarchy.program?(name)

    head = hierarchy.unknown_singleton?(name) ? [['(dynamic extend)', :unknown]] : []
    extended = hierarchy.extends(name).reverse.flat_map { |m| lookup(m, hierarchy, path) }
    rest = if (sup = hierarchy.superclass(name))
             singleton_lookup(sup, hierarchy, path)
           else
             [['(no superclass row)', :unknown]]
           end
    [["#{name}.singleton", :program]] + head + extended + rest
  end

  # Where an observation of `klass.singleton#name` lands for the module method +sig+, over singleton_lookup. The same
  # verdicts as mixin_status: :accepted when the module is reached before any other definer of the name, :not_included
  # when a program singleton in front of it defines the name (an own `def self.x` shadows the extended module), and
  # :undecided when something in front is unknown, or the module is absent and the lookup is unreadable.
  def singleton_status(klass, sig, ctx)
    return :undecided unless ctx.hierarchy

    order = singleton_lookup(klass, ctx.hierarchy)
    at = order.index { |label, _| label == sig.owner }
    return order.any? { |_, kind| kind == :unknown } ? :undecided : :not_included if at.nil?

    front = order.take(at)
    return :undecided unless front.all? { |_, kind| kind == :program }
    return :not_included if front.any? { |label, _| singleton_defines?(label, sig.name, ctx.hierarchy) }

    :accepted
  end

  def singleton_defines?(label, method, hierarchy)
    return hierarchy.singleton_defines?(label.delete_suffix('.singleton'), method) if label.end_with?('.singleton')

    hierarchy.defines?(label, method)
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

  # self_owner is the class a `self` return means; nil for a singleton method, whose self is a class object.
  def type_verdict(observed, type, self_owner, ctx)
    case type
    when RBS::Types::Bases::Any, RBS::Types::Bases::Void then :ok
    when RBS::Types::Bases::Nil then observed == 'NilClass' ? :ok : :contradiction
    when RBS::Types::Bases::Bool then %w[TrueClass FalseClass].include?(observed) ? :ok : :contradiction
    when RBS::Types::Bases::Self then self_owner ? class_verdict(observed, self_owner, ctx) : :unknown
    when RBS::Types::Optional
      combine([type_verdict(observed, type.type, self_owner, ctx),
               type_verdict(observed, RBS::Types::Bases::Nil.new(location: nil), self_owner, ctx)])
    when RBS::Types::Union then combine(type.types.map { |t| type_verdict(observed, t, self_owner, ctx) })
    when RBS::Types::ClassInstance then class_verdict(observed, type.name.to_s.delete_prefix('::'), ctx)
    else :unknown
    end
  end

  # The element type each role of a container declares: Array[T] gives array => T, Hash[K, V] gives key => K and value
  # => V. A nilable container declares the same elements; any other type declares none.
  def element_types(type)
    case type
    when RBS::Types::Optional then element_types(type.type)
    when RBS::Types::ClassInstance
      args = type.args
      case type.name.to_s.delete_prefix('::')
      when 'Array' then args.size == 1 ? { 'array' => args[0] } : {}
      when 'Hash' then args.size == 2 ? { 'key' => args[0], 'value' => args[1] } : {}
      else {}
      end
    else {}
    end
  end

  # ---- the comparison -----------------------------------------------------------------------------------------------

  def compare(classes, sigs, obs, hierarchy)
    ctx = Ctx.new(classes, hierarchy)
    findings = []
    stats = Hash.new(0)
    stats[:overflowed] = obs.overflowed
    observers = observers_by_name(obs)
    singletons = singleton_observers_by_name(obs)
    sigs.each do |sig|
      stats[:methods] += 1
      stats[:singleton_methods] += 1 if sig.singleton
      compare_sig(sig, sig.key, obs, ctx, findings, stats)
      next unless classes[sig.owner] == :module && !sig.singleton

      observers.fetch(sig.name, []).uniq.each do |klass|
        next if klass == sig.owner

        case mixin_status(klass, sig, ctx)
        when :accepted
          stats[:mixin_sites] += 1
          compare_sig(sig, "#{klass}##{sig.name}", obs, ctx, findings, stats, via: klass)
        when :undecided
          stats[:mixin_undecided] += 1
        end
      end
      # The module's method is a singleton method of each class that extends it. Its self is that class object, so a
      # `self` return is not the module's.
      singletons.fetch(sig.name, []).uniq.each do |klass|
        case singleton_status(klass, sig, ctx)
        when :accepted
          stats[:extend_sites] += 1
          compare_sig(sig, "#{klass}.singleton##{sig.name}", obs, ctx, findings, stats,
                      via: "#{klass}.singleton", self_owner: nil)
        when :undecided
          stats[:extend_undecided] += 1
        end
      end
    end
    Result.new(findings, stats)
  end

  # Compares the parameters, the returns and their elements under the trace key +key+ (the method's own key, or a class
  # that includes a module method, named by `via`).
  # self_owner is the class a `self` return means (see type_verdict): the owner of an instance method, none for a singleton
  # method or a method run as one.
  def compare_sig(sig, key, obs, ctx, findings, stats, via: nil, self_owner: sig.singleton ? nil : sig.owner)
    sig.params.each_with_index do |type, i|
      index = i + 1
      label = "parameter #{index}"
      check_observed(sig, label, type, (obs.by_param[key] || {})[index], ctx, findings, stats, via, self_owner)
      check_elements(sig, label, type, (obs.param_elems[key] || {})[index], ctx, findings, stats, via, self_owner)
    end
    return if sig.name == 'initialize'

    check_observed(sig, 'return', sig.ret, obs.rets[key], ctx, findings, stats, via, self_owner)
    check_elements(sig, 'return', sig.ret, obs.ret_elems[key], ctx, findings, stats, via, self_owner)
  end

  def check_observed(sig, label, type, site, ctx, findings, stats, via, self_owner)
    if site.nil? || site[:calls].zero?
      stats[:unreached] += 1
      return
    end
    # An overflowed site has classes nobody recorded. It is counted once, for the whole trace, in the summary.
    return if site[:overflow].positive?

    compare_site(sig, label, type, site, ctx, findings, stats, via, :sites, self_owner)
  end

  def check_elements(sig, label, type, roles, ctx, findings, stats, via, self_owner)
    return if roles.nil?

    element_types(type).each do |role, elem_type|
      site = roles[role]
      next if site.nil? || site[:calls].zero? || site[:overflow].positive?

      compare_site(sig, "#{label} element (#{role})", elem_type, site, ctx, findings, stats, via, :element_sites,
                   self_owner)
    end
  end

  def compare_site(sig, label, type, site, ctx, findings, stats, via, counter, self_owner)
    return if type.is_a?(RBS::Types::Bases::Any) || type.is_a?(RBS::Types::Bases::Void)

    stats[counter] += 1
    bad = site[:classes].filter_map do |observed, count|
      verdict = type_verdict(observed, type, self_owner, ctx)
      stats[:undecided_classes] += 1 if verdict == :unknown
      [observed, count] if verdict == :contradiction
    end
    return if bad.empty?

    seen = bad.map { |observed, count| "#{observed} (#{count})" }.join(', ')
    on = via ? " (on #{via})" : ''
    findings << "#{sig.file}:#{sig.line}: #{sig.label} #{label}#{on} declared #{type}, but the trace observed " \
                "#{seen} [TRACE_CONTRADICTION]"
  end

  def run(dir, dumps, hierarchy_path: nil)
    classes, sigs = read_candidates(dir)
    obs = read_observed(dumps)
    hierarchy = hierarchy_path && TraceTypes::Candidates::Hierarchy.read(hierarchy_path)
    compare(classes, sigs, obs, hierarchy)
  end

  def summary(result)
    s = result.stats
    "rbs suggestion trace check: #{s[:methods]} method(s) (#{s[:singleton_methods]} singleton), #{s[:sites]} site(s) " \
      "compared, #{s[:element_sites]} element slot(s), #{s[:mixin_sites]} mixin site(s), #{s[:unreached]} unreached, " \
      "#{s[:overflowed]} overflowed site(s) skipped, #{s[:undecided_classes]} class(es) undecided, " \
      "#{s[:mixin_undecided]} mixin observation(s) undecided, #{s[:extend_sites]} extend site(s) compared, " \
      "#{s[:extend_undecided]} extend observation(s) cannot decide, #{result.findings.size} contradiction(s)"
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
      o.on('--hierarchy TSV', 'class_hierarchy.rb rows of the program sources (superclass chains and mixins)') { |v| hierarchy = v }
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
  def write_candidates(dir, methods, classes: [], modules: [])
    require 'type_check_rbs'
    facts = { 'classes' => classes.map { |n| { 'name' => n, 'kind' => 'class', 'superclass' => nil } } +
                           modules.map { |n| { 'name' => n, 'kind' => 'module', 'superclass' => nil } },
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

  # The element rows of one site: prefix PARAM or RETURN names the site table, role is array, key or value.
  def elem_rows(prefix, id, role, calls, overflow, classes)
    rows = ["#{prefix}_ELEM_SITE\tfx\t#{id}\t#{role}\t#{calls}\t#{overflow}"]
    classes.each { |klass, count| rows << "#{prefix}_ELEM_CLASS\tfx\t#{id}\t#{role}\t#{klass}\t#{count}" }
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
      method_fact('Game::Actor', 'hp', [], 'Integer'),
      method_fact('Box.singleton', 'make', ['Integer'], 'Integer'),
      method_fact('Box', 'pack', ['Array[Integer]'], 'Integer'),
      method_fact('Box', 'tally', ['Hash[String]'], 'Integer'),
      method_fact('Box', 'bucket', [], 'Array[Integer]'),
      method_fact('Walk', 'step', ['Integer'], 'Integer'),
      method_fact('Box', 'take_walker', ['Walk'], 'Integer'),
      method_fact('Helpers', 'tag', ['Integer'], 'Integer')
    ]
    hierarchy = <<~TSV
      SUPER\tGame::Sprite\tNumeric
      SUPER\tGame::Plain\tGame::Base
      DEF\tGame::Sprite\tdraw
    TSV
    mixin_hierarchy = <<~TSV
      MODULE\tWalk
      CLASS\tGame::Walker
      INCLUDE\tGame::Walker\tWalk
      CLASS\tGame::Hidden
      INCLUDE\tGame::Hidden\tWalk
      DEF\tGame::Hidden\tstep
      SUPER\tGame::Stranger\tNumeric
    TSV

    extend_hierarchy = <<~TSV
      MODULE\tHelpers
      CLASS\tGame::Hero
      EXTEND\tGame::Hero\tHelpers
      CLASS\tGame::Walker
      EXTEND\tGame::Walker\tHelpers
      EXTEND\tGame::Walker\t*
      CLASS\tGame::Shadow
      EXTEND\tGame::Shadow\tHelpers
      SDEF\tGame::Shadow\ttag
    TSV

    Dir.mktmpdir('rbs-suggestion-trace') do |tmp|
      candidates = File.join(tmp, 'candidates')
      write_candidates(candidates, methods, classes: ['Game::Actor'], modules: ['Walk', 'Helpers'])
      put_text = File.read(File.join(candidates, 'Box.rbs'))
      check.call('the emitted candidate declares the Integer parameter', put_text.include?('def put: (Integer)'))
      check.call('a nilable parameter is emitted nilable', put_text.include?('def find: (Integer?)'))
      check.call('a singleton method is emitted as def self.', put_text.include?('def self.make: (Integer)'))
      check.call('an element type is emitted as Array[T]', put_text.include?('def pack: (Array[Integer])'))
      check.call('a module candidate is emitted as a module', File.read(File.join(candidates, 'Walk.rbs')).include?('module Walk'))

      hier_path = File.join(tmp, 'hierarchy.tsv')
      File.write(hier_path, hierarchy)
      mixin_path = File.join(tmp, 'mixins.tsv')
      File.write(mixin_path, mixin_hierarchy)

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

      overflow_all = File.join(tmp, 'overflow_all.tsv')
      File.write(overflow_all, (param_rows(0, 'Box#ghost', 1, 3, 2, 'String' => 3) +
                                elem_rows('PARAM', 0, 'array', 0, 1, {})).join("\n") << "\n")
      r = run(candidates, [overflow_all])
      check.call('overflowed sites are counted for the whole trace, declared or not (a parameter and an element slot)',
                 r.findings.empty? && r.stats[:overflowed] == 2)

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

      # A singleton method is traced as Owner.singleton#name and compared with `def self.name`.
      singleton_bad = File.join(tmp, 'singleton_bad.tsv')
      File.write(singleton_bad, (param_rows(0, 'Box.singleton#make', 1, 2, 0, 'String' => 2) +
                                 return_rows(1, 'Box.singleton#make', 2, 0, 'Integer' => 2)).join("\n") << "\n")
      r = run(candidates, [singleton_bad])
      check.call('a singleton parameter observed as String against `def self.make(Integer)` is a contradiction',
                 r.findings.one? { |line| line.include?('Box.make parameter 1 declared Integer') && line.include?('observed String (2)') })
      singleton_ok = File.join(tmp, 'singleton_ok.tsv')
      File.write(singleton_ok, (param_rows(0, 'Box.singleton#make', 1, 2, 0, 'Integer' => 2) +
                                return_rows(1, 'Box.singleton#make', 2, 0, 'Integer' => 2)).join("\n") << "\n")
      r = run(candidates, [singleton_ok])
      check.call('a singleton method the trace admits has no findings and is counted as compared',
                 r.findings.empty? && r.stats[:singleton_methods] == 1 && r.stats[:sites] == 2)

      # Element rows are checked against Array[T] and Hash[K, V]: the `value` role against V, the `key` role against K.
      element_bad = File.join(tmp, 'element_bad.tsv')
      File.write(element_bad, (param_rows(0, 'Box#pack', 1, 2, 0, 'Array' => 2) +
                               elem_rows('PARAM', 0, 'array', 3, 0, 'Integer' => 2, 'String' => 1) +
                               return_rows(1, 'Box#bucket', 1, 0, 'Array' => 1) +
                               elem_rows('RETURN', 1, 'array', 2, 0, 'String' => 2) +
                               param_rows(2, 'Box#tally', 1, 2, 0, 'Hash' => 2) +
                               elem_rows('PARAM', 2, 'key', 2, 0, 'Symbol' => 2) +
                               elem_rows('PARAM', 2, 'value', 2, 0, 'Integer' => 2)).join("\n") << "\n")
      r = run(candidates, [element_bad])
      check.call('an element String under Array[Integer] is a contradiction',
                 r.findings.one? { |line| line.include?('Box#pack parameter 1 element (array) declared Integer') && line.include?('observed String (1)') })
      check.call('an element String under a returned Array[Integer] is a contradiction',
                 r.findings.one? { |line| line.include?('Box#bucket return element (array) declared Integer') })
      check.call('a Hash value Integer under Hash[String] is a contradiction, and the untyped key is not compared',
                 r.findings.one? { |line| line.include?('Box#tally parameter 1 element (value) declared String') && line.include?('observed Integer (2)') })
      check.call('the element contradictions are the only findings', r.findings.size == 3)
      element_ok = File.join(tmp, 'element_ok.tsv')
      File.write(element_ok, (param_rows(0, 'Box#pack', 1, 2, 0, 'Array' => 2) +
                              elem_rows('PARAM', 0, 'array', 3, 0, 'Integer' => 3) +
                              return_rows(1, 'Box#bucket', 1, 0, 'Array' => 1) +
                              elem_rows('RETURN', 1, 'array', 2, 0, 'Integer' => 2) +
                              param_rows(2, 'Box#tally', 1, 2, 0, 'Hash' => 2) +
                              elem_rows('PARAM', 2, 'key', 2, 0, 'Symbol' => 2) +
                              elem_rows('PARAM', 2, 'value', 2, 0, 'String' => 2)).join("\n") << "\n")
      r = run(candidates, [element_ok])
      check.call('elements the containers admit have no findings and are counted as element slots',
                 r.findings.empty? && r.stats[:element_sites] == 3)

      # A module method is observed through the classes that include the module (--hierarchy), and a module-declared type
      # is admitted by a class that includes it.
      mixin_bad = File.join(tmp, 'mixin_bad.tsv')
      File.write(mixin_bad, (param_rows(0, 'Walk#step', 1, 1, 0, 'Integer' => 1) +
                             param_rows(1, 'Game::Walker#step', 1, 2, 0, 'String' => 2) +
                             param_rows(2, 'Game::Hidden#step', 1, 2, 0, 'String' => 2) +
                             param_rows(3, 'Game::Stranger#step', 1, 2, 0, 'String' => 2) +
                             param_rows(4, 'Box#take_walker', 1, 2, 0, 'Game::Walker' => 1, 'Integer' => 1)).join("\n") << "\n")
      r = run(candidates, [mixin_bad], hierarchy_path: mixin_path)
      check.call('a class that includes the module is compared with the module method: String is a contradiction',
                 r.findings.one? { |line| line.include?('Walk#step parameter 1 (on Game::Walker) declared Integer') && line.include?('observed String (2)') })
      check.call('a class that defines the name itself, or never includes the module, is not evidence for the module',
                 r.stats[:mixin_sites] == 1 && r.findings.size == 1)
      check.call('a module-declared type admits a class that includes the module and is undecided otherwise',
                 r.stats[:undecided_classes] == 1)
      r = run(candidates, [mixin_bad])
      check.call('without --hierarchy the mixin observations are undecided, not failures',
                 r.findings.none? { |line| line.include?('Walk#step') } && r.stats[:mixin_undecided] == 3 && r.stats[:undecided_classes] == 2)
      mixin_ok = File.join(tmp, 'mixin_ok.tsv')
      File.write(mixin_ok, (param_rows(0, 'Walk#step', 1, 1, 0, 'Integer' => 1) +
                            param_rows(1, 'Game::Walker#step', 1, 2, 0, 'Integer' => 2)).join("\n") << "\n")
      r = run(candidates, [mixin_ok], hierarchy_path: mixin_path)
      check.call('an including class the trace admits has no findings', r.findings.empty? && r.stats[:mixin_sites] == 1)

      # A module method is a singleton method of each class that extends it (EXTEND rows). Game::Hero extends Helpers,
      # Game::Walker's extend is a computed module (cannot decide), and Game::Shadow defines `tag` on its own singleton.
      extend_hier = File.join(tmp, 'extend_hierarchy.tsv')
      File.write(extend_hier, extend_hierarchy)
      extend_ok = File.join(tmp, 'extend_ok.tsv')
      File.write(extend_ok, (param_rows(0, 'Game::Hero.singleton#tag', 1, 2, 0, 'Integer' => 2) +
                             return_rows(1, 'Game::Hero.singleton#tag', 2, 0, 'Integer' => 2)).join("\n") << "\n")
      r = run(candidates, [extend_ok], hierarchy_path: extend_hier)
      check.call('an extended module method is compared as the singleton method of the extending class: an admitted trace has no findings',
                 r.findings.empty? && r.stats[:extend_sites] == 1 && r.stats[:sites] == 2)
      extend_bad = File.join(tmp, 'extend_bad.tsv')
      File.write(extend_bad, param_rows(0, 'Game::Hero.singleton#tag', 1, 2, 0, 'String' => 2).join("\n") << "\n")
      r = run(candidates, [extend_bad], hierarchy_path: extend_hier)
      check.call('an observed String on the extending class against the extended module method declared Integer is a contradiction',
                 r.findings.one? { |line| line.include?('Helpers#tag parameter 1 (on Game::Hero.singleton) declared Integer') && line.include?('observed String (2)') })
      extend_dyn = File.join(tmp, 'extend_dynamic.tsv')
      File.write(extend_dyn, param_rows(0, 'Game::Walker.singleton#tag', 1, 2, 0, 'String' => 2).join("\n") << "\n")
      r = run(candidates, [extend_dyn], hierarchy_path: extend_hier)
      check.call('a class with a dynamic extend cannot decide: the same kind of observation is not a failure',
                 r.findings.empty? && r.stats[:extend_undecided] == 1 && r.stats[:extend_sites] == 0)
      r = run(candidates, [extend_bad])
      check.call('without --hierarchy an extended observation cannot decide, not a failure',
                 r.findings.empty? && r.stats[:extend_undecided] == 1 && r.stats[:extend_sites] == 0)
      extend_shadow = File.join(tmp, 'extend_shadow.tsv')
      File.write(extend_shadow, param_rows(0, 'Game::Shadow.singleton#tag', 1, 2, 0, 'String' => 2).join("\n") << "\n")
      r = run(candidates, [extend_shadow], hierarchy_path: extend_hier)
      check.call('a class that defines the singleton method itself is not evidence for the extended module',
                 r.findings.empty? && r.stats[:extend_sites] == 0 && r.stats[:extend_undecided] == 0)

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
