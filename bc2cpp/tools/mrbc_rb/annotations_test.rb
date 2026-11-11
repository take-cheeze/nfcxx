# frozen_string_literal: true

# Cross-check of the emitter's class-scope annotations (annotations.rb) against bc2cpp's bytecode dataflow derivations, for every
# input of the corpus (bc2cpp/**/*.rb; with MRBC also the gem mrblib sets and rpg-maker-clone's .rb files, as structured_test.rb):
#   * class_body_path: annotation (exact) vs reaching-definitions dataflow, given the same lexical namespace;
#   * class_bodies (opener -> body irep): annotation vs the opener-EXEC adjacency;
#   * the LexicalConsts scope of every irep and the keys it resolves (read_keys / site_keys).
# Every difference is classified. A difference in LIMITATIONS is a documented dataflow limitation (listed with a sample); any other
# is a bug in one of the two and fails the run. Annotations must also be well formed (every recorded pc is the recorded op).
#   MRBC=<mrbc> bundle exec ruby bc2cpp/tools/mrbc_rb/annotations_test.rb
require_relative '../bc2cpp/irep'
require_relative '../bc2cpp/lexical_consts'
require_relative '../bc2cpp/dynamic_names'

# kind => why the dataflow cannot (or does not) give the annotation's answer.
LIMITATIONS = {
  path_compact: 'class A::B / class ::B: the outer register is a constant path / OCLASS-with-GETMCNST, "resolved by the caller"; the annotation resolves the written path (exact at top level or ::-rooted)',
  path_lexical_unproven: 'plain `class X` whose outer LOADNIL the reaching-definition proof could not establish (a handler/loop/closure writes the register)',
  path_in_sclass: 'class/module inside `class << obj`: dataflow names it Namespace::X, but it is defined on the singleton class (annotation: unknown)',
  body_unlinked: 'a body the EXEC-adjacency scan does not pair with its opener',
  scope_compact: 'LexicalConsts treats a compact/::-rooted/singleton scope as :unknown, the annotation says which and agrees (counted, not a difference)',
  scope_gain: 'LexicalConsts scope the dataflow proof lost (:unknown) but the cref chain gives exactly',
  key_gain: 'a constant read/site key the dataflow could not resolve that the exact scope resolves',
  key_loss: 'a constant key resolved by dataflow that the exact scope refuses (compact definition now defined in its real scope)',
  key_change: 'a constant key that differs between the two scope models'
}.freeze

oracle = ENV.fetch('MRBC', nil)

corpus = Dir.glob('bc2cpp/**/*.rb').sort.map { |p| [p] }
if oracle
  mruby_dir = File.expand_path('../..', oracle)
  world_root = File.expand_path('../..', mruby_dir)
  sets = { 'core mrblib' => Dir["#{mruby_dir}/mrblib/*.rb"].sort.reject { |p| p.end_with?('/10error.rb') } }
  (Dir["#{mruby_dir}/mrbgems/*"] + Dir["#{world_root}/3rd/*"] + Dir["#{world_root}/mruby-*"]).sort.each do |gem_dir|
    sets[File.basename(gem_dir)] = Dir["#{gem_dir}/mrblib/**/*.rb"].sort
  end
  sets.each_value { |files| corpus << files if files.size >= 2 }
  corpus.concat(Dir.glob("#{world_root}/**/*.rb").reject { |p| p.include?('/3rd/') || p.include?('/.git/') }.sort.map { |p| [p] })
else
  puts 'note: MRBC unset, the gem mrblib sets and the rpg-maker-clone files are not checked'
end

counts = Hash.new(0)
samples = Hash.new { |h, k| h[k] = [] }
bugs = []

note = lambda do |kind, where|
  counts[kind] += 1
  samples[kind] << where if samples[kind].size < 3
  bugs << "#{kind}: #{where}" unless LIMITATIONS.key?(kind) || %i[ok].include?(kind)
end

scope_models = lambda do |ireps|
  model = LexicalConsts::Model.new(ireps)
  [model.instance_variable_get(:@scope), LexicalConsts.analyze(ireps, static: true)]
end

