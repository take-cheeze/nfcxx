#!/usr/bin/env ruby
# frozen_string_literal: true

# Check RBS_SIGNATURES (docs/adr/0413, tools/bc2cpp/rbs_signatures.rb): `.rbs` files as a source of the hints the
# `# bc2cpp:` comments give.
#
# 1. The loader on RBS text (no MRBC): the supported subset is read into the right hint kinds; what is accepted without
#    giving a hint is a TC1005 note; a parse error and an overloaded def are TC1002 errors at their own file:line:col;
#    nothing is dropped silently.
# 2. On fixtures (needs MRBC):
#    * a signature that contradicts the inference is TC1001 at the signature's own file:line (argument, class
#      argument, return class, ivar), exit status 1;
#    * a signature names a method the program lacks (TC1003) or a wrong parameter count (TC1004): warnings;
#    * a correct signature has exactly the effect of the equivalent `# bc2cpp:` comment: the generated C++ is identical
#      (the comment is the only difference between the two fixtures), the parameter is typed `signature`, the ranked
#      suggestion for it disappears and its send gets a direct arm; the guarded else arm keeps the by-name line;
#    * the comment wins over a signature naming the same slot (TC1006);
#    * an unusable signature file fails a build, and an empty or absent directory changes nothing (byte-identical).
#
# BC2CPP_TOOLS_DIR points at a mutant copy of tools/bc2cpp (rbs_signatures_mutation_check.rb).
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/rbs_signatures_check.rb [--unit-only]

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

ROOT = File.expand_path('../..', __dir__)
TOOLS = ENV['BC2CPP_TOOLS_DIR'] || File.join(ROOT, 'tools/bc2cpp')
$LOAD_PATH.unshift(TOOLS)
require 'rbs_signatures'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# ------------------------------------------------------------------------------------------------ 1. loader
puts '== loader: the supported subset'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'a.rbs'), <<~RBS)
    module Game
      class Actor
        @hp: Integer
        @items: Array[Game::Item]
        @slots: Hash[Symbol, Game::Item]
        @owner: Game::Party
        attr_reader name: Symbol
        def take: (Integer n, Symbol s, Game::Item i, Array[Game::Item] a) -> Game::Item
        def maybe: (Game::Item? i, ?Integer opt, *untyped rest) { (Integer) -> void } -> void
        def self.make: () -> Game::Actor
        private
        alias foo take
      end
      class Item
      end
    end
    A_CONSTANT: Integer
  RBS
  loaded = RbsSignatures.load([dir])
  check.call('no error diagnostics for the supported subset', loaded.diagnostics.none? { |d| d.severity == 'error' })
  take = loaded.methods[['Game::Actor', 'take']]
  check.call('nested class names are joined with ::', take && take.owner == 'Game::Actor')
  check.call('parameter kinds: Integer, Symbol, class, Array[C]', take && take.args.map(&:kind) == %i[int sym class array])
  check.call('the element class of Array[C] is read', take && take.args[3].element == 'Game::Item')
  check.call('the return class is read', take && take.ret.kind == :class && take.ret.cls == 'Game::Item')
  check.call('the def line and column are the signature location', take && take.loc.line == 8 && take.loc.col == 5 && take.loc.file.end_with?('a.rbs'))
  iv = loaded.ivars
  check.call('ivars: Integer, Array[C], Hash[K, C], class', iv[['Game::Actor', '@hp']].type.kind == :int &&
             iv[['Game::Actor', '@items']].type.element == 'Game::Item' && iv[['Game::Actor', '@slots']].type.kind == :hash &&
             iv[['Game::Actor', '@slots']].type.element == 'Game::Item' && iv[['Game::Actor', '@owner']].type.cls == 'Game::Party')
  check.call('attr_reader declares its ivar', iv[['Game::Actor', '@name']]&.type&.kind == :sym)
  notes = loaded.diagnostics.select { |d| d.code == 'TC1005' }.map(&:message)
  check.call('optional / rest / block parameters are noted, not dropped silently', notes.any? { |m| m.include?('maybe') && m.include?('optional') && m.include?('block type') })
  check.call('a singleton def is noted', notes.any? { |m| m.include?('singleton method make') })
  check.call('a constant is noted', notes.any? { |m| m.include?('A_CONSTANT') })
  check.call('alias / visibility are noted', notes.count { |m| m.start_with?('Alias') || m.start_with?('Private') } == 2)
  check.call('Integer? gives a type of kind other', loaded.methods[['Game::Actor', 'maybe']].args[0].kind == :other)
end

