#!/usr/bin/env ruby
# frozen_string_literal: true

# BLOCK_SELF_WORLD (docs/adr/0477): a block's `self` is its creating frame's self unless a rebinder runs it under
# another one.
#
# 1. The world analysis (MRBC; snippets compiled in-process, seconds): which literal blocks are REBOUND (nested ones
#    included), which shapes make the world fact fail (a non-literal block to a rebinder, a computed-name send or a
#    Method maker whose name is not proven, a Proc argument to define_method, a rebind name spelled, aliased or
#    defined, a factory `new` with `&blk`, a method_missing forwarding by name, natives that rebind or name a
#    rebinder), and the wio world: it fails only at enumerator.rb:322, Symbol#to_proc's send is proven, the rebound
#    blocks are mruby-enumerator's own `instance_eval { }` and `Fiber.new { }` blocks.
# 2. The consumers (in-process CodeGen): BLOCK_SELF answers the creating method for a block handed to a native
#    iterator when the fact holds, the per-site proof (which refuses it) when it does not, and never for a rebound
#    block; a CodeGen without the build's scan refuses the fact; ClosedWorld#proven_miss? refuses `self` in a rebound
#    block.
# 3. Generated code (one closed-world generation in the wio world, which may rebind): blocks at rebinder sites are
#    not compiled, and every compiled block carries the entry check.
# 4. Behaviour on real mruby (a full-core libmruby, Bc2cppFixtureRuntime.full_or_build): interpreted and compiled
#    runs agree for literal blocks at instance_eval/instance_exec/class_eval/define_method/Class.new/Struct.new sites
#    (before this ADR the compiled run read the creator's self), for each/map/Proc#call/yield/Fiber with a compiled
#    block, and for objects, nil and Integers as the creator's self; a compiled block a rebinder receives as `&blk`
#    raises the closed-world guard violation in the compiled run (the interpreted run rebinds it).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/block_self_world_check.rb

require 'set'
require 'tmpdir'
require 'fileutils'

unless ENV['MRBC']
  puts '  SKIP: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  exit 0
end

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
ROOT = File.expand_path('../..', __dir__)

# [ireps, registry, superclass_of] of +source+.
compiled = lambda do |source|
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'bsw.rb')
    File.write(path, source)
    ireps, root = compile_ireps(path, 'bsw_fixture', dir)
    registry, superclass_of, = build_registry(ireps, root)
    [ireps, registry, superclass_of]
  end
end
method_labels = lambda do |registry|
  registry.each_with_object({}) { |(name, defs), out| defs.each { |d| out[d.irep] = [d.owner, name] if d.irep } }
end
world_of = lambda do |source, natives: [], root: ROOT|
  ireps, registry, superclass_of = compiled.call(source)
  [BlockSelfWorld.analyze(ireps: ireps, native_paths: natives, method_labels: method_labels.call(registry),
                          superclass_of: superclass_of, root: root), ireps]
end
# Labels of the blocks whose first instruction line is +line+.
blocks_at = lambda do |ireps, line|
  ireps.values.select { |irep| irep.instructions.first&.lineno == line && ireps.values.any? { |p| Array(p.reps).include?(irep.label) } }.map(&:label)
end

puts '-- the world analysis'
world, = world_of.call(<<~RUBY)
  class BswA
    def each_tag(a); a.each { |x| @t = x }; end
    def pass(a, &b); a.each(&b); end
    def sym(a); a.map(&:to_s); end
    def fwd(o, *a, &b); o.__send__(:each, *a, &b); end
    def arr(n); Array.new(n) { |i| i }; end
  end
RUBY
check.call('a world with only ordinary block uses holds', world.holds? && world.rebound.empty?)

world, ireps = world_of.call(<<~RUBY)
  class BswB
    def peek(o)
      o.instance_eval do
        [1].each { |x| @seen = x }
      end
    end
    def install
      self.class.send(:define_method, :x) { 1 }
    end
  end
RUBY
check.call('a rebind name spelled as a Symbol fails the fact', !world.holds? && world.why.include?('spells the rebinder :define_method'))
world, ireps = world_of.call(<<~RUBY)
  class BswB
    def peek(o)
      o.instance_eval do
        [1].each { |x| @seen = x }
      end
    end
    def kls; Class.new { def z; end }; end
    def st; Struct.new(:a) { def b; a; end }; end
    def lam(o); o.instance_exec(1, &->(v) { v }); end
  end
