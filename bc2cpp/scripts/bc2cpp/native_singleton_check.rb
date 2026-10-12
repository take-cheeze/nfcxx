#!/usr/bin/env ruby
# frozen_string_literal: true

# NATIVE_SINGLETON_CALL (docs/adr/0416): `Const.name(args)` on a stable constant whose singleton method is one
# registered C function (File.exist?, File.file?, File.basename, Math.sin, Time.now ...) is called through a
# per-site method cache (bc2cpp_native_singleton) instead of a by-name bc2cpp_send.
#
# 1. With MRBC: the generated code of worlds that each add one way for the lookup to change (a Ruby
#    redefinition, `class << File`, define_singleton_method, extend, a prepend on the singleton class, an alias,
#    visibility, remove_method, a reassigned or nested-shadowed constant, a second native registration, a native
#    alias or call by name, an outside Ruby definer, another class's method of the same name). The affected site
#    keeps its by-name send; the unaffected sites of the same world are still bound, so the refusal is the
#    named condition and not a blanket one.
# 2. With MRBC, BC2CPP_MRUBY_FULL and g++: the worlds run on real mruby, interpreted and compiled, and must
#    answer alike -- values, exception classes and messages, including the wrong-arity ArgumentError, a block
#    given to File.open, method_missing on the class, a runtime redefinition or visibility change after
#    compilation (the runtime fill refuses a non-public or non-C method and sends), and a bound site reaching
#    its native function without a by-name dispatch.
#
# NS_WORLDS=w1,w2 limits the worlds (the mutation check names the one a mutant must die in);
# NS_GENERATED_ONLY=1 skips part 2.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/native_singleton_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'cxx'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless ENV['MRBC']
  puts '  SKIP generated code: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  puts 'bc2cpp_native_singleton_check OK'
  exit 0
end

require_relative 'fixture_runtime'
runtime = Bc2cppFixtureRuntime
ROOT = runtime::ROOT
OWNERS = %w[NsUse NsScope::Probe NsF::Probe2 NsKid NsGfx NsLate].freeze
TIME_GEM = [['mruby-time', "#{ROOT}/3rd/mruby/mrbgems/mruby-time"]].freeze

# Every world shares these sites. Each method calls one native singleton function.
BASE = <<~RUBY
  class NsUse
    def exist(p); File.exist?(p); end
    def file(p); File.file?(p); end
    def base(p); File.basename(p); end
    def base_ext(p, e); File.basename(p, e); end
    def m_sin(x); Math.sin(x); end
    def m_cos(x); Math.cos(x); end
    def m_tan(x); Math.tan(x); end
    def pipe_name(a); IO.sysopen(a); end
    def opened(p); File.open(p) { |f| f.gets }; end
    def now_class; Time.now.class; end
    def now_year_class; Time.now.year.class; end
    def now_arg; Time.now(1); end
    def exist_noarg_message
      File.exist?
    rescue ArgumentError => e
      e.message
    end
    def exist_two_message(a, b)
      File.exist?(a, b)
    rescue ArgumentError => e
      e.message
    end
    def sin_type_message(s)
      Math.sin(s)
    rescue TypeError => e
      e.message
    end
    def missing_thing; File.nonexistent_zork(1); end
  end
RUBY

# A scoped native module: the compiler knows RGSS::Graphics from the bytecode's `module` statements, as in the engine.
GFX = <<~RUBY
  module RGSS
    module Graphics
    end
  end
  class NsGfx
    def snap; RGSS::Graphics.snap_to_bitmap; end
  end
RUBY

