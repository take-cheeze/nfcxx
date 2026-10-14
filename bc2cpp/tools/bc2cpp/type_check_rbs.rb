# frozen_string_literal: true

require 'fileutils'
require 'set'

# TYPE_CHECK_RBS (docs/adr/0414): the inferred types of a type-check run (type_facts.rb) as RBS files, so Steep,
# TypeProf and RBS-aware editors can read what bc2cpp proved. `scripts/bc2cpp/type_check.rb --emit-rbs DIR` writes one
# `.rbs` per class / module below DIR (Game::Actor -> DIR/Game/Actor.rbs).
#
# What is written:
#   * every class / module the program defines that is not in CRuby's core RBS, with its superclass (reopened core
#     classes are not redeclared; only their methods the core RBS lacks are written);
#   * `def name: (T, T, ?untyped, *untyped, **untyped) ?{ (*untyped) -> untyped } -> R` per method: the mandatory
#     parameters carry the inferred / declared type or `untyped`; optional, rest and keyword parameters are `untyped`
#     (bc2cpp does not infer them); every method accepts an optional block (the facts do not know which methods yield);
#   * `@ivar: T` per ivar and `NAME: T` per constant with a type, `untyped` otherwise;
#   * `def self.x` for singleton methods; `private` for private methods.
# A type that names a class the program and the core RBS do not declare becomes `untyped`; `Array` / `Hash` / `Range`
# without arguments become `Array[untyped]` ...; nilable `T?` stays. Nothing is guessed: no type, `untyped`.
#
# The directory is NOT read back as hints by the compiler (it is not sig/bc2cpp); point BC2CPP_SIG_DIRS at it
# (or copy files into sig/bc2cpp) to turn what bc2cpp inferred into declared hints, which the type check then compares
# with the inference again (a round trip that reports nothing).
module TypeCheckRbs
  GENERIC = { 'Array' => 'Array[untyped]', 'Hash' => 'Hash[untyped, untyped]', 'Range' => 'Range[untyped]',
              'Enumerator' => 'Enumerator[untyped, untyped]', 'Proc' => 'Proc' }.freeze
  CORE_KEYWORD_TYPES = %w[nil bool self untyped void].freeze

  module_function

  # Names of the classes and modules in CRuby's core RBS, and a predicate for "this core class has that instance method".
  def core_env
    require 'rbs'
    loader = RBS::EnvironmentLoader.new
    env = RBS::Environment.from_loader(loader).resolve_type_names
    builder = RBS::DefinitionBuilder.new(env: env)
    names = env.class_decls.keys.map { |n| n.to_s.delete_prefix('::') }.to_set
    has_method = lambda do |klass, meth, singleton|
      tn = RBS::TypeName.parse("::#{klass}")
      d = singleton ? builder.build_singleton(tn) : builder.build_instance(tn)
      d.methods.key?(meth.to_sym)
    rescue StandardError
      false
    end
    [names, has_method]
  rescue LoadError
    [Set.new, ->(*) { false }]
  end

  def rbs_type(text, declared)
    return 'untyped' if text.nil? || text.to_s.empty?

    parts = text.to_s.split(' | ').map do |atom|
      nilable = atom.end_with?('?')
      a = atom.delete_suffix('?')
      t = if CORE_KEYWORD_TYPES.include?(a) then a
          elsif (m = /\A(Array|Hash)\[(.+)\]\z/.match(a))
            m[1] == 'Array' ? "Array[#{rbs_type(m[2], declared)}]" : "Hash[untyped, #{rbs_type(m[2], declared)}]"
          elsif GENERIC.key?(a) then GENERIC[a]
          elsif declared.include?(a) then a
          else 'untyped'
          end
      nilable && t != 'untyped' ? "#{t}?" : t
    end.uniq
    parts.include?('untyped') ? 'untyped' : parts.join(' | ')
  end

  def method_line(m, declared, singleton: false)
    positional = m['params'].map { |p| rbs_type(p['type'], declared) }
    positional.concat((0...m['opt'].to_i).map { |index| '?'+rbs_type(Array(m['optional_params'])[index]&.[]('type'), declared) })
    positional << '*untyped' if m['rest']
    keywords = Array(m['keyword_params'])
    keywords.each { |param| positional << "#{param['required'] ? '' : '?'}#{param['name']}: #{rbs_type(param['type'], declared)}" }
    positional << '**untyped' if m['kdict'] || keywords.empty? && m['key'].to_i.positive?
    ret = rbs_type(m['return']['type'], declared)
    ret = 'self' if m['return']['type'] == 'self'
    ret = 'void' if m['name'] == 'initialize'
    ret = "(#{ret})" if ret.include?(' | ') # an unparenthesised union reads as an overload separator
    "def #{singleton ? 'self.' : ''}#{m['name']}: (#{positional.join(', ')}) ?{ (*untyped) -> untyped } -> #{ret}"
  end

  def valid_member?(line)
    require 'rbs'
    RBS::Parser.parse_signature("class X\n  #{line}\nend\n")
    true
  rescue RBS::ParsingError
    false
  end

  # A suggested return needs an inferred answer at every exit, independent of its declared contract.
  def inferred_return_suggestions(facts, scope: 'engine')
    rows = Array(facts['ir_feedback']).select { |row| row['kind'] == 'return' && (scope == 'all' || row['scope'] == scope) }
    rows.group_by { |row| [row['owner'], row['method']] }.filter_map do |(owner, method), exits|
      next unless exits.all? { |row| %w[inferred mismatch possible_mismatch].include?(row['status']) && row['type'] }

      types = exits.flat_map { |row| row['type'].split(' | ') }.uniq.sort
      { 'owner' => owner, 'method' => method, 'type' => types.join(' | '), 'source' => 'inferred:bytecode-ir' }
    end
  end

  def suggestion_facts(facts, scope: 'engine')
    suggestions = inferred_return_suggestions(facts, scope: scope).to_h { |row| [[row['owner'], row['method']], row] }
    facts.merge('methods' => facts['methods'].map do |method|
      suggestion = suggestions[[method['owner'], method['name']]]
      suggestion ? method.merge('return' => { 'type' => suggestion['type'], 'source' => suggestion['source'], 'reason' => nil }) : method
    end)
  end

  # Writes the files; returns { files:, methods:, skipped: [[reason, what]] }.
  def emit(facts, dir, scope: 'engine')
    core_names, core_has = core_env
    classes = facts['classes'] || []
    ours = classes.map { |c| c['name'] }.reject { |n| core_names.include?(n) }.to_set
    declared = ours | core_names
    kind_of = classes.to_h { |c| [c['name'], c] }
    members = Hash.new { |h, k| h[k] = { methods: [], ivars: [], consts: [] } }
    skipped = []
    facts['methods'].each do |m|
      next unless scope == 'all' || m['scope'] == scope

      owner = m['owner']
      next if owner.start_with?('<')

      singleton = owner.end_with?('.singleton')
      base = owner.delete_suffix('.singleton')
      members[base][:methods] << [m, singleton]
    end
    facts['ivars'].each do |i|
      next unless scope == 'all' || i['scope'] == scope

      members[i['owner']][:ivars] << i
    end
    facts['constants'].each do |c|
      next unless scope == 'all' || c['scope'] == scope
      next unless c['owner']

      members[c['owner']][:consts] << c
    end
    (ours.to_a & members.keys | ours.to_a).each { |o| members[o] }
    FileUtils.mkdir_p(dir)
    written = []
    method_count = 0
    members.keys.sort.each do |owner|
      next if owner.empty? || owner.start_with?('<')

      info = kind_of[owner] || { 'kind' => 'class', 'superclass' => nil }
      core = core_names.include?(owner)
      body = []
      pub = []
      priv = []
      members[owner][:methods].sort_by { |m, s| [s ? 1 : 0, m['name']] }.each do |m, singleton|
        next if core && core_has.call(owner, m['name'], singleton)

        line = method_line(m, declared, singleton: singleton)
        unless valid_member?(line)
          skipped << ['unparseable method', "#{owner}#{singleton ? '.' : '#'}#{m['name']}"]
          next
        end
        (m['visibility'] == 'private' ? priv : pub) << line
        method_count += 1
      end
      members[owner][:ivars].sort_by { |i| i['name'] }.each do |i|
        line = "#{i['name']}: #{rbs_type(i['type'], declared)}"
        valid_member?(line) ? body << line : skipped << ['unparseable ivar', "#{owner}#{i['name']}"]
      end
      members[owner][:consts].sort_by { |c| c['name'] }.each do |c|
        name = c['name'].split('::').last
        next unless name.match?(/\A[A-Z]\w*\z/)

        line = "#{name}: #{rbs_type(c['type'], declared)}"
        valid_member?(line) ? body << line : skipped << ['unparseable constant', c['name']]
      end
      next if core && body.empty? && pub.empty? && priv.empty?

      body.concat(pub)
      unless priv.empty?
        body << 'private'
        body.concat(priv)
      end
      head = if info['kind'] == 'module' then "module #{owner}"
             else
               sup = info['superclass']
               sup && declared.include?(sup) && sup != owner ? "class #{owner} < #{sup}" : "class #{owner}"
             end
      path = File.join(dir, *owner.split('::')) + '.rbs'
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{head}\n#{body.map { |l| "  #{l}\n" }.join}end\n")
      written << path
    end
    { files: written, methods: method_count, skipped: skipped }
  end
end
