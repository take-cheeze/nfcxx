#!/usr/bin/env ruby
# frozen_string_literal: true

# ALIAS_SITES (docs/adr/0474): `alias_method :new, :old` / `alias new old` written straight in a class body,
# with literal names, is a definition of `new` on that class: a copy of `old`'s body as the walk last saw it
# on that class, or a definition with no body the compiler knows (native, core, inherited `old`). A settled
# site installs nothing at run time; any other alias stays a dynamic installer.
#
# 1. Registry (MRBC): which definition each shape registers, what a later `def old` leaves alone, every
#    refusal and settle withdrawal, and CodeGen#symbol_installed_names.
# 2. Generated code (MRBC): calls to an alias of a Ruby method are direct; a method-body alias keeps the
#    call dynamic (CLOSED_WORLD kept: dynamic_install).
# 3. Behaviour on real mruby (MRBC, g++, and BC2CPP_MRUBY_FULL, a core-only build (BC2CPP_MRUBY_CORE or the
#    tree's build*/mruby/host/mrbc), or a full-core one built once into BC2CPP_FULL_BUILD_DIR): interpreted and
#    compiled answer alike for an alias of a Ruby method, an inherited method redefined after the alias, a core
#    method, a private alias, a call through `__send__`, strict arity, and a refused method-body alias.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/alias_method_check.rb

require 'set'
require 'tmpdir'

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
runtime = Bc2cppFixtureRuntime

# [registry after settle, ireps, kept, dropped, CodeGen#symbol_installed_names] for +source+.
registry_of = lambda do |source, closed: true, method_trusted: true|
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'al.rb')
    File.write(path, source)
    ireps, root = compile_ireps(path, 'al_fixture', dir)
    registry = build_registry(ireps, root)[0]
    kept, dropped = AliasSites.settle(registry, ireps, closed: closed, method_trusted: method_trusted)
    installed = CodeGen.new(ireps, registry, {}).send(:symbol_installed_names)
    [registry, ireps, kept, dropped, installed]
  end
end
alias_of = ->(registry, name) { registry.fetch(name, []).select { |d| d.installer == :alias } }

puts '-- registry'
SHAPES = <<~RUBY
  module AlMix
    def al_mixed; 1; end
  end
  module AlPre
    def al_pre; 2; end
  end
  class AlR
    include AlMix
    def al_g(x); x + 1; end
    alias_method :al_first, :al_g
    def al_g(x); x + 2; end
    alias al_second al_g
    def al_up(x); super(x); end
    alias_method :al_up2, :al_up
    def initialize; @a = 1; end
    alias_method :al_init, :initialize
    alias_method :al_mixed2, :al_mixed
  end
  class AlP
    prepend AlPre
    def al_pre; 3; end
    alias_method :al_pre2, :al_pre
  end
  class Array
    alias_method :al_sort, :sort
    alias_method :al_size, :size
  end
RUBY
registry, ireps, kept, dropped, installed = registry_of.call(SHAPES)
check.call('every class-body alias registers a definition', kept == 8 && dropped.zero?)
first, second = registry.fetch('al_g').reject(&:installer)
copy1 = alias_of.call(registry, 'al_first').first
copy2 = alias_of.call(registry, 'al_second').first
check.call('an alias copies the definition the walk saw last (a later def leaves it alone)',
           copy1&.irep&.start_with?("#{first.irep}~al") && copy2&.irep&.start_with?("#{second.irep}~al"))
check.call('the copy is the same code under its own irep',
           ireps[copy1.irep]&.instructions.equal?(ireps[first.irep].instructions) && copy1.irep != first.irep)
check.call('the alias keyword registers like alias_method', copy2.owner == 'AlR' && copy2.visibility == :public)
check.call('a body that calls super has no copy (super would answer the new name)', alias_of.call(registry, 'al_up2').first&.irep.nil?)
check.call('an alias of initialize is a private copy', alias_of.call(registry, 'al_init').first&.visibility == :private &&
                                                       !alias_of.call(registry, 'al_init').first.irep.nil?)
check.call('an alias of an inherited method has no body the compiler knows', alias_of.call(registry, 'al_mixed2').first&.irep.nil?)
check.call('an alias in a class with a prepended module has no copy', alias_of.call(registry, 'al_pre2').first&.irep.nil?)
check.call('aliases of core and native methods have no body', %w[al_sort al_size].all? { |n| alias_of.call(registry, n).first&.irep.nil? })
check.call('settled aliases install nothing', installed == Set.new)

