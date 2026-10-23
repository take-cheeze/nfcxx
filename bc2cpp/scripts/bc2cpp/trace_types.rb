#!/usr/bin/env ruby
# frozen_string_literal: true

# Traced-type tools for BC2CPP_TRACE_TYPES dumps (tools/bc2cpp/param_trace.rb): one file, two commands.
#
#   report      joins the dumps with the static facts bc2cpp proved and answers, for parameters and returns,
#               (a) what ran monomorphic with no static fact, (b) what a run contradicts, (c) which parameters
#               feed the unresolved by-name sends of an ELSE_TRACE dump, and (d) which returns contradict the
#               return fact.
#   candidates  writes RBS candidates: the classes observed for each method's parameters and returns, as unions.
#               Candidates are for review and are not loaded by bc2cpp.
#
#   ruby scripts/bc2cpp/trace_types.rb report [--top N] [--else FILE]... DUMP [...]
#   ruby scripts/bc2cpp/trace_types.rb candidates [--out FILE] DUMP [...]
#
# The dump rows are documented in the report section below (PARAM_*, RETURN_*).

require 'optparse'
require 'set'
require 'digest'

module TraceTypes
  module Report
  TOKEN_CLASS = { 'INT' => 'Integer', 'FLT' => 'Float', 'ARR' => 'Array', 'HSH' => 'Hash', 'STR' => 'String',
                  'NIL' => 'NilClass', 'RNG' => 'Range' }.freeze
  SCALAR_CLASS = { 'fixnum' => 'Integer', 'symbol' => 'Symbol', 'bool' => nil }.freeze

  def self.allowed_classes(fact)
    kind, value = fact.split('=', 2)
    case kind
    when 'argtypes', 'annot' then (c = SCALAR_CLASS[value]) ? [c] : nil
    when 'entryfix' then ['Integer']
    when 'classarg' then [value]
    when 'numeric', 'pool'
      tokens = value.split('|')
      return nil if tokens.any? { |t| %w[OTHER CHECKED NONE].include?(t) }

      tokens.map { |t| TOKEN_CLASS[t] || t.delete_prefix('FILE:') }  # numeric=FILE:CLASS names a class too
    end
  end
  def self.facts(p)
    p[:static].start_with?('none') ? [] : p[:static].split(',')
  end
  def self.label(p)
    name = p[:name].sub(/\Abc2cpp_kwarg_/, 'kw:')
    "#{p[:method]} #{p[:kind]}#{p[:index].positive? ? p[:index] : ''} #{name}"
  end
  def self.histogram(p)
    s = p[:classes].sort_by { |c, n| [-n, c] }.map { |c, n| "#{c} #{n}" }.join(', ')
    p[:overflow].positive? ? "#{s}, +#{p[:overflow]} calls in further classes" : s
  end

    def self.run(argv)

    options = { top: 20, else_files: [] }
    OptionParser.new do |o|
      o.banner = 'usage: trace_types.rb report [--top N] [--else DUMP]... PARAM_DUMP...'
      o.on('--top N', Integer, 'rows per ranking (default 20)') { |n| options[:top] = n }
      o.on('--else FILE', 'ELSE_TRACE dump (repeatable)') { |f| options[:else_files] << f }
    end.parse!(argv)
    abort 'no param dump files given' if argv.empty?

    # Runtime class names that each mask token / fact value allows.

    # The set of classes a fact allows, or nil when it carries no usable restriction.

    params = {}  # [sym, fn, name] => {...}
    rets = {}    # [sym, return id] => {...}
    symbols = {}
    fn_entries = Hash.new(0)
    ids = {}     # [sym, id] => key
    elems = {}   # [:param | :return, site, role] => { calls:, overflow:, classes: } for array elements and hash keys/values

    argv.each do |path|
      File.foreach(path) do |raw|
        f = raw.chomp.split("\t", -1)
        case f[0]
        when 'PARAM_TRACE_SYMBOL'
          symbols[f[1]] = { fns: f[3].to_i, params: f[5].to_i, untraced_methods: f[11].to_i }
        when 'PARAM_FN'
          fn_entries[[f[1], f[5]]] += f[3].to_i
        when 'PARAM_SITE'
          sym, id = f[1], f[2].to_i
          key = [sym, f[6], f[10]]
          ids[[sym, id]] = key
          p = params[key] ||= { calls: 0, overflow: 0, classes: Hash.new(0) }
          p[:calls] += f[3].to_i
          p[:overflow] += f[4].to_i
          p.merge!(method: f[5], fn: f[6], scope: f[7], kind: f[8], index: f[9].to_i, name: f[10], static: f[11])
        when 'PARAM_CLASS'
          key = ids[[f[1], f[2].to_i]] or next
          params[key][:classes][f[3]] += f[4].to_i
        when 'RETURN_SITE'
          # [sym, id] => { calls:, overflow:, classes:, static:, label: } for each traced `return` statement.
          rets[[f[1], f[2].to_i]] = { calls: f[3].to_i, overflow: f[4].to_i, classes: Hash.new(0),
                                      method: f[5], fn: f[6], static: f[11] }
        when 'RETURN_CLASS'
          rets[[f[1], f[2].to_i]] or next
          rets[[f[1], f[2].to_i]][:classes][f[3]] += f[4].to_i
        when 'PARAM_ELEM_SITE'
          # Element rows: role is array (Array elements), key or value (Hash entries), sampled up to 32 per container;
          # the rest is in the overflow column.
          key = ids[[f[1], f[2].to_i]] or next
          e = elems[[:param, key, f[3]]] ||= { calls: 0, overflow: 0, classes: Hash.new(0) }
          e[:calls] += f[4].to_i
          e[:overflow] += f[5].to_i
        when 'PARAM_ELEM_CLASS'
          key = ids[[f[1], f[2].to_i]] or next
          elems[[:param, key, f[3]]] ||= { calls: 0, overflow: 0, classes: Hash.new(0) }
          elems[[:param, key, f[3]]][:classes][f[4]] += f[5].to_i
        when 'RETURN_ELEM_SITE'
          e = elems[[:return, [f[1], f[2].to_i], f[3]]] ||= { calls: 0, overflow: 0, classes: Hash.new(0) }
          e[:calls] += f[4].to_i
          e[:overflow] += f[5].to_i
        when 'RETURN_ELEM_CLASS'
          elems[[:return, [f[1], f[2].to_i], f[3]]] ||= { calls: 0, overflow: 0, classes: Hash.new(0) }
          elems[[:return, [f[1], f[2].to_i], f[3]]][:classes][f[4]] += f[5].to_i
        end
      end
    end

    # Else-arm hits per feeding parameter.
    else_by_param = Hash.new { |h, k| h[k] = { hits: 0, may_hits: 0, sites: [] } }
    else_total = 0
    options[:else_files].each do |path|
      File.foreach(path) do |raw|
        f = raw.chomp.split("\t", -1)
        next unless f[0] == 'ELSE_SITE'

        else_total += f[3].to_i
        next unless %w[parameter join].include?(f[10])

        param = f[12]
        if param.nil? || param == '-'
          else_by_param[:unresolved][:hits] += f[3].to_i
          next
        end
        exact = !param.start_with?('~')
        param.delete_prefix('~').split('|').each do |name|
          e = else_by_param[[f[1], f[6], name]]
          e[exact ? :hits : :may_hits] += f[3].to_i
          e[:sites] << "#{f[7]} on #{f[11]} #{f[8]}#{exact ? '' : ' (join: may hold this parameter)'}"
        end
      end
    end




    hit = params.values.select { |p| p[:calls].positive? }
    mono = hit.select { |p| p[:classes].size == 1 && p[:overflow].zero? }
    mono_or_nil = hit.select do |p|
      p[:classes].size == 2 && p[:classes].key?('NilClass') && p[:overflow].zero?
    end
    proven = ->(p) { !facts(p).empty? }

    contradictions = []
    hit.each do |p|
      facts(p).each do |fact|
        allowed = allowed_classes(fact)
        next unless allowed

        # A static class name may be unqualified (`Rect` for RGSS::Rect): match on the trailing path too.
        bad = p[:classes].reject { |c, _| allowed.any? { |a| a == c || c.end_with?("::#{a}") } }
        contradictions << [p, fact, bad] unless bad.empty?
        break unless bad.empty?
      end
    end

    puts "symbols traced: #{symbols.keys.join(', ')}"
    puts "parameters instrumented: #{params.size}  (methods and blocks with their own impl; inlined blocks are not traced)"
    puts "function entries counted: #{fn_entries.values.sum}"
    puts "parameters reached at run time: #{hit.size}  (never reached: #{params.size - hit.size})"
    puts "  statically proven (any fact): #{hit.count(&proven)}"
    puts "  monomorphic at run time: #{mono.size}  (proven #{mono.count(&proven)}, UNPROVEN #{mono.count { |p| !proven.call(p) }})"
    puts "  one class plus nil: #{mono_or_nil.size}  (proven #{mono_or_nil.count(&proven)}, unproven #{mono_or_nil.count { |p| !proven.call(p) }})"
    puts "  polymorphic (3+ classes or more than the table holds): #{hit.size - mono.size - mono_or_nil.size - hit.count { |p| p[:classes].size == 2 && !p[:classes].key?('NilClass') && p[:overflow].zero? }}  (two non-nil classes: #{hit.count { |p| p[:classes].size == 2 && !p[:classes].key?('NilClass') && p[:overflow].zero? }})"
    by_scope = mono.reject(&proven).group_by { |p| p[:scope] == 'block' ? 'block' : p[:kind] }.transform_values(&:size)
    puts "  unproven monomorphic by kind: #{by_scope.sort.map { |k, v| "#{k} #{v}" }.join(', ')}"
    by_static = mono.reject(&proven).group_by { |p| p[:static] }.transform_values(&:size)
    puts "  unproven monomorphic by reason: #{by_static.sort.map { |k, v| "#{k} #{v}" }.join(', ')}"
    puts ''

    puts "== (b) static fact contradicted by run time: #{contradictions.size} =="
    contradictions.each do |p, fact, bad|
      puts "  CONTRADICTION #{label(p)} [#{p[:fn]}]  fact #{fact}  observed #{histogram(p)}  (outside the fact: #{bad.map(&:first).join(', ')})"
    end
    puts '  (none)' if contradictions.empty?
    puts ''

    puts "== (a) monomorphic at run time, no static fact (top #{options[:top]} by calls) =="
    cands = mono.reject(&proven).sort_by { |p| [-p[:calls], p[:method], p[:index]] }
    cands.first(options[:top]).each_with_index do |p, i|
      puts format('%3d. %10d  %-70s %s  [%s]', i + 1, p[:calls], label(p), p[:classes].keys.first, p[:static])
    end
    puts ''

    returns = rets.values.select { |r| r[:calls].positive? }
    ret_facts = returns.select { |r| r[:static].start_with?('ret=') && r[:static] != 'ret=none' }
    ret_contradictions = returns.filter_map do |r|
      allowed = case r[:static]
                when 'ret=fixnum' then ['Integer']
                when 'ret=array' then ['Array']
                when /\Aret=class=(.+)\z/ then [Regexp.last_match(1)]
                end
      next unless allowed

      bad = r[:classes].reject { |c, _| allowed.any? { |a| a == c || c.end_with?("::#{a}") } }
      [r, bad] unless bad.empty?
    end
    puts "== (d) returns: #{rets.size} traced, #{returns.size} reached at run time, #{ret_facts.size} with a static return fact =="
    ret_contradictions.each do |r, bad|
      puts "  CONTRADICTION #{r[:method]} [#{r[:fn]}] return #{r[:static]}  observed #{r[:classes].sort_by { |c, n| [-n, c] }.map { |c, n| "#{c} #{n}" }.join(', ')}  (outside the fact: #{bad.map(&:first).join(', ')})"
    end
    puts '  (none)' if ret_contradictions.empty?
    puts ''

    elem_rows = elems.select { |_, e| e[:calls].positive? }
    puts "== (e) container elements: #{elem_rows.size} traced slots saw Array elements or Hash keys/values =="
    elem_rows.sort_by { |(kind, site, role), e| [-e[:calls], kind.to_s, role, site.to_s] }.first(options[:top]).each do |(kind, site, role), e|
      where = if kind == :param
                label(params[site]) + " [#{params[site][:fn]}]" if params[site]
              else
                "#{site[0]} return #{site[1]}"
              end
      puts format('  %9d %-5s %-70s  %s', e[:calls], role, where || site.inspect, histogram(e))
    end
    puts '  (none)' if elem_rows.empty?
    puts ''

    unless options[:else_files].empty?
      resolved = else_by_param.reject { |k, _| k == :unresolved }
      total = ->(e) { e[:hits] + e[:may_hits] }
      puts "== (c) parameters feeding unresolved by-name sends (else-arm hits #{else_total} total; " \
           "#{else_by_param[:unresolved][:hits]} reach no parameter) =="
      puts '   "exact" = the receiver register is a plain copy of the parameter; "may" = a control-flow join, some path'
      puts '   copies the parameter (a hit counts once per candidate parameter, so the column sum can exceed the total).'
      ranked = resolved.sort_by { |(key), e| [-total.call(e), key.to_s] }
      ranked.first(options[:top]).each_with_index do |(key, e), i|
        p = params[key]
        sym, fn, name = key
        if p
          state = proven.call(p) ? 'PROVEN' : 'unproven'
          puts format('%3d. %9d else hits (exact %d, may %d)  %s  [%s, static: %s]', i + 1, total.call(e), e[:hits], e[:may_hits], label(p), state, p[:static])
          puts "       runtime (#{p[:calls]} calls): #{histogram(p)}"
        else
          puts format('%3d. %9d else hits (exact %d, may %d)  %s %s (%s): parameter not traced (function not instrumented)', i + 1, total.call(e), e[:hits], e[:may_hits], fn, name, sym)
        end
        e[:sites].tally.sort_by { |_, n| -n }.first(4).each { |s, n| puts "       send #{s}#{n > 1 ? " x#{n}" : ''}" }
      end
      traced = resolved.select { |key, _| params[key] }
      unproven_hits = traced.sum { |key, e| proven.call(params[key]) ? 0 : total.call(e) }
      mono_unproven_hits = traced.sum { |key, e| (p = params[key]) && mono.include?(p) && !proven.call(p) ? total.call(e) : 0 }
      puts ''
      puts "feeding parameters: #{resolved.size} (traced #{traced.size}); hits through unproven ones: #{unproven_hits} " \
           "(monomorphic at run time: #{mono_unproven_hits})"
    end
    end
  end

  module Candidates
  OWNER_RE = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/
  NAME_RE = /\A[a-z_]\w*[?!]?\z/
  RBS_CLASS = { 'NilClass' => 'nil', 'TrueClass' => 'bool', 'FalseClass' => 'bool' }.freeze

  # The RBS type of the observed classes: the union of what was seen (true and false both give `bool`).
  def self.rbs_type(classes)
    return 'untyped' if classes.empty?

    classes.keys.map { |c| RBS_CLASS.fetch(c, c) }.uniq.sort.join(' | ')
  end

  # The widest union the runtime guard checks linearly (DeclaredReturns::UNION_MAX, tools/bc2cpp/declared_returns.rb).
  # A wider observation is untyped: a declaration bc2cpp cannot guard is no use as a hint.
  UNION_MAX = 4

  # Observed classes wider than a union: the nearest common ancestor the hierarchy gives them (a subclass instance is
  # an instance of it, so this is a kind-of claim, not the exact-class fact a guard checks today), else the methods
  # every observed class shares as a named interface, else untyped.
  def self.bounded_type(classes, hierarchy = nil)
    return 'untyped' if classes.empty?

    names = classes.keys.map { |c| RBS_CLASS.fetch(c, c) }.uniq
    return names.sort.join(' | ') if names.size <= UNION_MAX
    return 'untyped' unless hierarchy

    ancestor = hierarchy.common_ancestor(names)
    return ancestor if ancestor

    shared = hierarchy.shared_methods(names)
    return 'untyped' if shared.empty?

    hierarchy.interface_for(shared)
  end

  # The class hierarchy and each class's own methods, from scripts/bc2cpp/class_hierarchy.rb (TSV: SUPER, DEF rows).
  class Hierarchy
    OBJECT_ROOTS = %w[Object BasicObject Kernel].freeze

    attr_reader :interfaces

    def initialize(supers, defs, includes: {}, prepends: {}, modules: Set.new, names: Set.new, extends: {}, sdefs: {},
                   dynamic: Set.new)
      @supers = supers
      @defs = defs
      @includes = includes
      @prepends = prepends
      @modules = modules
      @names = names
      @extends = extends
      @sdefs = sdefs
      @dynamic = dynamic
      @interfaces = {}
    end

    # The rows class_hierarchy.rb writes. Mixin and extend lists are in application order.
    def self.read(path)
      supers = {}
      defs = Hash.new { |h, k| h[k] = [] }
      includes = Hash.new { |h, k| h[k] = [] }
      prepends = Hash.new { |h, k| h[k] = [] }
      extends = Hash.new { |h, k| h[k] = [] }
      sdefs = Hash.new { |h, k| h[k] = [] }
      dynamic = Set.new
      modules = Set.new
      names = Set.new
      File.foreach(path) do |raw|
        kind, owner, value = raw.chomp.split("\t", 3)
        case kind
        when 'SUPER' then supers[owner] = value
        when 'DEF' then defs[owner] << value
        when 'INCLUDE' then includes[owner] << value
        when 'PREPEND' then prepends[owner] << value
        when 'EXTEND'
          # A `*` module is one the sources cannot name, so the lookup is unknown past it. A `*` owner (see
          # class_hierarchy.rb) is an extend of an unknown class, which makes every class's singleton lookup unknown.
          value == '*' ? dynamic << owner : extends[owner] << value
        when 'SDEF'
          # A `*` owner is a `def obj.x` on a receiver the sources cannot name: any class may answer x.
          dynamic << owner if owner == '*'
          sdefs[owner] << value
        when 'CLASS' then names << owner
        when 'MODULE'
          names << owner
          modules << owner
        end
      end
      new(supers, defs, includes: includes, prepends: prepends, modules: modules, names: names, extends: extends,
                        sdefs: sdefs, dynamic: dynamic)
    end

    # Whether the hierarchy names +name+ as a class or a module (a name it does not name may still be a core one).
    def program?(name)
      @names.include?(name) || @supers.key?(name)
    end

    def module?(name)
      @modules.include?(name)
    end

    def superclass(name)
      @supers[name]
    end

    def includes(name)
      @includes.fetch(name, [])
    end

    def prepends(name)
      @prepends.fetch(name, [])
    end

    # The modules extended into +name+ (and `class << self` includes), in application order.
    def extends(name)
      @extends.fetch(name, [])
    end

    # Whether the singleton lookup of +name+ may hold something the sources do not name: a dynamic extend of it, or any
    # unknown receiver's singleton def. Such a lookup cannot be read as complete.
    def unknown_singleton?(name)
      @dynamic.include?(name) || @dynamic.include?('*')
    end

    # Whether the `class << self` body or `def self.` of +name+ defines +method+. A `*` row names any method.
    def singleton_defines?(name, method)
      names = @sdefs.fetch(name, [])
      names.include?(method) || names.include?('*')
    end

    # Whether the body of +name+ defines +method+. A `*` row (a computed name) may define any method.
    def defines?(name, method)
      names = @defs.fetch(name, [])
      names.include?(method) || names.include?('*')
    end

    def chain(name)
      out = []
      cur = name
      while cur && !out.include?(cur)
        out << cur
        cur = @supers[cur]
      end
      out
    end

    def common_ancestor(names)
      chains = names.map { |n| chain(n) }
      first = chains.first.find { |c| chains.all? { |ch| ch.include?(c) } }
      first unless first.nil? || OBJECT_ROOTS.include?(first)
    end

    # Method names every observed class answers, inherited ones included. `initialize` is never a shared interface, and
    # a `*` row names no method.
    def shared_methods(names)
      sets = names.map { |n| chain(n).flat_map { |c| @defs.fetch(c, []) }.to_set }
      sets.reduce(:&).to_a.reject { |m| m == 'initialize' || m == '*' }.sort
    end

    # Names the RBS interface for a method set. The same set gets the same name, so declarations are shared.
    def interface_for(methods)
      name = "_Shared#{Digest::SHA1.hexdigest(methods.join(' '))[0, 10]}"
      @interfaces[name] = methods
      name
    end
  end

  # Merges the dumps by what a site is (method, parameter or return, name), not by the per-binary site id, so runs
  # of one build add up and runs of different builds are compared on the same key. A site whose class table
  # overflowed has classes nobody recorded, so it has no complete observed type.
  def self.read_dumps(paths)
    params = {}   # [method, kind, index, name] => { calls:, overflow:, classes: Hash }
    rets = {}     # method => { calls:, overflow:, classes: Hash }
    paths.each do |path|
      ids = {}    # this dump's [sym, id] => key
      rid = {}    # this dump's [sym, id] => method
      File.foreach(path) do |raw|
        f = raw.chomp.split("\t", -1)
        case f[0]
        when 'PARAM_SITE'
          key = [f[5], f[8], f[9].to_i, f[10]]
          ids[[f[1], f[2].to_i]] = key
          site = params[key] ||= { calls: 0, overflow: 0, classes: Hash.new(0) }
          site[:calls] += f[3].to_i
          site[:overflow] += f[4].to_i
        when 'PARAM_CLASS'
          ids.fetch([f[1], f[2].to_i], nil)&.then { |key| params[key][:classes][f[3]] += f[4].to_i }
        when 'RETURN_SITE'
          rid[[f[1], f[2].to_i]] = f[5]
          site = rets[f[5]] ||= { calls: 0, overflow: 0, classes: Hash.new(0) }
          site[:calls] += f[3].to_i
          site[:overflow] += f[4].to_i
        when 'RETURN_CLASS'
          rid.fetch([f[1], f[2].to_i], nil)&.then { |method| rets[method][:classes][f[3]] += f[4].to_i }
        end
      end
    end
    [params, rets]
  end

  # The element rows (PARAM_ELEM_*, RETURN_ELEM_*) merged the way read_dumps merges the sites they belong to:
  # { params: { [method, kind, index, name] => { role => slot } }, returns: { method => { role => slot } } }, where a
  # slot is { calls:, overflow:, classes: Hash } and role is array (Array elements), key or value (Hash entries).
  def self.read_elements(paths)
    params = {}
    returns = {}
    paths.each do |path|
      pids = {}   # this dump's [sym, id] => PARAM_SITE key
      rids = {}   # this dump's [sym, id] => method
      File.foreach(path) do |raw|
        f = raw.chomp.split("\t", -1)
        case f[0]
        when 'PARAM_SITE' then pids[[f[1], f[2].to_i]] = [f[5], f[8], f[9].to_i, f[10]]
        when 'RETURN_SITE' then rids[[f[1], f[2].to_i]] = f[5]
        when 'PARAM_ELEM_SITE'
          key = pids[[f[1], f[2].to_i]] or next
          merge_elem(elem_slot(params, key, f[3]), f[4].to_i, f[5].to_i)
        when 'PARAM_ELEM_CLASS'
          key = pids[[f[1], f[2].to_i]] or next
          elem_slot(params, key, f[3])[:classes][f[4]] += f[5].to_i
        when 'RETURN_ELEM_SITE'
          method = rids[[f[1], f[2].to_i]] or next
          merge_elem(elem_slot(returns, method, f[3]), f[4].to_i, f[5].to_i)
        when 'RETURN_ELEM_CLASS'
          method = rids[[f[1], f[2].to_i]] or next
          elem_slot(returns, method, f[3])[:classes][f[4]] += f[5].to_i
        end
      end
    end
    { params: params, returns: returns }
  end

  # The IVAR rows (a traced GETIV read, see param_trace.rb) merged by owner class and ivar name, across the dumps:
  # { [owner, "@name"] => { calls:, overflow:, classes: Hash } }. A dump without IVAR rows (one from before they were
  # recorded) contributes nothing.
  def self.read_ivars(paths)
    ivars = {}
    paths.each do |path|
      ids = {}   # this dump's [sym, id] => key
      File.foreach(path) do |raw|
        f = raw.chomp.split("\t", -1)
        case f[0]
        when 'IVAR_SITE'
          key = [f[5], f[6]]
          ids[[f[1], f[2].to_i]] = key
          site = ivars[key] ||= { calls: 0, overflow: 0, classes: Hash.new(0) }
          site[:calls] += f[3].to_i
          site[:overflow] += f[4].to_i
        when 'IVAR_CLASS'
          ids.fetch([f[1], f[2].to_i], nil)&.then { |key| ivars[key][:classes][f[3]] += f[4].to_i }
        end
      end
    end
    ivars
  end

  def self.elem_slot(table, key, role)
    ((table[key] ||= {})[role] ||= { calls: 0, overflow: 0, classes: Hash.new(0) })
  end

  def self.merge_elem(slot, calls, overflow)
    slot[:calls] += calls
    slot[:overflow] += overflow
  end

  def self.candidates(params, rets, hierarchy = nil)
    by_method = Hash.new { |h, k| h[k] = { params: {}, ret: Hash.new(0), ret_calls: 0 } }
    params.each do |(method, kind, index, name), p|
      next unless kind == 'req' && p[:calls].positive? && p[:overflow].zero?

      by_method[method][:params][index] = [name, p[:classes]]
    end
    rets.each do |method, r|
      # Ruby discards the value `initialize` returns, so no caller reads it.
      next if method.end_with?('#initialize')
      next unless r[:calls].positive? && r[:overflow].zero?

      m = by_method[method]
      r[:classes].each { |c, n| m[:ret][c] += n }
      m[:ret_calls] += r[:calls]
    end
    by_method.filter_map do |key, m|
      owner, name = key.split('#', 2)
      next unless owner && name && OWNER_RE.match?(owner) && NAME_RE.match?(name)
      next if m[:params].empty? && m[:ret_calls].zero?

      args = m[:params].sort.map { |_, (_, classes)| bounded_type(classes, hierarchy) }
      next if args.any?(&:nil?)

      ret = bounded_type(m[:ret], hierarchy)

      { owner: owner, name: name, args: args, ret: ret, calls: m[:ret_calls] }
    end
  end

  def self.render(cands, interfaces = {})
    out = +"# Trace candidates (scripts/bc2cpp/trace_types.rb candidates). Not loaded by bc2cpp; review before any hint.\n"
    interfaces.sort.each do |name, methods|
      out << "interface #{name}\n"
      methods.each { |m| out << "  def #{m}: (*untyped) -> untyped\n" }
      out << "end\n"
    end
    cands.group_by { |c| c[:owner] }.sort.each do |owner, list|
      out << "class #{owner}\n"
      list.sort_by { |c| c[:name] }.each do |c|
        ret = c[:ret].include?(' | ') ? "(#{c[:ret]})" : c[:ret] # RBS needs parentheses for a union return
        out << "  def #{c[:name]}: (#{c[:args].join(', ')}) -> #{ret}\n"
      end
      out << "end\n"
    end
    out
  end

  def self.main(argv)
    out_path = nil
    hierarchy_path = nil
    args = argv.dup
    while args.first&.start_with?('--')
      flag = args.shift
      case flag
      when '--out' then out_path = args.shift
      when '--hierarchy' then hierarchy_path = args.shift
      else abort "unknown option #{flag}"
      end
    end
    abort 'usage: trace_types.rb candidates [--out FILE] [--hierarchy TSV] dump.txt [...]' if args.empty?

    params, rets = read_dumps(args)
    hierarchy = hierarchy_path && Hierarchy.read(hierarchy_path)
    cands = candidates(params, rets, hierarchy)
    text = render(cands, hierarchy ? hierarchy.interfaces : {})
    if out_path
      File.write(out_path, text)
      puts "wrote #{out_path}"
    else
      print text
    end
  end
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  case command
  when 'report' then TraceTypes::Report.run(ARGV)
  when 'candidates' then TraceTypes::Candidates.main(ARGV)
  else abort 'usage: trace_types.rb report|candidates [args] (see the header)'
  end
end