puts '== loader: errors are located'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'over.rbs'), "class X\n  def a: (Integer) -> Integer\n  def b: (Integer x) -> Integer | (String x) -> String\nend\n")
  File.write(File.join(dir, 'bad.rbs'), "class Y\n  def c: (\nend\n")
  File.write(File.join(dir, 'ok.rbs'), "class Z\nend\n")
  loaded = RbsSignatures.load([dir], display_root: dir)
  errs = loaded.diagnostics.select { |d| d.severity == 'error' }.map { |d| [d.file, d.line, d.col, d.code] }
  check.call('an overloaded def is TC1002 at its own line', errs.include?(['over.rbs', 3, 3, 'TC1002']))
  check.call('a parse error is TC1002 at the error position', errs.any? { |f, l, _c, code| f == 'bad.rbs' && l == 3 && code == 'TC1002' })
  check.call('the overload message says why', loaded.diagnostics.any? { |d| d.message.include?('2 overloads') })
  check.call('the valid declaration of the same file is still read', loaded.methods.key?(['X', 'a']))
  check.call('no .rbs: nothing loaded (the byte-identical path)', RbsSignatures.load([File.join(dir, 'empty-nothing')]).nil?)
  ENV['BC2CPP_SIG_DIRS'] = ''
  check.call('BC2CPP_SIG_DIRS="" switches the feature off', RbsSignatures.dirs_from_env(ROOT).empty?)
  ENV.delete('BC2CPP_SIG_DIRS')
end

puts '== richer RBS contracts in bytecode IR'
require 'irep'
require 'bytecode_ir'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'types.rbs'), <<~RBS)
    class IrContracts
      def choose: (Integer? n, bool b, String | Symbol s) -> String?
      def opaque: (Integer | untyped x) -> void
      def literals: (true t, false f, 42 n, :tag s, "text" text) -> nil
      def containers: (Array[String] a, Hash[Symbol, Integer] h) -> Array[String]
      def unknown: (self x) -> untyped
      def generic: (Enumerator[String] x) -> untyped
    end
  RBS
  loaded = RbsSignatures.load([dir])
  choose = loaded.methods[['IrContracts', 'choose']]
  check.call('nullable, bool and union classes are retained', choose.args.map(&:value_classes) == [
    Set[:Integer, :NilClass], Set[:TrueClass, :FalseClass], Set[:String, :Symbol]
  ])
  check.call('nullable return classes are retained', choose.ret.value_classes == Set[:String, :NilClass])
  check.call('a union with untyped stays unknown', loaded.methods[['IrContracts', 'opaque']].args.first.value_classes.nil?)
  check.call('literal classes are retained without inventing finite-value proofs',
             loaded.methods[['IrContracts', 'literals']].args.map(&:value_classes) == [
               Set[:TrueClass], Set[:FalseClass], Set[:Integer], Set[:Symbol], Set[:String]
             ])
  check.call('container generics give only their outer classes',
             loaded.methods[['IrContracts', 'containers']].args.map(&:value_classes) == [Set[:Array], Set[:Hash]])
  check.call('self and unsupported generic types stay unknown',
             %w[unknown generic].all? { |name| loaded.methods[['IrContracts', name]].args.first.value_classes.nil? })
  make_insn = ->(addr, op, args) { Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}") }
  body = Irep.new(label: 'choose', nlocals: 6, instructions: [
    make_insn.call(0, 'ENTER', '3:0:0:0:0:0:0:0 (0x0)'),
    make_insn.call(4, 'JMPIF', "R2\t16"), make_insn.call(8, 'MOVE', "R4\tR1"),
    make_insn.call(12, 'JMP', '20'), make_insn.call(16, 'LOADSYM', "R4\t:tag"),
    make_insn.call(20, 'RETURN', 'R4')
  ])
  definition = MethodDef.new(owner: 'IrContracts', name: 'choose', irep: body.label)
  # Applying only the fixture's matched declaration avoids unrelated missing-method diagnostics.
  matched = RbsSignatures::Loaded.new(methods: { ['IrContracts', 'choose'] => choose }, ivars: {}, diagnostics: [], files: [])
  apply = ->(ann = {}) { RbsSignatures.apply(matched, { body.label => body }, { 'choose' => [definition] }, ann, {}, {}) }
  applied = apply.call
  analysis = RbsSignatures.ir_types(applied, body)
  fact = analysis.fact_at(5, '4')
  check.call('IR unions declared argument and inferred literal through MOVE',
             fact && fact.classes == Set[:Integer, :NilClass, :Symbol] && fact.declared? && fact.frozen? && fact.classes.frozen?)
  check.call('proof-only query stays unknown with a signature', analysis.at(5, '4').nil?)
  check.call('ENTER R1 gets its parameter contract', analysis.fact_at(1, '1')&.classes == Set[:Integer, :NilClass])
  check.call('other required slots get their entry contracts', analysis.fact_at(1, '2')&.classes == Set[:TrueClass, :FalseClass])
  literal = analysis.fact_at(5, '4', max_states: 1)
  check.call('contracts preserve the dataflow budget', literal.nil?)
  inferred = analysis.fact_at(5, '5')
  check.call('an inferred definition is still marked inferred', inferred && inferred.classes == Set[:NilClass] && !inferred.declared?)
  commented = apply.call({ body.label => Annotations::Annotation.new(args: [:symbol], ret: nil) })
  check.call('a comment owns its parameter contract', !commented.ir_arg_types[body.label].key?('1') &&
             RbsSignatures.ir_types(commented, body).fact_at(1, '1').nil?)
  wrong = Irep.new(label: body.label, instructions: [
    make_insn.call(0, 'ENTER', '2:0:0:0:0:0:0:0 (0x0)'), make_insn.call(4, 'RETURN', 'R1')
  ])
  rejected = RbsSignatures.apply(matched, { body.label => wrong }, { 'choose' => [definition] }, {}, {}, {})
  check.call('arity mismatch seeds no IR contracts', rejected.ir_arg_types.empty? && rejected.diagnostics.any? { |d| d.code == 'TC1004' })
  overwritten = Irep.new(label: body.label, nlocals: 3, instructions: [
    make_insn.call(0, 'ENTER', '3:0:0:0:0:0:0:0 (0x0)'),
    make_insn.call(4, 'GETIV', "R1\t:value"), make_insn.call(8, 'RETURN', 'R1')
  ])
  check.call('a parameter contract does not type a later unknown write', RbsSignatures.ir_types(applied, overwritten).fact_at(2, '1').nil?)
  invalid = begin
    BytecodeIR::Types.new(body, declared_args: { '0' => Set[:IrContracts] })
    false
  rescue ArgumentError
    true
  end
  check.call('self cannot be seeded as an argument contract', invalid)
  alias_definition = MethodDef.new(owner: 'OtherOwner', name: 'choose', irep: body.label)
  shared = RbsSignatures.apply(matched, { body.label => body }, { 'choose' => [definition, alias_definition] }, {}, {}, {})
  check.call('shared IREPs with ambiguous owners do not acquire one owner contract',
             RbsSignatures.ir_types(shared, body).fact_at(1, '1').nil?)