WRAP = ->(body) { "class AlN\n  def al_b(x); x; end\n#{body}end\n" }
REFUSED = {
  'an alias in a method body' => "  def self.patch; alias_method :al_a, :al_b; end\n",
  'an alias under a condition' => "  alias_method :al_a, :al_b if $al\n",
  'an alias in a loop' => "  2.times { alias_method :al_a, :al_b }\n",
  'a computed name' => "  alias_method \"al_\#{1}\".to_sym, :al_b\n",
  'an explicit receiver' => "  AlN.alias_method :al_a, :al_b\n",
  'an alias handed to private' => "  private alias_method :al_a, :al_b\n",
  'a singleton class opened on another object' => "  class << Object.new; alias_method :al_a, :to_s; end\n"
}.freeze
REFUSED.each do |what, body|
  registry, _ireps, kept, _dropped, installed = registry_of.call(WRAP.call(body))
  check.call("#{what} registers nothing", kept.zero? && alias_of.call(registry, 'al_a').empty?)
  check.call("#{what} keeps the name installed at run time", installed.nil? || installed.include?('al_a'))
end
registry, _ireps, kept, = registry_of.call("alias al_top puts\n")
check.call('an alias at top level registers nothing', kept.zero? && alias_of.call(registry, 'al_top').empty?)

_registry, ireps, kept, dropped, installed = registry_of.call(WRAP.call("  alias_method :al_a, :al_b\n  def al_a; 0; end\n"))
check.call('a def of the new name drops the alias', kept.zero? && dropped == 1 && installed.include?('al_a'))
check.call('a dropped copy leaves the program', ireps.keys.none? { |l| l.include?('~al') })
_registry, _ireps, kept, dropped, = registry_of.call(WRAP.call("  alias_method :al_a, :al_b\n  alias al_c al_b\n"), closed: false)
check.call('outside a closed world every alias is dropped', kept.zero? && dropped == 2)
registry, _ireps, kept, dropped, = registry_of.call(WRAP.call("  alias_method :al_a, :al_b\n  alias al_c al_b\n"), method_trusted: false)
check.call('an untrusted alias_method drops its sites, the keyword stays',
           kept == 1 && dropped == 1 && alias_of.call(registry, 'al_c').size == 1)

body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
SITES_LINE = /== alias sites \((\d+) registered as definitions, (\d+) left as installers\)/

WORLD = <<~RUBY
  module AlBase
    def hello(x); x + 100; end
  end
  class AlFx
    include AlBase
    def initialize; @n = 10; end
    def greet(x); x + @n; end
    alias_method :old_greet, :greet
    alias kw_greet greet
    alias_method :old_hello, :hello
    def hello(x); old_hello(x) * 2; end
    alias_method :_al_init, :initialize
    def run(x); greet(x) + old_greet(x) + kw_greet(x) + hello(x); end
    def sorted(a); a.al_sort; end
    def via_send(x); __send__(:old_greet, x); end
  end
  class Array
    alias_method :al_sort, :sort
  end
  # Not compiled: calls through OP_SEND, where the VM checks arity and visibility.
  class AlProbe
    def self.og0(o); o.old_greet; end
    def self.priv(o); o._al_init; end
  end
RUBY
REFUSED_WORLD = <<~RUBY
  class AlKept
    def greet(x); x + 1; end
    def self.patch; alias_method :kept_greet, :greet; end
    def run(x); kept_greet(x); end
  end
RUBY

puts '-- generated code'
Dir.mktmpdir do |dir|
  code, err = runtime.generate(WORLD, dir)
  check.call('the world registers five aliases', err[SITES_LINE, 1] == '5' && err[SITES_LINE, 2] == '0')
  run = body_of.call(code, 'AlFx_run')
  check.call('run calls greet and both aliases of it directly',
             %w[greet old_greet kw_greet].all? { |m| run.include?("AlFx_#{m}_impl(M, self") })
  check.call('the aliases are compiled', %w[old_greet kw_greet _al_init].all? { |m| code.include?("AlFx_#{m}_impl(mrb_state* M") })
  check.call('a call to an alias without a body is an owner call, not a by-name send',
             body_of.call(code, 'AlFx_hello').include?('CLOSED_WORLD owner-call: old_hello'))
  check.call('no call is kept dynamic for an installed name', !code.include?('kept: dynamic_install'))
end
Dir.mktmpdir do |dir|
  code, err = runtime.generate(REFUSED_WORLD, dir)
  run = body_of.call(code, 'AlKept_run')
  check.call('a method-body alias registers nothing', err[SITES_LINE, 1].to_i.zero?)
  check.call('a method-body alias keeps its call a dynamic send, never a proven miss',
             !run.empty? && run.include?('bc2cpp_send(M, self') && !run.include?('bc2cpp_nomethod('))
end

# Array#each and #sort for a build whose mrblib is empty; core-sourced, so they are still mruby's own.
POLYFILL = <<~RUBY
  class Array
    def sort(&block)
      dup.sort!(&block)
    end
  end
RUBY