RUBY
check.call('literal blocks at rebinder sites keep the fact', world.holds?)
outer = blocks_at.call(ireps, 3)
inner = blocks_at.call(ireps, 4)
check.call('the instance_eval block and the block nested in it are rebound',
           !outer.empty? && !inner.empty? && (outer + inner).all? { |l| world.rebound.include?(l) })
check.call('Class.new { }, Struct.new { } and a lambda literal handed to instance_exec are rebound',
           [7, 8, 9].all? { |line| blocks_at.call(ireps, line).any? { |l| world.rebound.include?(l) } })
check.call('the literal rebinder sites are listed', world.sites.map { |s| s[2] }.sort == %w[instance_eval instance_exec new new])

FAILING = {
  'a block that is not a literal to instance_exec' => ['def r(o, &b); o.instance_exec(&b); end', 'not a literal block to instance_exec'],
  'a stored Proc to instance_eval' => ['def r(o); o.instance_eval(&@pr); end', 'not a literal block to instance_eval'],
  'a Proc argument to define_method' => ['def r(c, pr); c.define_method(:z, pr); end', 'Proc argument to define_method'],
  'Class.new with &blk' => ['def r(&b); Class.new(&b); end', 'not a literal block to new'],
  'a factory call on a receiver that is not a known class' => ['def r(k, &b); k.new(&b); end', 'not a literal block to new'],
  'a computed name with a block' => ['def r(o, n, &b); o.public_send(n, &b); end', 'name it cannot prove'],
  'a method_missing that forwards by name' =>
    ['def method_missing(n, *a, &b); @t.__send__(n, *a, &b); end', 'name it cannot prove'],
  'a computed name with a Proc argument' => ['def r(o, n, pr); o.send(n, :z, pr); end', 'Proc argument'],
  'a Method object made by a computed name' => ['def r(o, n); o.method(n); end', 'Method object'],
  'a rebind name as a block Symbol' => ['def r(a); a.each(&:instance_eval); end', 'spells the rebinder'],
  'a rebind name as a String' => ['def r(o); o.send("instance_exec") { 1 }; end', 'spells the rebinder'],
  'an alias of a rebinder' => ['alias my_exec instance_exec', 'aliases the rebinder'],
  'a Ruby definition of a rebinder' => ['def instance_exec(*a); super; end', 'defines the rebinder'],
  'a to_proc send' => ['def r(a, s); a.each(&s.to_proc); end', 'name it cannot prove'],
  'a String eval' => ['def r(o, s); o.instance_eval(s); end', 'evaluates a String'],
  'Kernel#eval' => ['def r(s); eval(s); end', 'evaluates a String']
}.freeze
FAILING.each do |what, (body, why)|
  w, = world_of.call("class BswF\n  #{body}\nend\nclass Symbol\n  def to_proc; mid = self; ->(o, *a, &b) { o.__send__(mid, *a, &b) }; end\nend\n")
  check.call("#{what}: the fact fails (#{w.why})", !w.holds? && w.failures.any? { |f| f.include?(why) })
end
w, = world_of.call("class Symbol\n  def to_proc; mid = self; ->(o, *a, &b) { o.__send__(mid, *a, &b) }; end\nend\n" \
                   "class BswS\n  def r(a); a.map(&:to_s); end\nend\n")
check.call("Symbol#to_proc's computed send is proven by the Symbols passed as blocks", w.holds?)