end

puts '== explicit receiver contracts and call-result chains'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'calls.rbs'), <<~RBS)
    class CallRoot
      def child: () -> CallLeaf
      def next: () -> CallRoot
    end
    class CallLeaf
      def finish: () -> Symbol
    end
    class CallOther
      def child: () -> CallOtherLeaf
    end
    class CallOtherLeaf
      def finish: () -> Integer
    end
    class CallUse
      def chain: (CallRoot value) -> untyped
      def union: (CallRoot | CallOther value) -> untyped
      def missing: (CallRoot | String value) -> untyped
      def cyclic: (CallRoot value) -> untyped
      def deep: (CallRoot value) -> untyped
    end
  RBS
  loaded = RbsSignatures.load([dir])
  make_insn = ->(addr, op, args) { Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}") }
  definitions = []
  ireps = {}
  loaded.methods.each_value do |sig|
    label = "#{sig.owner}_#{sig.name}"
    instructions = [make_insn.call(0, 'ENTER', "#{sig.args.size}:0:0:0:0:0:0:0 (0x0)")]
    if sig.owner == 'CallUse'
      instructions += [make_insn.call(4, 'MOVE', "R2\tR1"), make_insn.call(8, 'SEND0', "R2\t:child"),
                       make_insn.call(12, 'SEND0', "R2\t:finish"), make_insn.call(16, 'RETURN', 'R2')]
    else
      instructions += [make_insn.call(4, 'LOADNIL', 'R1 (nil)'), make_insn.call(8, 'RETURN', 'R1')]
    end
    ireps[label] = Irep.new(label: label, nlocals: 3, instructions: instructions)
    definitions << MethodDef.new(owner: sig.owner, name: sig.name, irep: label)
  end
  cyclic = ireps['CallUse_cyclic']
  cyclic.instructions = [make_insn.call(0, 'ENTER', '1:0:0:0:0:0:0:0 (0x0)'), make_insn.call(4, 'MOVE', "R2\tR1"),
                         make_insn.call(8, 'JMPIF', "R3\t20"), make_insn.call(12, 'SEND0', "R2\t:next"),
                         make_insn.call(16, 'JMP', '8'), make_insn.call(20, 'RETURN', 'R2')]
  deep = ireps['CallUse_deep']
  deep.instructions = [make_insn.call(0, 'ENTER', '1:0:0:0:0:0:0:0 (0x0)'), make_insn.call(4, 'MOVE', "R2\tR1")]
  30.times { |index| deep.instructions << make_insn.call(8 + index * 4, 'SEND0', "R2\t:next") }
  deep.instructions << make_insn.call(128, 'RETURN', 'R2')
  registry = definitions.group_by(&:name)
  applied = RbsSignatures.apply(loaded, ireps, registry, {}, {}, {})
  chain = RbsSignatures.ir_types(applied, ireps['CallUse_chain'])
  fact = chain.fact_at(4, '2')
  check.call('explicit receiver call chains retain every contract dependency', fact&.classes == Set[:Symbol] && fact.declared? &&
             fact.contracts == ['argument:R1', 'call-result:CallLeaf#finish', 'call-result:CallRoot#child'])
  check.call('contract call results do not enter the inference-only query', chain.at(4, '2').nil?)
  blocked = Irep.new(label: 'CallUse_chain', nlocals: 3, instructions: [
    make_insn.call(0, 'ENTER', '1:0:0:0:0:0:0:0 (0x0)'), make_insn.call(4, 'MOVE', "R2\tR1"),
    make_insn.call(8, 'SENDB', "R2\t:child\tn=0"), make_insn.call(12, 'RETURN', 'R2')
  ])
  check.call('a block call cannot borrow the normal RBS return contract',
             RbsSignatures.ir_types(applied, blocked).fact_at(3, '2').nil?)
  union = RbsSignatures.ir_types(applied, ireps['CallUse_union']).fact_at(4, '2')
  check.call('every receiver union member contributes its return type', union&.classes == Set[:Symbol, :Integer])
  missing_reason = {}
  missing = RbsSignatures.ir_types(applied, ireps['CallUse_missing']).fact_at(4, '2', refusal: missing_reason)
  check.call('one missing receiver contract poisons the complete result', missing.nil? && missing_reason[:cause] == 'call_contract_missing:String#child')
  cycle_reason = {}
  check.call('a loop-carried receiver cycle refuses without guessing a fixed point',
             RbsSignatures.ir_types(applied, cyclic).fact_at(5, '2', refusal: cycle_reason).nil? && cycle_reason[:cause] == :call_cycle)
  depth_reason = {}
  deep_analysis = RbsSignatures.ir_types(applied, deep)
  check.call('long call chains respect a bounded query depth',
             deep_analysis.fact_at(deep.instructions.size - 1, '2', refusal: depth_reason).nil? &&
             depth_reason[:cause] == :call_depth_cap)
  check.call('a depth refusal does not poison a shorter root query', deep_analysis.fact_at(10, '2')&.classes == Set[:CallRoot])
  check.call('the call-results switch restores explicit-receiver unknowns',
             RbsSignatures.ir_types(applied, ireps['CallUse_chain'], call_results: false).fact_at(4, '2').nil?)