# name => [extra Ruby, {native/foreign sources}, bound sites, kept sites]. A site is "Class#method" and the
# native function it calls; "bound" sites carry the NATIVE_SINGLETON_CALL marker, "kept" sites keep their send.
WORLDS = {
  'base' => {
    extra: <<~RUBY + GFX,
      # A Ruby redefinition of one name leaves the other names of the constant bound.
      def Math.cos(x); :my_cos; end
      # An alias over one name (the alias target is not bound either).
      class << File
        alias_method :file?, :directory?
      end
      # A visibility change names one function (mruby has no private_class_method).
      class << Math
        private :tan
      end
      # A prepend on one constant's singleton class leaves the others bound.
      module NsHook; def sysopen(*a); :hook; end; end
      class << IO
        prepend NsHook
      end
      # A same-named constant nested in a module shadows File inside it only (and has no `exist?`).
      module NsScope
        # Empty: the name is native-safe, so only the lexical scope keeps the site off File's registration.
        class File
        end
        class Probe
          def exist(p); File.exist?(p); end
        end
      end
    RUBY
    bound: { 'NsGfx#snap' => 'snap_to_bitmap', 'NsUse#exist' => 'exist?', 'NsUse#base' => 'basename', 'NsUse#base_ext' => 'basename',
             'NsUse#m_sin' => 'sin' },
    kept: { 'NsUse#file' => 'file?', 'NsUse#m_cos' => 'cos', 'NsUse#m_tan' => 'tan', 'NsUse#pipe_name' => 'sysopen',
            'NsScope::Probe#exist' => 'exist?', 'NsUse#missing_thing' => 'nonexistent_zork' }
  },
  'method_missing on the class' => {
    # It answers only names the singleton lacks, but a method_missing hook is a closed-world refusal.
    extra: "class << File\n  def method_missing(name, *args); [:mm, name, args]; end\nend\n",
    kept: { 'NsUse#exist' => 'exist?', 'NsUse#base' => 'basename' }, bound: {}
  },
  'redefined' => {
    extra: "def File.exist?(p); :mine; end\n",
    kept: { 'NsUse#exist' => 'exist?' }, bound: { 'NsUse#base' => 'basename' }
  },
  'reopened' => {
    extra: "class << File\n  def exist?(p); :mine; end\nend\n",
    kept: { 'NsUse#exist' => 'exist?' }, bound: { 'NsUse#base' => 'basename' }
  },
  'define_singleton_method' => {
    extra: "File.define_singleton_method(:exist?) { |p| :mine }\n",
    kept: { 'NsUse#exist' => 'exist?', 'NsUse#base' => 'basename' }, bound: {}
  },
  'extend' => {
    extra: "module NsExt; def exist?(p); :ext; end; end\nFile.extend(NsExt)\n",
    kept: { 'NsUse#exist' => 'exist?', 'NsUse#base' => 'basename' }, bound: {}
  },
  'singleton include' => {
    extra: "module NsInc; def exist?(p); :inc; end; end\nclass << File\n  include NsInc\nend\n",
    kept: { 'NsUse#exist' => 'exist?', 'NsUse#base' => 'basename' }, bound: { 'NsUse#m_sin' => 'sin' }
  },
  'singleton prepend' => {
    extra: "module NsPre; def exist?(p); :pre; end; end\nclass << File\n  prepend NsPre\nend\n",
    kept: { 'NsUse#exist' => 'exist?', 'NsUse#base' => 'basename' }, bound: { 'NsUse#m_sin' => 'sin' }
  },
  'remove_method' => {
    extra: "class << File\n  remove_method :exist?\nend\n",
    kept: { 'NsUse#exist' => 'exist?' }, bound: { 'NsUse#base' => 'basename' }
  },
  'reassigned constant' => {
    extra: "class NsFake\n  def self.exist?(p); :fake; end\nend\nFile = NsFake\n",
    kept: { 'NsUse#exist' => 'exist?', 'NsUse#base' => 'basename' }, bound: { 'NsUse#m_sin' => 'sin' }
  },
  'a method of the name on another class' => {
    # Another class's instance method is never reached by `File.exist?`, so the site still binds.
    extra: "class NsOther\n  def exist?(p); :other; end\nend\n",
    kept: {}, bound: { 'NsUse#exist' => 'exist?', 'NsUse#base' => 'basename' }
  },
  'a second native registration' => {
    extra: '',
    native: [['ns_twice.c', <<~C]],
      void ns_twice_init(mrb_state* mrb) {
        struct RClass *file = mrb_class_get_id(mrb, MRB_SYM(File));
        mrb_define_class_method_id(mrb, file, MRB_SYM_Q(exist), ns_other_exist, MRB_ARGS_REQ(1));
      }
    C
    # Two C registrations are still C functions; the call resolves whichever the VM ends up with.
    kept: {}, bound: { 'NsUse#exist' => 'exist?', 'NsUse#base' => 'basename' }
  },
  'a native alias of the name' => {
    extra: '',
    native: [['ns_alias.c', <<~C]],
      void ns_alias_init(mrb_state* mrb) {
        struct RClass *file = mrb_class_get_id(mrb, MRB_SYM(File));
        mrb_define_alias(mrb, file, "exist?", "file?");
      }
    C
    kept: { 'NsUse#exist' => 'exist?' }, bound: { 'NsUse#base' => 'basename' }
  },
  'a foreign nested constant' => {
    # The compiler's class table holds only the bytecode's constants; the outside Ruby's NsF::File and
    # NsF2::File shadow File inside NsF and inside anything that includes NsF2.
    extra: <<~RUBY,
      module NsF
        class Probe2
          def exist(p); File.exist?(p); end
        end
      end
      module NsF2
      end
      class NsKid
        include NsF2
        def exist2(p); File.exist?(p); end
      end
    RUBY
    foreign: [['ns_foreign_scopes.rb', "module NsF\n  class File\nend\nend\nmodule NsF2\n  class File\nend\nend\n"]],
    kept: { 'NsF::Probe2#exist' => 'exist?', 'NsKid#exist2' => 'exist?' }, bound: { 'NsUse#exist' => 'exist?' }
  },
  'a build gem Ruby definer' => {
    # The closed world's own outside Ruby (a build gem's mrblib), which FOREIGN_RUBY_SRCS does not list in this fixture.
    extra: '',
    gem: ['ns_gem_ruby', { 'mrblib/ns_gem.rb' => "class File\n  def self.exist?(p); true; end\nend\n" }],
    kept: { 'NsUse#exist' => 'exist?' }, bound: { 'NsUse#base' => 'basename' }
  },
  'a def nested in a method' => {
    # The registry cannot place a `def` run from a method body; it can still install File.exist? at run time.
    extra: "class NsLate\n  def setup\n    def File.exist?(p); :late; end\n  end\nend\n",
    kept: { 'NsUse#exist' => 'exist?' }, bound: { 'NsUse#base' => 'basename' }
  },
  'a global refusal and a scoped native constant' => {
    # `File.extend` refuses the closed world; RGSS::Graphics is a scoped constant, so only the name-level refusal
    # (not the top-level constant proof) can keep its site on the send.
    extra: "module NsExt; def exist?(p); :ext; end; end\nFile.extend(NsExt)\n#{GFX}",
    kept: { 'NsGfx#snap' => 'snap_to_bitmap' }, bound: {}
  },
  'an outside Ruby definer' => {
    extra: '',
    foreign: [['ns_foreign.rb', "class File\n  def self.exist?(p); true; end\nend\n"]],
    kept: { 'NsUse#exist' => 'exist?' }, bound: { 'NsUse#base' => 'basename' }
  }
}.freeze

