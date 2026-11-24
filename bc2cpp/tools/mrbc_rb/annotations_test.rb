# frozen_string_literal: true

# Cross-check of the emitter's class-scope annotations (annotations.rb) against bc2cpp's bytecode dataflow derivations, for every
# input of the corpus (bc2cpp/**/*.rb; with MRBC also the gem mrblib sets and rpg-maker-clone's .rb files, as structured_test.rb):
#   * class_body_path: annotation (exact) vs reaching-definitions dataflow, given the same lexical namespace;
#   * class_bodies (opener -> body irep): annotation vs the opener-EXEC adjacency;
#   * the LexicalConsts scope of every irep and the keys it resolves (read_keys / site_keys);
#   * the loop and block-send records (version 4) against their bytecode (LoopRecords.check: any contradiction fails).
# Every difference is classified. A difference in LIMITATIONS is a documented dataflow limitation (listed with a sample); any other
# is a bug in one of the two and fails the run. Annotations must also be well formed (every recorded pc is the recorded op).
#   MRBC=<mrbc> bundle exec ruby bc2cpp/tools/mrbc_rb/annotations_test.rb
require_relative '../bc2cpp/irep'
require_relative '../bc2cpp/lexical_consts'
require_relative '../bc2cpp/dynamic_names'
require_relative '../bc2cpp/const_conditional'
require_relative '../bc2cpp/loop_records'

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
  key_change: 'a constant key that differs between the two scope models',
  cond_loose: 'a constant write the emitter knows runs whenever the program loads that the bytecode dataflow cannot prove does (`X = (a rescue b)`: the handler joins before the write)'
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

loop_counts = Hash.new(0)
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
  loops = LoopRecords.check(ann)
  loops.contradictions.each { |row| note.call(:loop_contradiction, "#{tag} #{row}") }
  loops.counts.each { |k, n| loop_counts[k] += n }

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

  # CONST_CONDITIONAL: the dataflow may only be more conservative than the emitter (a write it calls unconditional must be one).
  f_cond = ConstConditional.sites(flow)
  ConstConditional.sites(ann).each do |site, conditional|
    derived = f_cond[site]
    if derived == conditional then note.call(:ok, '')
    elsif !conditional && derived then note.call(:cond_loose, "#{tag} #{site.inspect}")
    else note.call(:cond_differs, "#{tag} #{site.inspect}: annotation #{conditional.inspect} dataflow #{derived.inspect}")
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
# CONST_CONDITIONAL: the writes that may not run, from the annotation and from the dataflow.
cond_src = <<~RUBY
  A0 = 1
  class FoldA
    W = 2
    NEVER = 9 if W == 0
    (P = 3)
    begin
      Q = 4
    end
    S = (6 rescue nil)
    [1].each { BLK = 1 }
    begin
      RESCUED = 1
    rescue StandardError
      nil
    end
    while W == 9
      LOOPED = 1
    end
    if W
      class Inner
        IN = 1
      end
    end
    class Ok
      OK = 1
    end
    FoldA::PATH = 7
    T ||= 8
    M1, M2 = 1, 2
    raise 'x' if W == 3
    RAISED = 1
  end
  return if A0 == 2
  LATE = 1
RUBY
cond_expected = %w[NEVER BLK RESCUED LOOPED IN T RAISED LATE].to_set
%w[annotated dataflow].each do |mode|
  got = ConstConditional.names(load_source.call(cond_src, mode == 'annotated'))
  bugs << "conditional constants (#{mode}): #{got.to_a.sort.inspect} != #{cond_expected.to_a.sort.inspect}" unless got == cond_expected
end

# A call past 14 arguments packs them into an Array: only the call record shows the first one is a literal Symbol.
packed = "class B\n  attr_accessor(#{(1..16).map { |i| ":a#{i}" }.join(', ')})\nend\n"
bugs << 'dynamic names: a packed literal attr_accessor is computed with the annotation' if DynamicNames.analyze(load_source.call(packed, true))[1]
bugs << 'dynamic names: a packed literal attr_accessor stays computed without the annotation (the documented dataflow limit)' unless DynamicNames.analyze(load_source.call(packed, false))[1]
bugs << 'dynamic names: send(name) must stay computed' unless DynamicNames.analyze(load_source.call("def f(n)\n  send(n)\nend\n", true))[1]

# ---- loop and block-send records (annotations version 4) ----------------------------------------------------------------------
loop_src = <<~RUBY
  def f(n, a)
    i = 0
    while i < n
      i += 1
      next if i == 2
      redo if i == 99
      j = 0
      until j > i
        j += 1
        break if j == 5
        return nil if j == 7
        raise 'x' if j < 0
      end
      if false
        dead = 1
      end
      begin
        a.fetch(i)
      rescue IndexError => e
        retry if i == 50
      end
      a.each { |x| i += x }
      a.map(&:to_s)
      for k in a do; end
    end
    begin
      i -= 1
    end while i > 0
    i
  end
  class LoopB
    def g(*r, &b)
      super { |q, *s, o: 1, &c| q }
      super(&b)
      super
      r.each { _1 }
    end
  end