# Synthetic programs for the forms the corpus lacks, each with the exact annotation facts expected: [opener name => [path, outer]].
SYNTHETIC = {
  'compact' => ["class A; end\nclass A::B; end\nclass ::C; end\nmodule M\n  class ::D; end\n  class A::E < B; end\n  class F; end\nend\n",
                { 'A' => ['A', :lexical], 'M' => ['M', :lexical], 'B' => ['A::B', :path], 'C' => ['C', :root], 'D' => ['D', :root], 'E' => [nil, :path], 'F' => ['M::F', :lexical] }],
  'dynamic' => ["x = Object\nclass x::G; end\nclass << x; class H; end; end\n", { 'G' => [nil, :dynamic], 'H' => [nil, :lexical] }],
  'sclass' => ["class K\n  class << self\n    def a; end\n    class L; end\n  end\nend\n", { 'K' => ['K', :lexical], 'L' => [nil, :lexical] }],
  'struct_block' => ["S = Struct.new(:a) do\n  def z; end\nend\nclass N\n  [1].each { def y; end }\nend\n", { 'N' => ['N', :lexical] }]
}.freeze
synthetic_failures = []

covered = 0
inputs = corpus.map { |paths| ["#{paths.first}#{paths.size > 1 ? " (+#{paths.size - 1})" : ''}", -> { mrbc_rb_image(paths).first }] }
SYNTHETIC.each do |name, (src, expected)|
  inputs << ["synthetic #{name}", lambda {
    r = MrbcRb.compile_result(src, "#{name}.rb")
    openers = r.annotations[:ireps].flat_map { |rec| rec[:ops].values }.select { |o| %i[CLASS MODULE].include?(o[:op]) }
    got = openers.to_h { |o| [o[:name], [o[:path], o[:outer]]] }
    synthetic_failures << "#{name}: #{got.inspect} != #{expected.inspect}" unless got == expected
    r
  }]
end
inputs.each do |tag, build|
  result = build.call
  next unless result

  covered += 1
  image = RiteImage.new(result.image, rites_from_tree(result.tree), result.annotations)
  ann, root = load_ireps(image, cache: nil)
  ENV['BC2CPP_CLASS_SCOPE'] = '0'
  flow, = load_ireps(image, cache: nil)
  ENV.delete('BC2CPP_CLASS_SCOPE')
  bugs << "not attached: #{tag}" unless ann.each_value.all?(&:class_scope) && flow.each_value.none?(&:class_scope)
  next unless ann.each_value.all?(&:class_scope)

  err = MrbcRb::Annotations.verify(result.annotations, dfs_order(ann, root).map { |l| ann[l].class_scope[:ops].to_h { |a, o| [a, o[:op]] } })
  # (addresses are decoded addresses here; pcs agree with them unless an EXT prefix is not folded)
  note.call(:malformed, "#{tag}: #{err}") if err && InsnDecoder.fold_ext_prefix?

  ann.each do |label, irep|
    other = flow.fetch(label)
    ops = %i[CLASS MODULE SCLASS]
    a_bodies = BytecodeIR.class_bodies(irep, *ops)
    f_bodies = BytecodeIR.class_bodies(other, *ops)
    (a_bodies.keys | f_bodies.keys).each do |idx|
      if a_bodies[idx] == f_bodies[idx] then note.call(:ok, '')
      elsif a_bodies[idx] && f_bodies[idx].nil? then note.call(:body_unlinked, "#{tag} #{label}[#{idx}]")
      else note.call(:body_differs, "#{tag} #{label}[#{idx}] #{a_bodies[idx].inspect} vs #{f_bodies[idx].inspect}")
      end
    end
    irep.each_with_op(:CLASS, :MODULE) do |insn, idx|
      op = ClassScope.op_at(irep, insn)
      namespace = op[:namespace]
      exact = BytecodeIR.class_body_path(irep, idx, namespace)
      derived = BytecodeIR.class_body_path(other, idx, namespace)
      where = "#{tag} #{label}[#{idx}] #{op[:written]} line #{op[:line]}"
      if exact == derived then note.call(:ok, '')
      elsif derived.nil? then note.call(op[:outer] == :lexical ? :path_lexical_unproven : :path_compact, where)
      elsif exact.nil? && op[:cref_in_sclass] != false && (irep.class_scope[:cref].any? { |e| e[:kind] == :sclass } || op[:namespace].nil?) then note.call(:path_in_sclass, where)
      else note.call(:path_differs, "#{where}: annotation #{exact.inspect} dataflow #{derived.inspect}")
      end
    end
  end

  a_scope, a_keys = scope_models.call(ann)
  f_scope, f_keys = scope_models.call(flow)
  a_scope.each do |label, scope|
    f = f_scope[label]
    if scope == f then note.call(:ok, '')
    elsif f == :unknown then note.call(:scope_gain, "#{tag} #{label}: #{scope.inspect}")
    elsif scope == :unknown then note.call(:scope_compact, "#{tag} #{label}: dataflow #{f.inspect}")
    else note.call(:scope_differs, "#{tag} #{label}: annotation #{scope.inspect} dataflow #{f.inspect}")
    end
  end
  %i[read_keys site_keys].each do |field|
    a_map = a_keys[field]
    f_map = f_keys[field]
    # keyed by (label, address): the Insn objects of the two decodes are distinct
    index = lambda do |trees, map|
      out = {}
      trees.each { |label, irep| irep.instructions.each { |i| out[[label, i.addr]] = map[i] if map.key?(i) } }
      out
    end
    a_idx = index.call(ann, a_map)
    f_idx = index.call(flow, f_map)
    (a_idx.keys | f_idx.keys).each do |k|
      a = a_idx[k]
      f = f_idx[k]
      if a == f then next
      elsif f.nil? then note.call(:key_gain, "#{tag} #{k.inspect} #{field}: #{a.inspect}")
      elsif a.nil? then note.call(:key_loss, "#{tag} #{k.inspect} #{field}: #{f.inspect}")
      else note.call(:key_change, "#{tag} #{k.inspect} #{field}: #{a.inspect} vs #{f.inspect}")
      end
    end
  end
end

# ---- call records (annotations version 2): the send as written, for the mixin / name-taking / visibility sends --------------------
# [name, recv, recv_text, args] per record in pc order; an arg is [:sym|:str, value], [:const, written path], or its bare kind.
CALL_SYNTHETIC = {
  'mixins and names' => ["class A\n  include B::C\n  include ::D\n  extend self\n  attr_accessor(:a, 'b', *c)\n  include(include(E))\n  def m(x)\n    x.include(F)\n    Foo.send(:bar, k: 1)\n    self.extend(G)\n    respond_to?(:z)\n  end\nend\n",
                         [['include', :implicit, nil, [[:const, 'B::C']]], ['include', :implicit, nil, [[:const, '::D']]], ['extend', :implicit, nil, [:other]],
                          ['attr_accessor', :implicit, nil, [[:sym, 'a'], [:str, 'b'], :splat]], ['include', :implicit, nil, [[:const, 'E']]],
                          ['include', :implicit, nil, [:other]], ['include', :other, nil, [[:const, 'F']]], ['send', :const, 'Foo', [[:sym, 'bar'], :keywords]],
                          ['extend', :self, nil, [[:const, 'G']]], ['respond_to?', :implicit, nil, [[:sym, 'z']]]]],
  'past 14 arguments' => ["class B\n  attr_accessor(#{(1..16).map { |i| ":a#{i}" }.join(', ')})\nend\n",
                          [['attr_accessor', :implicit, nil, (1..16).map { |i| [:sym, "a#{i}"] }]]]
}.freeze
CALL_SYNTHETIC.each do |name, (src, expected)|
  r = MrbcRb.compile_result(src, "#{name}.rb")
  got = r.annotations[:ireps].flat_map { |rec| rec[:ops].values }.filter_map { |o| o[:call] }.map do |c|
    [c[:name], c[:recv], c[:recv_text], c[:args].map { |a| %i[sym str].include?(a[:kind]) ? [a[:kind], a[:value]] : a[:kind] == :const ? [:const, a[:text]] : a[:kind] }]
  end
  bugs << "call records #{name}: #{got.inspect} != #{expected.inspect}" unless got == expected && r.annotations[:version] == MrbcRb::Annotations::VERSION
end

# ---- what bc2cpp reads from them -------------------------------------------------------------------------------------------------
# A source as bc2cpp's loader gets it, with the annotations (+annotated+) or without (the dataflow path of an mrbc image).
load_source = lambda do |src, annotated|
  r = MrbcRb.compile_result(src, 'model.rb')
  ENV['BC2CPP_CLASS_SCOPE'] = '0' unless annotated
  ireps, = load_ireps(RiteImage.new(r.image, rites_from_tree(r.tree), r.annotations), cache: nil)
  ireps
ensure
  ENV.delete('BC2CPP_CLASS_SCOPE')
end
const_keys = lambda do |ireps, name|
  keys = LexicalConsts.analyze(ireps, static: true)[:read_keys]
  found = []
  ireps.each_value { |irep| irep.each_with_op(:GETCONST) { |insn, _| found << keys[insn] if insn.const_name == name } }
  found
end
# [source, constant read, resolved key with annotations, key without]: a mixin by constant path or a superclass by name no longer
# makes every ancestor set unknown; an unmodelled form still does.
MODEL_SYNTHETIC = [
  ['mixin path', "module Outer\n  module Shared\n    LIMIT = 1\n  end\nend\nclass Base\n  include Outer::Shared\nend\nclass Kid < Base\n  def f = LIMIT\nend\n", 'LIMIT', 'Outer::Shared::LIMIT', nil],
  ['rooted mixin and Object mixin', "module Shared\n  LIMIT = 1\nend\nclass Object\n  include ::Shared\nend\nclass Kid\n  def f = LIMIT\nend\n", 'LIMIT', 'Shared::LIMIT', nil],
  ['superclass through a namespace', "module NS\n  class Base\n    LIMIT = 1\n  end\n  class Kid < Base\n    def f = LIMIT\n  end\nend\n", 'LIMIT', 'NS::Base::LIMIT', nil],
  ['computed mixin', "module Shared\n  LIMIT = 1\nend\nclass Base\n  include(Shared.itself)\nend\nclass Kid < Base\n  def f = LIMIT\nend\n", 'LIMIT', nil, nil],
  ['core superclass', "class Err < StandardError\n  LIMIT = 1\nend\nclass Kid < Err\n  def f = LIMIT\nend\n", 'LIMIT', nil, nil],
  ['computed superclass', "class Base; LIMIT = 1; end\nclass Kid < Struct.new(:a)\n  def f = LIMIT\nend\n", 'LIMIT', nil, nil]
].freeze
MODEL_SYNTHETIC.each do |name, src, const, with, without|
  got = const_keys.call(load_source.call(src, true), const)
  bugs << "model #{name}: annotated #{got.inspect}, expected #{[with].inspect}" unless got.compact.uniq == [with].compact && got.size == 1
  base = const_keys.call(load_source.call(src, false), const)
  bugs << "model #{name}: dataflow #{base.inspect}, expected #{[without].inspect}" unless base.size == 1 && base.first == without
end
# A call past 14 arguments packs them into an Array: only the call record shows the first one is a literal Symbol.
packed = "class B\n  attr_accessor(#{(1..16).map { |i| ":a#{i}" }.join(', ')})\nend\n"
bugs << 'dynamic names: a packed literal attr_accessor is computed with the annotation' if DynamicNames.analyze(load_source.call(packed, true))[1]
bugs << 'dynamic names: a packed literal attr_accessor stays computed without the annotation (the documented dataflow limit)' unless DynamicNames.analyze(load_source.call(packed, false))[1]
bugs << 'dynamic names: send(name) must stay computed' unless DynamicNames.analyze(load_source.call("def f(n)\n  send(n)\nend\n", true))[1]

puts "annotations: #{covered} of #{inputs.size} inputs covered by the emitter; #{counts[:ok]} annotation/dataflow answers agree"
counts.each do |kind, n|
  next if kind == :ok

  tagline = LIMITATIONS[kind] ? "limitation (#{LIMITATIONS[kind]})" : 'DIFFERENCE (bug in one of the two)'
  puts "  #{kind}: #{n} -- #{tagline}"
  samples[kind].each { |s| puts "      e.g. #{s}" }
end
synthetic_failures.each { |f| bugs << "synthetic #{f}" }
bugs.first(20).each { |b| puts "  BUG #{b}" }
puts bugs.empty? ? 'no unexplained difference' : "#{bugs.size} unexplained difference(s)"
exit(bugs.empty? && covered.positive? ? 0 : 1)