Dir.mktmpdir do |dir|
  native = lambda do |rel, text|
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end
  NATIVES = {
    'mrb_yield_with_class' => "mrb_value f(mrb_state* M, mrb_value b, mrb_value o) { return mrb_yield_with_class(M, b, 0, NULL, o, NULL); }\n",
    'a rebinder by name' => "mrb_value f(mrb_state* M, mrb_value o, mrb_value b) { return mrb_funcall_with_block(M, o, MRB_SYM(instance_exec), 0, NULL, b); }\n",
    'a block to a computed name' => "mrb_value f(mrb_state* M, mrb_value o, mrb_sym m, mrb_value b) { return mrb_funcall_with_block(M, o, m, 0, NULL, b); }\n"
  }.freeze
  NATIVES.each do |what, text|
    path = native.call("gem/src/#{what.tr(' ', '_')}.c", text)
    w, = world_of.call("class BswN; end\n", natives: [path], root: dir)
    check.call("a native that runs #{what}: the fact fails", !w.holds? && w.why.include?('gem/src/'))
  end
  path = native.call('gem/src/ok.c', "mrb_value f(mrb_state* M, mrb_value o, mrb_value b) { return mrb_funcall_with_block(M, o, MRB_SYM(each), 0, NULL, b); }\n" \
                                    "/* \"instance_eval\" in a comment */\n")
  w, = world_of.call("class BswN; end\n", natives: [path], root: dir)
  check.call('a native passing a block to a literal name (and a comment) keeps the fact', w.holds?)
  path = native.call('3rd/mruby/src/vm.c', NATIVES['mrb_yield_with_class'])
  w, = world_of.call("class BswN; end\n", natives: [path], root: dir)
  check.call("the rebinders' own implementation (vm.c) keeps the fact", w.holds?)
end

