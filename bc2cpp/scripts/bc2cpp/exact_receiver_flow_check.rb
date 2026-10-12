#!/usr/bin/env ruby
# frozen_string_literal: true

# Check the exact-receiver levers of docs/adr/0301:
#
#   * CONSTANT_CLASS_POOL: `LIST = [1, 2].freeze` is exactly an Array wherever it is read, when every
#     definition of the bare name is visible, nothing but Kernel#freeze answers `freeze`, and no
#     const_missing exists;
#   * the exact receiver proof (literal, register copy, return class, argument pool) reaches the
#     registered-expression arms (`size`, `empty?`, `first` ...) and the tail of a POLY chain, so the
#     arm loses its class test and its by-name dispatch.
#
# 1. Generated code (needs MRBC): positives lose their guard and dispatch; each withdrawal (a second
#    class under the same constant name, a user `freeze`, a const_missing, an outside definition of
#    the name, a computed const_set, the kill switch, the open world) keeps the guard.
# 2. Behaviour on real mruby: compiled answers equal interpreted ones, including FrozenError on a
#    frozen constant and a user `freeze` that answers something else. Run it on a full-core and a
#    core-only mruby, and with BC2CPP_CXXFLAGS="-DMRB_32BIT -DMRB_INT32" on a 32-bit mrb_int build.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/exact_receiver_flow_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

CLASSES = <<~RUBY
  class ErBox
    def initialize; @n = 0; end
    def val; @n; end
    # A Ruby `join` next to Array#join makes every `join` a POLY chain whose tail the exact proof must reach.
    def join; 'box'; end
  end

  # A singleton `freeze` (Graphics.freeze in the engine) answers no instance.
  module ErScreen
    def self.freeze; :screen; end
  end
RUBY

HOLDER = <<~RUBY
  class ErHolder
    LIST = [1, 2, 3].freeze
    TABLE = { a: 1, b: 2 }.freeze
    LABEL = 'abcd'.freeze
    NAMES = %w[x y].freeze
    PLAIN = [4, 5]
    MIXED = [1, 2]
    TWICE = [1]

    # -- the receiver proofs ADR 0289 already had, now reaching the registered-expression arms
    def lit_size; [1, 2, 3].size; end
    def lit_join; [1, 2, 3].join; end
    def const_join; LIST.join; end
    def lit_str; 'abc'.size; end
    def lit_hash; { a: 1 }.size; end
    def moved; a = [1, 2]; b = a; c = b; c.size; end
    def mk; { a: 1, b: 2 }; end
    def from_return; mk.size; end
    def take_arr(a); a.size; end
    def go_arr; take_arr([1, 2]); end

    # -- constants
    def const_list; LIST.size; end
    def const_first; LIST.first; end
    def const_table; TABLE.size; end
    def const_label; LABEL.size; end
    def const_names; NAMES.length; end
    def const_plain; PLAIN.size; end
    def const_frozen_p; LIST.frozen?; end
    def const_push; LIST.push(4); end

    # -- a `freeze` that is not Kernel#freeze answers its own value (a user class overriding it, below)
    def box_freeze_val; ErBox.new.freeze.val; end

    # -- NEG: no single class
    def take_two(a); a.size; end
    def go_two; [take_two([1]), take_two({ a: 1 })]; end
    def mixed; MIXED.size; end
    def twice; TWICE.size; end
  end

  class ErOther
    MIXED = { x: 1, y: 2, z: 3 }
  end

  class ErDrv
    def go(h); [h.lit_size, h.moved, h.from_return, h.go_arr, h.const_list, h.const_table, h.const_label, h.mixed]; end
  end
RUBY

OWNERS = %w[ErBox ErHolder ErOther ErDrv].freeze