SCENARIO = <<~CPP
  static int scenario(mrb_state* M) {
    mrb_value o = mrb_obj_new(M, mrb_class_get(M, "AlFx"), 0, nullptr);
    mrb_value probe = mrb_obj_value(mrb_class_get(M, "AlProbe"));
    mrb_value a4 = mrb_fixnum_value(4);
    mrb_value list = mrb_ary_new(M);
    mrb_ary_push(M, list, mrb_fixnum_value(3)); mrb_ary_push(M, list, mrb_fixnum_value(1)); mrb_ary_push(M, list, mrb_fixnum_value(2));
    mrb_value init = mrb_symbol_value(mrb_intern_cstr(M, "_al_init"));
    call(M, "run(4)", o, "run", 1, &a4);
    call(M, "old_greet(4)", o, "old_greet", 1, &a4);
    call(M, "hello(4)", o, "hello", 1, &a4);
    call(M, "old_hello(4)", o, "old_hello", 1, &a4);
    call(M, "via_send(4)", o, "via_send", 1, &a4);
    call(M, "sorted", o, "sorted", 1, &list);
    call(M, "al_sort", list, "al_sort");
    call(M, "__send__(:_al_init)", o, "__send__", 1, &init);
    call(M, "probe.og0", probe, "og0", 1, &o);
    call(M, "probe.priv", probe, "priv", 1, &o);
    return 0;
  }
CPP
REFUSED_SCENARIO = <<~CPP
  static int scenario(mrb_state* M) {
    mrb_value o = mrb_obj_new(M, mrb_class_get(M, "AlKept"), 0, nullptr);
    mrb_value k = mrb_obj_value(mrb_class_get(M, "AlKept"));
    mrb_value a4 = mrb_fixnum_value(4);
    call(M, "kept.run(4) before", o, "run", 1, &a4);
    call(M, "patch", k, "patch");
    call(M, "kept.run(4) after", o, "run", 1, &a4);
    return 0;
  }
CPP

full = runtime.full || (runtime.core ? nil : runtime.full_or_build)
build = full || runtime.core
if build.nil? || !runtime.compiler?
  puts '  SKIP run: needs g++ and a mruby build (BC2CPP_MRUBY_FULL, BC2CPP_MRUBY_CORE or build*/mruby/host/mrbc)'
else
  puts "-- fixtures on real mruby (#{full ? 'full-core' : 'core only'}), interpreted and compiled"
  values = ->(sections, name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
  [[WORLD, %w[AlFx], SCENARIO, 10], [REFUSED_WORLD, %w[AlKept], REFUSED_SCENARIO, 3]].each do |world, owners, scenario, calls|
    Dir.mktmpdir do |dir|
      _code, err = if full
                     runtime.generate(world, dir, only_owners: owners)
                   else
                     runtime.generate(POLYFILL, dir, only_owners: owners, path: '3rd/mruby/mrblib/al_polyfill.rb',
                                                     extra: [['fixture.rb', world]])
                   end
      built, output = runtime.run(dir, err, owners, scenario, build: build, full: !full.nil?, exact_arity: true)
      check.call("#{owners.first} compiles and runs against real mruby", built)
      puts output unless built
      next unless built

      sections = runtime.sections(output)
      interpreted = values.call(sections, 'interpreted')
      compiled = values.call(sections, 'compiled')
      puts output if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
      check.call("#{owners.first}: compiled answers what the interpreter answers (#{interpreted.size} calls)",
                 interpreted.size == calls && interpreted == compiled)
      text = interpreted.join("\n")
      if owners == %w[AlFx]
        check.call('the aliases answer: a Ruby copy, an inherited method redefined after the alias, a core method',
                   text.include?('run(4) => 250') && text.include?('old_greet(4) => 14') && text.include?('hello(4) => 208') &&
                     text.include?('old_hello(4) => 104') && text.include?('via_send(4) => 14') &&
                     text.include?('sorted => [1, 2, 3]') && text.include?('al_sort => [1, 2, 3]'))
        check.call('arity and the copied private visibility hold',
                   text.include?('probe.og0 => raised ArgumentError') && text.match?(/probe\.priv => raised (NoMethodError|Exception)/) &&
                     text.include?('__send__(:_al_init) => 10'))
        dispatches = sections.fetch('compiled', []).each_cons(2).select { |c, n| c.start_with?('run(4)') && n.include?('dispatches=') }
        check.call('a compiled run makes no dynamic dispatch (the bodyless alias is an owner call, ADR 0468)',
                   dispatches.size == 1 && dispatches.first[1].strip == 'dispatches=0')
      else
        check.call('the refused alias still installs at run time',
                   text.match?(/kept\.run\(4\) before => raised (NoMethodError|Exception)/) && text.include?('kept.run(4) after => 5'))
      end
    end
  end
end

puts(failures.empty? ? 'bc2cpp_alias_method_check OK' : "FAILED: #{failures.size}")
exit(failures.empty? ? 0 : 1)