puts '-- the wio world'
Dir.mktmpdir do |dir|
  srcs = closed_world_mrblib_srcs(ROOT)
  gems = NomethodReviewedProbe.wio_gems(ROOT)
  natives, outside_ruby = bc2cpp_closed_world_outside_srcs('wio', gems, ROOT)
  natives = (natives + Dir["#{ROOT}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)).uniq
  foreign = (outside_ruby + foreign_mrblib_srcs(ROOT)).map { |p| File.expand_path(p) }.uniq - srcs
  ireps, root = compile_ireps(srcs, 'bsw_wio', dir)
  outside, = compile_ireps(foreign.sort, 'bsw_wio_outside', dir)
  registry, superclass_of, = build_registry(ireps, root)
  w = BlockSelfWorld.analyze(ireps: ireps, outside_ireps: outside, native_paths: natives, method_labels: method_labels.call(registry),
                             superclass_of: superclass_of, root: ROOT)
  puts "    why: #{w.why}"
  w.failures.drop(1).each { |f| puts "    also: #{f}" }
  check.call('the wio world may rebind, through enumerator.rb:322 only',
             w.failures.size == 1 && w.why.start_with?('3rd/mruby/mrbgems/mruby-enumerator/mrblib/enumerator.rb:322:'))
  check.call("Symbol#to_proc's send (symbol.rb:5) is proven", w.failures.none? { |f| f.include?('symbol.rb') })
  site_lines = w.sites.map { |label, idx, name, _| "#{File.basename(ireps[label].file)}:#{ireps[label].instructions[idx].lineno} #{name}" }
  puts "    sites: #{site_lines.join(', ')}"
  check.call('the literal rebinder sites are the enumerator instance_eval blocks and Fiber.new',
             site_lines.sort == ['enumerator.rb:137 instance_eval', 'enumerator.rb:139 instance_eval', 'enumerator.rb:308 instance_eval',
                                 'enumerator.rb:315 instance_eval', 'enumerator.rb:406 new'])
  engine = w.rebound.select { |label| ireps[label].file.to_s.match?(%r{/mruby-(?:rpg2k|rgss|lcf)/}) }
  check.call('no engine block is rebound', engine.empty?)
end

puts '-- consumers'
SELF_SRC = <<~RUBY
  class BswC
    def tags(a); a.each { |x| @t = x }; end
    def peek(o); o.instance_eval { @t }; end
  end
RUBY
ireps, registry, superclass_of = compiled.call(SELF_SRC)
each_block = blocks_at.call(ireps, 2).first
peek_block = blocks_at.call(ireps, 3).first
gen = lambda do |world|
  CodeGen.block_self_world = world
  CodeGen.block_self_bodies = registry.transform_values { |defs| defs.select(&:irep) }
  CodeGen.block_self_unread_names = Set.new
  g = CodeGen.new(ireps, registry, {})
  cw = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: {}, walked: Set.new, native_paths: [], ruby_paths: [])
  cw.block_self_world = world
  g.instance_variable_set(:@closed_world, cw)
  [g, cw]
end
holding = BlockSelfWorld.analyze(ireps: ireps, method_labels: method_labels.call(registry), superclass_of: superclass_of)
failing = BlockSelfWorld.analyze(ireps: ireps, method_labels: method_labels.call(registry), superclass_of: superclass_of,
                                 refusal: 'a fixture refusal')
g, cw = gen.call(holding)
owner, why = g.block_self_owner(each_block)
check.call("the fact holds: a block handed to a native iterator keeps BswC#tags's self (#{why})", owner&.owner == 'BswC')
owner, why = g.block_self_owner(peek_block)
check.call("a rebound block has no owner (#{why})", owner.nil? && why.include?('rebinder'))
check.call('no entry check when the fact holds', !g.block_self_check?)
check.call('proven_miss? refuses `self` in a rebound block', !cw.proven_miss?('zz', 'BswC', Set.new, :lexical_self, label: peek_block))
g, cw = gen.call(failing)
owner, why = g.block_self_owner(each_block)
check.call("the fact fails: the per-site proof refuses the native iterator (#{why})", owner.nil? && why.to_s.include?('each'))
check.call('compiled blocks carry the entry check when the fact fails', g.block_self_check?)
CodeGen.block_self_world = nil
g = CodeGen.new(ireps, registry, {})
check.call('a CodeGen without the build scan refuses the fact, still knows the rebound blocks',
           g.block_self_check? && g.block_self_rebound?(peek_block))
CodeGen.block_self_bodies = nil
CodeGen.block_self_unread_names = nil

SRC = <<~'RUBY'
  class BswFx
    def initialize; @tag = :creator; end
    def tag; @tag; end
    def via_exec(o); o.instance_exec(3) { |k| [@tag, k] }; end
    def via_eval(o); o.instance_eval { [@tag, [1].map { |x| [@tag, x] }] }; end
    def via_class_eval(c); c.class_eval { self }; end
    def via_lambda(o); o.instance_exec(&->() { @tag }); end
    def via_class; Class.new { def bsw_k; :k; end }.new.bsw_k; end
    def via_struct; Struct.new(:a) { def bsw_b; [self.class.superclass, a]; end }.new(1).bsw_b; end
    def plain(a); r = []; a.each { |x| r << [@tag, x] }; r; end
    def mapped(a); a.map { |x| [@tag, x] }; end
    def make; proc { |x| [@tag, x] }; end
    def make_tag; proc { @tag }; end
    def make_lambda; ->(x) { [@tag, x] }; end
    def call_it(b); b.call(7); end
    def rebind(o, b); o.instance_exec(&b); end
  end
  class BswTarget
    def initialize; @tag = :target; end
  end
  module BswImm
    def bsw_pairs(a); a.map { |x| [self, x] }; end
  end
  class NilClass
    include BswImm
  end
RUBY

# A define_method send in a method body leaves the installed names unknown, which makes the fixture's core code
# reference RGSS natives a fixture binary does not link: the define_method site is checked in the generated code only,
# and the behavioural run installs a compiled block with define_method from the (interpreted) driver.
DEFINE_SRC = <<~'RUBY'
  class BswFx
    def via_define(c); c.define_method(:bsw_defined) { @tag }; c.new.bsw_defined; end
  end
RUBY

puts '-- generated code (wio world: may rebind)'
code, = Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(SRC + DEFINE_SRC, dir, core: true, only_owners: %w[BswFx BswTarget BswImm]) }
fn = ->(name) { code[/^mrb_value BswFx_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
%w[via_exec via_eval via_class_eval via_lambda via_define via_class via_struct].each do |name|
  check.call("#{name}: the block at the rebinder site is not compiled (the method stays interpreted)", fn.call(name).empty?)
end
check.call('plain: the each block is compiled', fn.call('plain').include?('bc2cpp_captured_self') || code.include?('BswFx_plain_block_fallback'))
check.call('every direct-entry block sets the entry-check flag', code.scan(/mrb_int_value\(M, ([0-3])\) \};/).flatten.uniq.all? { |f| f.to_i >= 2 })
check.call('every other compiled block body checks its self', !code.include?('(void)bc2cpp_passed_self;') &&
                                                              code.include?('bc2cpp_block_self_check(M, bc2cpp_passed_self'))

DRIVER = <<~'RUBY'
  fx = BswFx.new
  t = BswTarget.new
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}"
    end
    puts "#{name}: #{out}"
  end
  show.call('via_exec') { fx.via_exec(t) }
  show.call('via_eval') { fx.via_eval(t) }
  show.call('via_class_eval') { fx.via_class_eval(BswTarget) }
  show.call('via_lambda') { fx.via_lambda(t) }
  show.call('via_class') { fx.via_class }
  show.call('via_struct') { fx.via_struct }
  show.call('plain') { fx.plain([1, 2]) }
  show.call('mapped array') { fx.mapped([1]) }
  show.call('mapped range') { fx.mapped(1..2) }
  show.call('mapped hash') { fx.mapped({ k: 1 }) }
  show.call('proc call') { fx.call_it(fx.make) }
  show.call('proc yield') { [3].each(&fx.make) }
  show.call('proc ===') { fx.make === 4 }
  show.call('proc []') { fx.make[5] }
  show.call('lambda of it') { lambda(&fx.make).call(6) }
  show.call('lambda yielded') { [1, 2].map(&fx.make_lambda) + { k: 1 }.map(&lambda(&fx.make)) }
  show.call('lambda called') { fx.make_lambda.call(3) }
  show.call('interpreted yield') { def bsw_yielder; yield 8; end; bsw_yielder(&fx.make) }
  show.call('fiber') { Fiber.new { fx.plain([9]) + fx.mapped(1..1) }.resume }
  show.call('nil self') { nil.bsw_pairs([1]) }
  show.call('rebind a compiled block') { fx.rebind(t, fx.make_tag) }
  show.call('define_method with a compiled block') do
    k = Class.new { def initialize; @tag = :other; end }
    k.define_method(:bsw_via_block, &fx.make_tag)
    k.new.bsw_via_block
  end
  show.call('define_method on Object, called on nil') do
    Object.define_method(:bsw_nil_body, &fx.make_tag)
    nil.bsw_nil_body
  end
  show.call('rebind after') { [fx.plain([0]), [4].map(&fx.make_lambda)] }
  GC.start
  puts 'end'