body_of = lambda do |code, owner, fn|
  code[/^mrb_value #{owner}_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
# No class test on the receiver and no by-name dispatch left in the method (comments name both).
live_of = ->(code, owner, fn) { body_of.call(code, owner, fn).lines.reject { |l| l.lstrip.start_with?('//') }.join }
unguarded = lambda do |code, owner, fn|
  body = live_of.call(code, owner, fn)
  !body.empty? && !body.include?('bc2cpp_send(') && !body.include?('mrb_funcall') && !body.include?('->c == M->') && !body.include?('switch (mrb_type(')
end
guarded = lambda do |code, owner, fn|
  body = live_of.call(code, owner, fn)
  !body.empty? && (body.include?('bc2cpp_send(') || body.include?('switch (mrb_type('))
end

generate = lambda do |source, dir, closed: true, env: {}, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(source, dir, closed: closed, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

CONST_METHODS = %w[const_list const_first const_table const_label const_names const_plain].freeze

# -- 1. generated code -----------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, err = generate.call(CLASSES + HOLDER, dir)

    %w[lit_size lit_join lit_str lit_hash moved from_return go_arr].each do |fn|
      check.call("ErHolder##{fn}: an exact literal/copy/return receiver takes no class test and no send", unguarded.call(code, 'ErHolder', fn))
    end
    check.call('ErHolder#take_arr: a single-site argument pool is exact', unguarded.call(code, 'ErHolder', 'take_arr'))
    (CONST_METHODS + ['const_join']).each do |fn|
      check.call("ErHolder##{fn}: a constant holding a (frozen) literal is exact", unguarded.call(code, 'ErHolder', fn))
    end
    check.call('the diagnostic lists the constant pools',
               err.include?('CLASSCONST LIST (ARR)') && err.include?('CLASSCONST TABLE (HSH)') && err.include?('CLASSCONST LABEL (STR)'))

    check.call('NEG ErHolder#take_two: call sites pass an Array and a Hash', guarded.call(code, 'ErHolder', 'take_two'))
    check.call('NEG ErHolder#mixed: the bare name MIXED is an Array in one class and a Hash in another',
               guarded.call(code, 'ErHolder', 'mixed') && !err.include?('CLASSCONST MIXED (ARR)'))
    check.call('the constant read by a frozen push keeps the FrozenError path (the push is exact, not elided)',
               body_of.call(code, 'ErHolder', 'const_push').include?('mrb_ary_push'))

    # Withdrawal conditions: each variant world keeps the guard of an otherwise-exact constant read.
    variants = {
      'a user freeze on instances' => { extra: "class ErBox\n  def freeze; :mine; end\nend\n" },
      'a const_missing' => { extra: "class ErHolder\n  def self.const_missing(n); [1]; end\nend\n" },
      'a foreign Ruby definition of LIST' => { foreign: [['er_foreign.rb', "module ErOut\n  LIST = {}\nend\n"]] },
      'a native definition of LIST' => { native: [['er_native.cxx',
                                                   "void er_c(mrb_state* M) { mrb_define_const(M, M->object_class, \"LIST\", mrb_nil_value()); }\n"]] },
      'a second class under the name LIST' => { extra: "class ErBox\n  LIST = { z: 1 }\nend\n" },
      'a LIST assigned a call result' => { extra: "class ErBox\n  LIST = [1].map { |x| x }\nend\n" }
    }
    variants.each do |what, spec|
      d = File.join(dir, what.gsub(/\W+/, '_'))
      Dir.mkdir(d)
      vcode, = generate.call(CLASSES + HOLDER + spec.fetch(:extra, ''), d, **spec.slice(:native, :foreign))
      verdict = if what.include?('freeze')
                  # NEG for every `.freeze` constant; a plain literal constant does not go through `freeze`.
                  CONST_METHODS.reject { |fn| fn == 'const_plain' }.all? { |fn| guarded.call(vcode, 'ErHolder', fn) } &&
                    unguarded.call(vcode, 'ErHolder', 'const_plain')
                elsif what.include?('const_missing')
                  CONST_METHODS.all? { |fn| guarded.call(vcode, 'ErHolder', fn) }
                else
                  guarded.call(vcode, 'ErHolder', 'const_list')
                end
      check.call("NEG #{what}: withdrawn as the model says", verdict)
    end

    singleton = "module ErScreen2\n  def self.freeze; :s; end\nend\n"
    Dir.mktmpdir do |sd|
      scode, = generate.call(CLASSES + HOLDER + singleton, sd)
      check.call('a singleton `freeze` (Graphics.freeze) does not withdraw the instance proof',
                 unguarded.call(scode, 'ErHolder', 'const_list'))
    end

    Dir.mktmpdir do |cd|
      ccode, = generate.call(CLASSES + HOLDER + "class ErHolder\n  def wild(n); Object.const_set(n, 1); end\nend\n", cd)
      check.call('NEG a computed const_set: withdrawn', guarded.call(ccode, 'ErHolder', 'const_list'))
    end

    Dir.mktmpdir do |off_dir|
      off_code, off_err = generate.call(CLASSES + HOLDER, off_dir, env: { 'BC2CPP_CLASS_POOLS' => '0' })
      check.call('the kill switch (BC2CPP_CLASS_POOLS=0): no constant pool, the old guards',
                 !off_err.include?('CLASSCONST') && guarded.call(off_code, 'ErHolder', 'const_list') &&
                   unguarded.call(off_code, 'ErHolder', 'lit_size'))
    end

    Dir.mktmpdir do |open_dir|
      open_code, = generate.call(CLASSES + HOLDER, open_dir, closed: false)
      check.call('the open world proves nothing about a constant', guarded.call(open_code, 'ErHolder', 'const_list'))
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 2. behaviour ----------------------------------------------------------------------

# The full-core build when there is one (or BC2CPP_FULL_BUILD_DIR may make one), and the core-only build.
builds = { 'full-core' => runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil), 'core-only' => runtime.core }.compact
builds['full-core'] = runtime.full_or_build if builds.empty?
builds.compact!
if ENV['MRBC'] && !builds.empty? && runtime.compiler? && !ENV['ERF_GENERATED_ONLY']
  puts '== fixture on real mruby, interpreted and compiled'
  methods = %w[lit_size lit_join const_join lit_str lit_hash moved from_return go_arr const_list const_first const_table const_label
               const_names const_plain const_frozen_p const_push go_two mixed twice box_freeze_val]
  calls = methods.map { |m| "  call(M, \"#{m}\", holder, \"#{m}\");" }.join("\n")
  body = <<~CPP
    static int scenario(mrb_state* M) {
      mrb_value holder = mrb_obj_new(M, mrb_class_get(M, "ErHolder"), 0, nullptr);
      mrb_value drv = mrb_obj_new(M, mrb_class_get(M, "ErDrv"), 0, nullptr);
    #{calls}
      call(M, "driver", drv, "go", 1, &holder);
      return 0;
    }
  CPP
  worlds = {
    'plain world' => '',
    'a user freeze on instances' => "class ErBox\n  def freeze; :mine; end\nend\n",
    'a singleton freeze' => "module ErScreen2\n  def self.freeze; :s; end\nend\n"
  }
  builds.each do |build_name, build|
    full = File.exist?("#{build}/lib/libmruby.a")
    worlds.each do |world, extra|
      label = "#{build_name}, #{world}"
      Dir.mktmpdir do |dir|
        _code, err = generate.call(CLASSES + HOLDER + extra, dir)
        built, output = runtime.run(dir, err, OWNERS, body, build: build, full: full)
        check.call("#{label}: the fixture compiles and runs against real mruby", built)
        puts output unless built
        next unless built

        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
        check.call("#{label}: every method answers what the interpreter answers (#{values.call('interpreted').size} lines), values and exceptions alike",
                   !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
        compiled = values.call('compiled')
        if extra.include?('def freeze; :mine')
          # Folded into its receiver, `.val` would answer 0; the overriding freeze hands back a Symbol, which the
          # interpreter and the compiled call both reject (the exception class is the build's, not the point).
          line = compiled.find { |l| l.start_with?('box_freeze_val =>') }
          puts "  box_freeze_val compiled: #{line.inspect}" unless line.to_s.start_with?('box_freeze_val => raised')
          check.call("#{label}: the overriding freeze is called, not folded into its receiver",
                     line.to_s.start_with?('box_freeze_val => raised'))
        end
        next unless extra.empty?

        check.call("#{label}: a frozen constant still raises FrozenError from its push", compiled.include?('const_push => raised FrozenError'))
        check.call("#{label}: the constant reads answer their sizes", compiled.include?('const_list => 3') && compiled.include?('const_table => 2') &&
                                                                     compiled.include?('const_label => 4') && compiled.include?('const_names => 2'))
        check.call("#{label}: the Array/Hash argument sites answer both classes", compiled.include?('go_two => [1, 1]'))
        check.call("#{label}: Kernel#freeze answers its receiver", compiled.include?('box_freeze_val => 0'))
        lines = sections.fetch('compiled', [])
        %w[lit_size lit_join const_join lit_str lit_hash moved from_return go_arr const_list const_first const_table const_label const_names const_plain].each do |m|
          at = lines.index { |l| l.start_with?("#{m} =>") }
          n = at && lines[at + 1].to_s[/dispatches=(\d+)/, 1]&.to_i
          check.call("#{label}: #{m}: the compiled call makes no dynamic dispatch", n == 0)
        end
      end
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
end

if failures.empty?
  puts 'bc2cpp exact receiver flow check: PASS'
else
  warn "bc2cpp exact receiver flow check: #{failures.size} failure(s)"
  exit 1
end