end

# ------------------------------------------------------------------------------------------------ 2. fixtures
if ARGV.include?('--unit-only') || !ENV['MRBC']
  puts(ARGV.include?('--unit-only') ? '-- fixture half skipped (--unit-only)' : '-- SKIP fixture half: set MRBC')
else
  require File.join(ROOT, 'scripts/bc2cpp/fixture_runtime')
  SCRIPT = File.join(ROOT, 'scripts/bc2cpp/type_check.rb')
  type_check = lambda do |dir, *args|
    Open3.capture3({ 'BC2CPP_TOOLS_DIR' => TOOLS, 'MRBC' => ENV.fetch('MRBC') }, RbConfig.ruby, SCRIPT, *args, chdir: dir)
  end
  gen = lambda do |src, sig_dir|
    old = ENV['BC2CPP_SIG_DIRS']
    ENV['BC2CPP_SIG_DIRS'] = sig_dir
    ENV['BC2CPP_TOOL'] = nil
    Dir.mktmpdir { |d| Bc2cppFixtureRuntime.generate(src, d).first }
  ensure
    old ? ENV['BC2CPP_SIG_DIRS'] = old : ENV.delete('BC2CPP_SIG_DIRS')
  end

  CONTRA = <<~RUBY
    class TcSym
      def take(n)
        n
      end

      def pick(o)
        o
      end

      def make
        TcSym.new
      end

      def go
        take(3)
        pick(TcSym.new)
        make
        @tag = TcSym.new
      end
    end

    class TcOther
      def hi
        1
      end
    end
  RUBY
  CONTRA_SIG = <<~RBS
    class TcSym
      @tag: TcOther
      def take: (Symbol n) -> untyped
      def pick: (TcOther o) -> untyped
      def make: () -> TcOther
      def ghost: (Integer a) -> void
      def go: (Integer extra) -> void
    end
  RBS
  USE = <<~RUBY
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
      end

      def put(k, v)
        @h[k] = v
      end

      def run(k)
        use(@h[k])
      end

      # COMMENT
      def use(o)
        o.size
      end
    end

    class TcMain
      def go
        u = TcUse.new
        u.put(1, TcA.new)
        u.put(2, TcB.new)
        u.run(1)
      end
    end
  RUBY
  USE_SIG = "class TcUse\n  def use: (TcA o) -> untyped\nend\n"

  Dir.mktmpdir do |dir|
    FileUtils.mkdir_p(File.join(dir, 'sig'))
    File.write(File.join(dir, 'contra.rb'), CONTRA)
    File.write(File.join(dir, 'sig/contra.rbs'), CONTRA_SIG)
    puts '== contradictions are located in the signature file'
    out, err, st = type_check.call(dir, '--files', 'contra.rb', '--sig', 'sig', '--no-sends', '-q')
    lines = out.lines.map(&:chomp)
    check.call("exit status 1 (#{st.exitstatus}) #{err.lines.first&.strip}", st.exitstatus == 1)
    check.call('fixnum/symbol argument', lines.include?('sig/contra.rbs:3:3: error: TcSym#take parameter 1: declared Symbol, inferred Integer (signature) [TC1001]'))
    check.call('class argument', lines.include?('sig/contra.rbs:4:3: error: TcSym#pick parameter 1: declared TcOther, inferred TcSym (signature) [TC1001]'))
    check.call('class return', lines.include?('sig/contra.rbs:5:3: error: TcSym#make return type: declared TcOther, inferred TcSym (signature) [TC1001]'))
    check.call('ivar class', lines.include?('sig/contra.rbs:2:3: error: TcSym@tag ivar: declared TcOther, inferred TcSym (signature) [TC1001]'))
    check.call('a method the program lacks is a TC1003 error', lines.include?('sig/contra.rbs:6:3: error: TcSym#ghost: no such method in the program [TC1003]'))
    check.call('a wrong parameter count is a TC1004 error',
               lines.include?('sig/contra.rbs:7:3: error: TcSym#go: signature lists 1 required parameter(s), method takes 0; not used [TC1004]'))

    puts '== a signature has the effect of the comment'
    File.write(File.join(dir, 'sig/use.rbs'), USE_SIG)
    plain = USE.sub("      # COMMENT\n", '')
    commented = USE.sub('# COMMENT', '# bc2cpp: (TcA)')
    c_plain = gen.call(plain, '')
    c_sig = gen.call(plain, File.join(dir, 'sig/use.rbs'))
    c_comment = gen.call(commented, '')
    check.call('the signature changes the generated code (a direct arm for the class)', c_sig != c_plain && c_sig.include?('TYPED :size -> TcA#size') && !c_plain.include?('TYPED :size -> TcA#size'))
    check.call('identical C++ to the equivalent `# bc2cpp:` comment', c_sig == c_comment)
    sends = ->(code) { code.scan('bc2cpp_send(M').size }
    check.call("the guarded else arm keeps the by-name line (#{sends.(c_plain)} -> #{sends.(c_sig)})", sends.(c_sig) == sends.(c_plain))
    check.call('an empty BC2CPP_SIG_DIRS is byte-identical to no signatures', gen.call(plain, '') == c_plain)
    File.write(File.join(dir, 'use.rb'), plain)
    before = JSON.parse(type_check.call(dir, '--files', 'use.rb', '--format', 'json', '--sig', File.join(dir, 'nosuch')).first)
    after = JSON.parse(type_check.call(dir, '--files', 'use.rb', '--format', 'json', '--sig', File.join(dir, 'sig/use.rbs')).first)
    check.call('before: the parameter is ranked', before['suggestions'].any? { |s| s['target'].start_with?('TcUse#use parameter 1') })
    up = after['methods'].find { |m| m['name'] == 'use' }
    check.call('after: typed from the signature and no longer ranked', up['params'][0]['type'] == 'TcA' && up['params'][0]['source'] == 'signature' &&
               after['suggestions'].none? { |s| s['target'].start_with?('TcUse#use parameter 1') })

    puts '== rich argument declarations appear in type facts'
    rich_source = <<~RUBY
      class IrContracts
        def choose(n, b, s)
          n
        end
      end
    RUBY
    File.write(File.join(dir, 'rich.rb'), rich_source)
    File.write(File.join(dir, 'sig/rich.rbs'), "class IrContracts\n  def choose: (Integer? n, bool b, String | Symbol s) -> untyped\nend\n")
    rich_out, rich_err, rich_status = type_check.call(dir, '--files', 'rich.rb', '--format', 'json', '--sig', 'sig/rich.rbs')
    check.call("rich contract type check succeeds #{rich_err.lines.first&.strip}", rich_status.success?)
    rich_params = JSON.parse(rich_out)['methods'].find { |method| method['name'] == 'choose' }['params']
    check.call('nullable, bool and union arguments are reported as signature declarations',
               rich_params.map { |param| [param['type'], param['source']] } == [
                 ['Integer | nil', 'signature'], ['bool', 'signature'], ['String | Symbol', 'signature']
               ])
    check.call('rich contracts do not change generated dispatch', gen.call(rich_source, '') == gen.call(rich_source, File.join(dir, 'sig/rich.rbs')))

    puts '== ivar and return contracts, feedback and RBS suggestions'
    feedback_source = <<~RUBY
      class Feedback
        def read
          @item
        end
        def produce(flag)
          flag ? 'text' : :tag
        end
        def invoke
          produce(true)
        end
        def dynamic(other)
          other.produce(true)
        end
        def bad_store
          @item = :bad
        end
        def bad_return
          :bad
        end
        def numeric
          3
        end
        def enumerable
          []
        end
        def external
          1
        end
        def maybe_wrong(flag)
          flag ? 1 : :bad
        end
      end
      class FeedbackChild < Feedback
        def inherited
          @item
        end
      end
      class FeedbackOther
        def produce(flag)
          flag.unknown_value
        end
      end
    RUBY
    feedback_sig = <<~RBS
      class Feedback
        @item: Integer?
        @unassigned: bool?
        def read: () -> Integer?
        def produce: (untyped flag) -> (String | Symbol)
        def invoke: () -> (String | Symbol)
        def bad_return: () -> Integer?
        def numeric: () -> Numeric
        def enumerable: () -> Enumerable
        def external: () -> ExternalContract
        def maybe_wrong: (untyped flag) -> Integer?
      end
    RBS
    File.write(File.join(dir, 'feedback.rb'), feedback_source)
    File.write(File.join(dir, 'sig/feedback.rbs'), feedback_sig)
    source_types_before = ENV['BC2CPP_IR_SOURCE_TYPES']
    ENV['BC2CPP_IR_SOURCE_TYPES'] = '0'
    feedback_out, feedback_err, feedback_status = type_check.call(dir, '--files', 'feedback.rb', '--format', 'json',
                                                                 '--no-sends', '--sig', 'sig/feedback.rbs', '--emit-rbs-suggestions', 'suggested', '--keep', 'feedback-kept')
    source_types_before ? ENV['BC2CPP_IR_SOURCE_TYPES'] = source_types_before : ENV.delete('BC2CPP_IR_SOURCE_TYPES')
    check.call("feedback returns exit 1 for definite contract mismatches #{feedback_err.lines.first&.strip}", feedback_status.exitstatus == 1)
    report = JSON.parse(feedback_out)
    feedback_rows = report['ir_feedback']
    find_return = ->(name) { feedback_rows.find { |row| row['method'] == name && row['kind'] == 'return' } }
    check.call('nullable ivar reads carry their contract provenance', find_return.call('read')['type'] == 'Integer | nil' &&
               find_return.call('read')['status'] == 'declared' && find_return.call('read')['contracts'] == ['ivar:@item'])
    check.call('inherited ivar contracts reach subclass reads', find_return.call('inherited')['type'] == 'Integer | nil' &&
               find_return.call('inherited')['status'] == 'declared')
    check.call('implicit self-call returns use the matched method contract', find_return.call('invoke')['type'] == 'String | Symbol' &&
               find_return.call('invoke')['contracts'] == ['self-call:produce'])
    check.call('an unknown receiver cannot inherit one same-name RBS return contract', find_return.call('dynamic')['status'] == 'unknown' &&
               find_return.call('dynamic')['reason'] == 'unknown:ENTER')
    check.call('ivar stores use the value operand, not the leading name', feedback_rows.any? { |row|
      row['kind'] == 'ivar_store' && row['detail'] == '@item' && row['status'] == 'mismatch' && row['type'] == 'Symbol'
    })
    check.call('rich ivar and return mismatches give TC1007 diagnostics', report['diagnostics'].count { |diag| diag['code'] == 'TC1007' } == 2)
    check.call('Integer fits a Numeric return contract', find_return.call('numeric')['status'] == 'inferred')
    check.call('Array satisfies its Enumerable mixin contract', find_return.call('enumerable')['status'] == 'inferred' &&
               find_return.call('enumerable')['compatibility'] == 'checked')
    check.call('an unresolved external nominal type does not create a false mismatch',
               find_return.call('external')['status'] == 'inferred' && find_return.call('external')['compatibility'] == 'unknown')
    check.call('a partially overlapping may-set produces a warning, not a definite mismatch',
               find_return.call('maybe_wrong')['status'] == 'possible_mismatch' &&
               report['diagnostics'].count { |diag| diag['code'] == 'TC1008' && diag['severity'] == 'warning' } == 1)
    check.call('a declaration-only nullable ivar is reported', report['ivars'].any? { |ivar|
      ivar['name'] == '@unassigned' && ivar['type'] == 'bool | nil' && ivar['source'] == 'signature'
    })
    check.call('IR-inferred union returns are available as RBS suggestions', report['rbs_suggestions'].any? { |suggestion|
      suggestion['method'] == 'produce' && suggestion['type'] == 'String | Symbol' && suggestion['source'] == 'inferred:bytecode-ir'
    })
    check.call('contract-dependent reads are not independent inferred suggestions', report['rbs_suggestions'].none? { |suggestion|
      %w[read inherited invoke dynamic].include?(suggestion['method'])
    })
    suggested = File.read(File.join(dir, 'suggested/Feedback.rbs'))
    check.call('suggestion export replaces a contradicted return with its inferred type',
               suggested.include?('def bad_return: () ?{ (*untyped) -> untyped } -> Symbol'))
    check.call('suggestion files parse as ordinary RBS', !RBS::Parser.parse_signature(suggested).nil?)
    text_out, _text_err, text_status = type_check.call(dir, '--facts', 'feedback-kept/facts.json', '--all', '--no-sends')
    check.call('text feedback explains unknowns and lists inferred RBS suggestions', text_status.exitstatus == 1 &&
               text_out.include?('[TC2004]') && text_out.include?('unknown:ENTER') && text_out.include?('Feedback#produce -> String | Symbol'))

    puts '== report propagation of explicit receiver contracts'
    File.write(File.join(dir, 'call-chain.rb'), <<~RUBY)
      class SigRoot
        def child
          @child
        end
        def store_child(value)
          @child = value
        end
      end
      class SigLeaf
        def finish
          @result
        end
        def store_result(value)
          @result = value
        end
      end
      class SigUse
        def chain(root)
          root.child.finish
        end
      end
    RUBY
    File.write(File.join(dir, 'sig/call-chain.rbs'), <<~RBS)
      class SigRoot
        def child: () -> SigLeaf
      end
      class SigLeaf
        def finish: () -> Symbol
      end
      class SigUse
        def chain: (SigRoot root) -> untyped
      end
    RBS
    chain_out, chain_err, chain_status = type_check.call(dir, '--files', 'call-chain.rb', '--sig', 'sig/call-chain.rbs', '--format', 'json', '--no-sends')
    check.call("explicit receiver fixture checks successfully #{chain_err.lines.first&.strip}", chain_status.success?)
    chain_report = JSON.parse(chain_out)
    chain_return = chain_report['methods'].find { |method| method['name'] == 'chain' }['return']
    check.call('complete contract-assisted returns are reported with derived provenance', chain_return['type'] == 'Symbol' &&
               chain_return['source'] == 'derived:contracts' && chain_return['contracts'].include?('call-result:SigLeaf#finish'))
    check.call('derived returns are excluded from independent RBS suggestions',
               chain_report['rbs_suggestions'].none? { |suggestion| suggestion['method'] == 'chain' })

    puts '== audited builtin call result and override withdrawal'
    builtin_source = "class IrBuiltinCall\n  def run\n    [].size\n  end\nend\n"
    File.write(File.join(dir, 'builtin-call.rb'), builtin_source)
    builtin_out, _builtin_err, builtin_status = type_check.call(dir, '--files', 'builtin-call.rb', '--sig', 'no-signatures', '--format', 'json', '--no-sends')
    builtin_report = JSON.parse(builtin_out)
    builtin_result = builtin_report['ir_feedback'].find { |row| row['method'] == 'run' && row['kind'] == 'return' }
    check.call('a pinned Array size result is independently inferred by IR', builtin_status.success? &&
               builtin_result['status'] == 'inferred' && builtin_result['type'] == 'Integer')
    File.write(File.join(dir, 'builtin-call.rb'), builtin_source + "class Array\n  def size\n    :changed\n  end\nend\n")
    override_out, _override_err, _override_status = type_check.call(dir, '--files', 'builtin-call.rb', '--sig', 'no-signatures', '--format', 'json', '--no-sends')
    override_result = JSON.parse(override_out)['ir_feedback'].find { |row| row['method'] == 'run' && row['kind'] == 'return' }
    check.call('an overridden builtin withdraws the Integer call-result proof', override_result['type'] != 'Integer')
    File.write(File.join(dir, 'builtin-call.rb'), builtin_source + <<~RUBY)
      def install_singleton(obj)
        def obj.size
          :changed
        end
      end
    RUBY
    singleton_out, _singleton_err, _singleton_status = type_check.call(dir, '--files', 'builtin-call.rb', '--sig', 'no-signatures', '--format', 'json', '--no-sends')
    singleton_result = JSON.parse(singleton_out)['ir_feedback'].find { |row| row['method'] == 'run' && row['kind'] == 'return' }
    check.call('singleton method installation withdraws independent call-result facts', singleton_result['status'] == 'unknown')
    File.write(File.join(dir, 'block-call.rb'), <<~RUBY)
      class IrBlockCall
        def values
          yield
          []
        end
        def run
          values { break :changed }
        end
      end
    RUBY
    File.write(File.join(dir, 'sig/block-call.rbs'), "class IrBlockCall\n  def values: () { () -> void } -> Array[untyped]\nend\n")
    block_out, _block_err, _block_status = type_check.call(dir, '--files', 'block-call.rb', '--sig', 'sig/block-call.rbs', '--format', 'json', '--no-sends')
    block_result = JSON.parse(block_out)['ir_feedback'].find { |row| row['method'] == 'run' && row['kind'] == 'return' }
    check.call('a breaking block does not inherit its callee normal Array return', block_result['type'] != 'Array')

    puts '== independent receiver source proofs'
    File.write(File.join(dir, 'source-types.rb'), <<~RUBY)
      class IrSources
        VALUE = 'constant'
        def constant_value
          VALUE
        end
        def store
          @item = []
        end
        def read
          @item
        end
        def ir_source_identity(value)
          value
        end
        def invoke
          ir_source_identity('incoming')
        end
      end
    RUBY
    source_out, _source_err, source_status = type_check.call(dir, '--files', 'source-types.rb', '--sig', 'no-signatures', '--format', 'json', '--no-sends')
    source_rows = JSON.parse(source_out)['ir_feedback']
    source_return = ->(name) { source_rows.find { |row| row['method'] == name && row['kind'] == 'return' } }
    check.call('constant source proof is independent', source_status.success? && source_return.call('constant_value')['type'] == 'String' &&
               source_return.call('constant_value')['status'] == 'inferred')
    check.call('ivar source proof preserves uninitialized nil', source_return.call('read')['type'].split(' | ').sort == %w[Array nil] &&
               source_return.call('read')['status'] == 'inferred')
    check.call('incoming argument pool feeds independent IR facts', source_return.call('ir_source_identity')['type'] == 'String' &&
               source_return.call('ir_source_identity')['status'] == 'inferred')

    puts '== the comment wins over a signature'
    File.write(File.join(dir, 'both.rb'), commented)
    File.write(File.join(dir, 'sig/both.rbs'), "class TcUse\n  def use: (TcB o) -> untyped\nend\n")
    out, _e, _s = type_check.call(dir, '--files', 'both.rb', '--sig', 'sig/both.rbs', '--no-sends', '-q')
    check.call('TC1006 names the slot and the comment is used', out.include?('warning: TcUse#use parameter 1: the `# bc2cpp:` comment wins over signature type TcB [TC1006]'))

    puts '== an unusable signature file fails a build'
    File.write(File.join(dir, 'sig/bad.rbs'), "class TcUse\n  def put: (Integer a) -> void | (String a) -> void\nend\n")
    raised = begin
      gen.call(plain, File.join(dir, 'sig/bad.rbs'))
      false
    rescue RuntimeError => e
      e.message.include?('RBS_SIGNATURES') && e.message.include?('2 overloads')
    end
    check.call('bc2cpp aborts naming RBS_SIGNATURES and the reason', raised)
    out, _e, st = type_check.call(dir, '--files', 'use.rb', '--sig', 'sig/bad.rbs', '--no-sends', '-q')
    check.call('the type check reports it as TC1002 (exit 1)', st.exitstatus == 1 && out.include?('sig/bad.rbs:2:3: error: unsupported RBS syntax') && out.include?('[TC1002]'))
  end
end

if failures.empty?
  puts 'ok'
else
  warn "FAILED: #{failures.size}"
  failures.each { |f| warn "  - #{f}" }
  exit 1
end