RUBY

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    Dir.mktmpdir do |dir|
      _code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: %w[BswFx BswTarget BswImm])
      body = <<~CPP
        static int scenario(mrb_state* M) {
          std::fflush(stdout);
          const char* src = R"BSW(#{DRIVER})BSW";
          mrb_load_string(M, src);
          std::fflush(stdout);
          if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
          return 0;
        }
      CPP
      built, output = Bc2cppFixtureRuntime.run(dir, err, %w[BswFx BswTarget BswImm], body, build: build, full: true)
      check.call('the fixtures build and run', built)
      sections = Bc2cppFixtureRuntime.sections(output)
      interpreted = sections['interpreted']
      # The violation also logs a `[RPG2k] closed-world guard violation: ...` line to $stderr, which the run shares.
      logged = sections['compiled']&.select { |line| line.start_with?('[RPG2k] closed-world guard violation: compiled block of make_tag') }
      compiled_run = sections['compiled']&.reject { |line| line.start_with?('[RPG2k] ') }
      check.call('the driver runs to the end in both runs', interpreted&.last == 'end' && compiled_run&.last == 'end')
      if interpreted && compiled_run
        violations = ['rebind a compiled block', 'define_method with a compiled block', 'define_method on Object, called on nil']
        same = ->(line) { violations.none? { |v| line.start_with?("#{v}:") } }
        check.call('interpreted and compiled runs agree on everything but the three rebound compiled blocks',
                   interpreted.select(&same) == compiled_run.select(&same))
        interpreted.zip(compiled_run).reject { |a, b| a == b }.each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
        check.call('instance_exec runs its literal block under the target', interpreted.include?('via_exec: [:target, 3]'))
        check.call('the interpreted run rebinds a block handed over as &blk', interpreted.include?('rebind a compiled block: :target'))
        check.call('the compiled run raises the closed-world guard violation for it',
                   compiled_run.include?('rebind a compiled block: BC2cppGuardViolation') &&
                   compiled_run.include?('define_method with a compiled block: BC2cppGuardViolation') &&
                   compiled_run.include?('define_method on Object, called on nil: BC2cppGuardViolation'))
        check.call('the violation names the block and the self it was run under', logged.size == 3 && logged.first.include?('BswTarget'))
      end
      puts output.lines.last(30).join unless built && interpreted && compiled_run
    end
  end
end

if failures.empty?
  puts 'bc2cpp block self world check: PASS'
else
  warn "bc2cpp block self world check: #{failures.size} failure(s)"
  exit 1
end
