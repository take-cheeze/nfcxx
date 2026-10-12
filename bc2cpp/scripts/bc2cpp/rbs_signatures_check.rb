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
    check.call('a method the program lacks is a TC1003 warning', lines.include?('sig/contra.rbs:6:3: warning: TcSym#ghost: no such method in the program [TC1003]'))
    check.call('a wrong parameter count is a TC1004 warning',
               lines.include?('sig/contra.rbs:7:3: warning: TcSym#go: signature lists 1 required parameter(s), method takes 0; not used [TC1004]'))

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