selected = ENV['NS_WORLDS']&.split(',')&.map(&:strip)
worlds = selected == ['-'] ? {} : WORLDS.select { |name, _| selected.nil? || selected.include?(name) }
if worlds.empty? && selected != ['-']
  puts "  FAIL no world named #{selected.inspect}"
  exit 1
end

# The generated function body of one site ("NsScope::Probe#exist" -> NsScope__Probe_exist).
body_of = lambda do |code, site|
  fn = site.sub('#', '_').gsub('::', '__')
  code[/^mrb_value #{Regexp.escape(fn)}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

generated = {}
mutex = Mutex.new
queue = Queue.new
worlds.each { |entry| queue << entry }
puts '-- generated code'
# Each generation is one bc2cpp.rb process of a closed-world run; BC2CPP_JOBS bounds them (default: 2).
workers = Array.new([Integer(ENV.fetch('BC2CPP_JOBS', '2')), worlds.size].min) do
  Thread.new do
    loop do
      name, world = begin
        queue.pop(true)
      rescue ThreadError
        break
      end
      Dir.mktmpdir do |dir|
        gems = TIME_GEM.dup
        if world[:gem]
          gem_name, files = world[:gem]
          gem_dir = File.join(dir, gem_name)
          files.each do |path, text|
            FileUtils.mkdir_p(File.dirname(File.join(gem_dir, path)))
            File.write(File.join(gem_dir, path), text)
          end
          FileUtils.mkdir_p(File.join(gem_dir, 'src'))
          gems += [[gem_name, gem_dir]]
        end
        code, err = runtime.generate(BASE + world[:extra], dir, only_owners: OWNERS, build_gems: gems,
                                                                native: world[:native] || [], foreign: world[:foreign] || [])
        mutex.synchronize { generated[name] = [code, err] }
        puts err.lines.grep(/NATIVE_SINGLETON_CALL\]|global refusal|closed world \(/).join if ENV['NS_DEBUG']
      end
    end
  end
end
workers.each(&:join)

worlds.each do |name, world|
  code, = generated.fetch(name)
  puts "-- world: #{name}"
  (world[:bound] || {}).each do |site, native|
    body = body_of.call(code, site)
    check.call("#{name}: #{site} binds #{native} to its native function",
               !body.empty? && body.include?("NATIVE_SINGLETON_CALL :#{native} ->") && body.include?('bc2cpp_native_singleton(M, ') &&
                 !body.include?("POLY :#{native}"))
  end
  (world[:kept] || {}).each do |site, native|
    body = body_of.call(code, site)
    # A by-name send, or (a constant that names a Ruby-defined class) that class's own singleton method.
    check.call("#{name}: #{site} does not bind #{native} to a native function",
               !body.empty? && !body.include?("NATIVE_SINGLETON_CALL :#{native} ->") &&
                 (body.include?('bc2cpp_send(M, ') || body.include?("CLOSED_WORLD_CONSTANT_OBJECT :#{native}")))
  end
end

if selected.nil? || selected.include?('base')
  base_code, = generated.fetch('base')
  check.call('every bound site is a call of the shared helper, which holds the only lookup',
             base_code.scan('bc2cpp_native_singleton_named(').empty? && base_code.include?('static mrb_value bc2cpp_native_singleton('))
  check.call('the helper falls back to the checked send for a method that is not a public C function',
             base_code[/static mrb_value bc2cpp_native_singleton\(.*?^\}/m].to_s.include?('bc2cpp_check_send(M, recv, mid, argc, argv, bc2cpp_sym_check[i] == 2)'))
end

if selected.nil? || selected.include?('kill switch')
  # BC2CPP_NATIVE_SINGLETON=0 is the control: the generator then emits what master does.
  Dir.mktmpdir do |dir|
    ENV['BC2CPP_NATIVE_SINGLETON'] = '0'
    code, = runtime.generate(BASE, dir, only_owners: OWNERS, build_gems: TIME_GEM)
    check.call('kill switch: BC2CPP_NATIVE_SINGLETON=0 leaves every site on its by-name send',
               !code.include?('NATIVE_SINGLETON_CALL') && !code.include?('bc2cpp_native_singleton(') && code.include?('bc2cpp_send(M, '))
  ensure
    ENV.delete('BC2CPP_NATIVE_SINGLETON')
  end
end

full = ENV['NS_GENERATED_ONLY'] == '1' ? nil : runtime.full_or_build
if ENV['NS_GENERATED_ONLY'] == '1'
  puts '  SKIP run: NS_GENERATED_ONLY=1'
elsif full.nil? || !runtime.compiler?
  puts '  SKIP run: set BC2CPP_MRUBY_FULL (libmruby.a with the full-core gems, from the patched 3rd/mruby) and have g++'
else
  puts '-- on real mruby, interpreted and compiled'
  scratch = Dir.mktmpdir('ns_files')
  File.write(File.join(scratch, 'line.txt'), "first line\nsecond\n")
  quoted = ->(text) { text.dump }
  # The calls every world makes; a runtime step may change the VM before them (runtime: C++ run once).
  scenario = lambda do |runtime_ruby|
    <<~CPP
      static mrb_value s(mrb_state* M, const char* text) { return mrb_str_new_cstr(M, text); }
      static int scenario(mrb_state* M) {
        mrb_value use = mrb_obj_new(M, mrb_class_get(M, "NsUse"), 0, nullptr);
        const char* real = #{quoted.call(File.join(scratch, 'line.txt'))};
        #{runtime_ruby.empty? ? '' : "mrb_load_string(M, #{quoted.call(runtime_ruby)}); if (M->exc) { mrb_print_error(M); return 3; }"}
        mrb_value a1 = s(M, real);
        mrb_value a2 = s(M, "/definitely/not/here");
        mrb_value a3 = s(M, "/usr/lib/ruby.rb");
        mrb_value two[2] = { s(M, "/usr/lib/ruby.rb"), s(M, ".rb") };
        mrb_value f = mrb_float_value(M, 0.5);
        call(M, "exist real", use, "exist", 1, &a1);
        call(M, "exist missing", use, "exist", 1, &a2);
        call(M, "file real", use, "file", 1, &a1);
        mrb_value usr = s(M, "/usr");
        call(M, "file dir", use, "file", 1, &usr);
        call(M, "base", use, "base", 1, &a3);
        call(M, "base with extension", use, "base_ext", 2, two);
        call(M, "sin", use, "m_sin", 1, &f);
        call(M, "cos", use, "m_cos", 1, &f);
        call(M, "tan", use, "m_tan", 1, &f);
        call(M, "open with block", use, "opened", 1, &a1);
        call(M, "now class", use, "now_class");
        call(M, "now year class", use, "now_year_class");
        call(M, "now with an argument", use, "now_arg");
        call(M, "exist without argument", use, "exist_noarg_message");
        call(M, "exist with two arguments", use, "exist_two_message", 2, two);
        mrb_value str = s(M, "x");
        call(M, "sin of a string", use, "sin_type_message", 1, &str);
        call(M, "method_missing on the class", use, "missing_thing");
        call(M, "sysopen of a missing file", use, "pipe_name", 1, &a2);
        mrb_value probe = mrb_obj_new(M, mrb_class_get_under(M, mrb_module_get(M, "NsScope"), "Probe"), 0, nullptr);
        call(M, "scoped exist (NoMethodError)", probe, "exist", 1, &a1);
        return 0;
      }
    CPP
  end
  owners = %w[NsUse NsScope::Probe]
  runs = {
    'base' => '',
    'base after a runtime private' => "class << File; private :basename; end",
    'base after a runtime redefinition' => "def File.exist?(p); :runtime_mine; end",
    'base after a runtime prepend' => "module NsLate; def basename(*a); :late; end; end; class << File; prepend NsLate; end"
  }
  only_runs = ENV['NS_RUNS']&.split(',')&.map(&:strip)
  runs.each do |label, runtime_ruby|
    next if only_runs && !only_runs.include?(label)

    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(BASE + WORLDS.fetch('base')[:extra], dir, only_owners: owners, build_gems: TIME_GEM)
      built, output = runtime.run(dir, err, owners, scenario.call(runtime_ruby), build: full, full: true)
      check.call("#{label}: the fixture compiles and runs against real mruby", built)
      puts output unless built
      next unless built

      sections = runtime.sections(output)
      values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
      interpreted = values.call('interpreted')
      compiled = values.call('compiled')
      check.call("#{label}: the compiled calls answer what the interpreter answers",
                 !interpreted.empty? && interpreted == compiled)
      puts (interpreted - compiled + compiled - interpreted).first(6) unless interpreted == compiled
      puts output if ENV['BC2CPP_CHECK_VERBOSE']
      next unless runtime_ruby.empty?

      # A bound site makes no by-name dispatch when it runs; a kept one does.
      dispatches = sections.fetch('compiled', []).each_cons(2).to_h do |line, next_line|
        [line[/\A(.*?) =>/, 1], next_line[/dispatches=(\d+)/, 1]&.to_i]
      end.compact
      %w[exist\ real exist\ missing base base\ with\ extension sin].each do |label_|
        check.call("compiled `#{label_}` runs its native function without a by-name dispatch", dispatches[label_] == 0)
      end
      %w[cos file\ real].each do |label_|
        check.call("compiled `#{label_}` (kept) still dispatches by name", dispatches[label_].to_i.positive?)
      end
    end
  end
  FileUtils.rm_rf(scratch)
end

puts(failures.empty? ? 'bc2cpp_native_singleton_check OK' : "FAILED: #{failures.size}")
exit(failures.empty? ? 0 : 1)