RUBY
loop_result = MrbcRb.compile_result(loop_src, 'loops.rb')
bugs << "loop records: table version #{loop_result.annotations[:version]}" unless loop_result.annotations[:version] == 4
loop_recs = loop_result.annotations[:ireps].flat_map { |rec| rec[:loops] }
got = loop_recs.map { |l| [l[:kind], l[:post_test], l[:line], l[:exits].map { |e| e[:kind] }, l[:writes]] }
want = [[:while, false, 3, %i[next redo return raise retry], %w[dead e i j k]], [:until, false, 8, %i[break return raise], %w[j]],
        [:while, true, 26, [], %w[i]]]
bugs << "loop records: #{got.inspect} != #{want.inspect}" unless got == want
sends = loop_result.annotations[:ireps].flat_map { |rec| rec[:block_sends].values }
got = sends.map { |b| [b[:op], b[:method], b[:block], b[:sym], b[:recv][:kind], b[:params]&.map { |p| p[:kind] }] }
want = [[:SENDB, 'each', :literal, nil, :local, %i[req]], [:SENDB, 'map', :sym, 'to_s', :local, nil], [:SENDB, 'each', :for, nil, :local, nil],
        [:SUPER, 'super', :literal, nil, :implicit, %i[req rest key block]], [:SUPER, 'super', :pass, nil, :implicit, nil],
        [:SUPER, 'super', :implicit, nil, :implicit, nil], [:SENDB, 'each', :literal, nil, :local, %i[numbered]]]
bugs << "block-send records: #{got.inspect} != #{want.inspect}" unless got == want

# Each edit of the table is a record its bytecode contradicts, which LoopRecords.check reports (the unedited table passes,
# with `dead` the one name the AST counts and the code never stores).
loop_check = lambda do |edit|
  table = Marshal.load(Marshal.dump(loop_result.annotations))
  edit&.call(table[:ireps])
  ireps, = load_ireps(RiteImage.new(loop_result.image, rites_from_tree(loop_result.tree), table), cache: nil)
  next nil unless ireps.each_value.all?(&:class_scope)

  LoopRecords.check(ireps)
end
clean = loop_check.call(nil)
bugs << "loop records: the emitter's table is contradicted: #{clean.contradictions.first(3)}" unless clean&.contradictions&.empty?
bugs << "loop records: write sets #{clean.counts.inspect}" unless clean && clean.counts[:writes_ast_only] == 1 && clean.counts[:writes_equal] == 2
outer = ->(ireps) { ireps.find { |r| r[:loops].any? }[:loops].first }
sends_of = ->(ireps) { ireps.find { |r| r[:block_sends].size > 1 }[:block_sends] }
LOOP_EDITS = {
  'back edge' => ->(t) { outer.call(t)[:back_pc] -= 3 },
  'body pc' => ->(t) { outer.call(t)[:body_pc] += 1 },
  'next as break' => ->(t) { outer.call(t)[:exits].find { |e| e[:kind] == :next }[:kind] = :break },
  'dropped next' => ->(t) { outer.call(t)[:exits].reject! { |e| e[:kind] == :next } },
  'dropped redo' => ->(t) { outer.call(t)[:exits].reject! { |e| e[:kind] == :redo } },
  'dropped return' => ->(t) { outer.call(t)[:exits].reject! { |e| e[:kind] == :return } },
  'dropped raise' => ->(t) { outer.call(t)[:exits].reject! { |e| e[:kind] == :raise } },
  'raise as return' => ->(t) { outer.call(t)[:exits].find { |e| e[:kind] == :raise }[:kind] = :return },
  'dropped write' => ->(t) { outer.call(t)[:writes].delete('j') },
  'dropped upvar write' => ->(t) { outer.call(t)[:writes].delete('i') },
  'block irep' => ->(t) { sends_of.call(t).each_value.find { |b| b[:block] == :literal }[:block_irep] = 0 },
  'sym' => ->(t) { sends_of.call(t).each_value.find { |b| b[:block] == :sym }[:sym] = 'to_i' },
  'literal as pass' => ->(t) { sends_of.call(t).each_value.find { |b| b[:block] == :literal }[:block] = :pass },
  'method' => ->(t) { sends_of.call(t).each_value.find { |b| b[:block] == :for }[:method] = 'map' },
  'dropped send' => ->(t) { sends_of.call(t).delete(sends_of.call(t).keys.first) }
}.freeze
LOOP_EDITS.each do |name, edit|
  r = loop_check.call(edit)
  bugs << "loop records: edit '#{name}' is not reported" unless r && !r.contradictions.empty?
end
# A version 3 table (no loop records) still attaches, and there is nothing to check.
v3 = Marshal.load(Marshal.dump(loop_result.annotations))
v3[:version] = 3
v3[:ireps].each { |rec| rec.delete(:loops) && rec.delete(:block_sends) }
v3_ireps, = load_ireps(RiteImage.new(loop_result.image, rites_from_tree(loop_result.tree), v3), cache: nil)
v3_check = LoopRecords.check(v3_ireps)
bugs << 'loop records: a version 3 table does not attach' unless v3_ireps.each_value.all?(&:class_scope)
bugs << "loop records: a version 3 table is checked #{v3_check.counts.inspect}" unless v3_check.counts.empty? && v3_check.contradictions.empty?

puts "annotations: #{covered} of #{inputs.size} inputs covered by the emitter; #{counts[:ok]} annotation/dataflow answers agree"
puts "loop records: #{loop_counts[:loops]} loops (writes equal #{loop_counts[:writes_equal]}, a recorded name the code never " \
     "stores #{loop_counts[:writes_ast_only]}), #{loop_counts[:block_sends]} block sends"
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
