#!/usr/bin/env ruby
# encoding: UTF-8
# Executable check for the RData ivar-slot descriptor (ADR 0232): compile a tiny
# closed world with bc2cpp, link it against a real patched mruby and run it
# under GC pressure plus interpreted reflection. A typed embedded ivar is a raw
# C field; if the descriptor listed one, mrb_gc_mark or mrb_iv_get would read a
# raw integer as an object pointer and segfault.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/rdata_slot_native_check.rb
# Env:
#   RDATA_SLOT_MRUBY_SRC     the mruby source tree, already patched by the build's
#                            patch chain (default 3rd/mruby)
#   BC2CPP_RB                override the compiler (default tools/bc2cpp/bc2cpp.rb)
#   RDATA_SLOT_MRUBY_BUILD   a built patched mruby tree with C++ exceptions, to
#                            skip building one (must hold build/host/lib)
#   RDATA_SLOT_GC_STRESS=1   build mruby with MRB_GC_STRESS (full GC per allocation)
#   RDATA_SLOT_KEEP=dir      keep the generated sources and binary there

require 'fileutils'
require 'etc'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
require File.join(ROOT, 'tools/bc2cpp/compiled_gems')

MRBC = ENV.fetch('MRBC')
CORE = File.expand_path(ENV.fetch('RDATA_SLOT_MRUBY_SRC', File.join(ROOT, '3rd/mruby')))
BC2CPP = ENV['BC2CPP_RB'] || File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
STRESS = ENV['RDATA_SLOT_GC_STRESS'] == '1'

FIXTURE = <<~'RUBY'
  # Typed (Integer, bool, Symbol) and :value (String, Array) ivars in one payload.
  class Mixed
    def initialize(seed)
      @count = 0
      @flag = false
      @on = false
      @tag = :fresh
      @name = "n#{seed}"
      @items = []
    end

    def step
      @count = @count + 1
      @flag = true
      @on = !@on
      @tag = :stepped
      @items << @count if @count % 3 == 0
      self
    end

    def count; @count; end
    def on?; @on; end
    def flag?; @flag; end
    def tag; @tag; end
    def name; @name; end
    def item_count; @items.size; end
    def label; "#{@name}/#{@count}/#{@on}/#{@tag}/#{@items.size}/#{@flag}"; end
  end

  # Only typed ivars: the descriptor has no slot to mark at all.
  class Counter
    def initialize
      @hits = 0
      @armed = true
    end

    def hit; @hits = @hits + 1; end
    def hits; @hits; end
    def armed?; @armed; end
  end

  # @ticks is touched by a method bc2cpp refuses (Fiber.new with a block), so it
  # must be a boxed :value slot; @beats stays typed.
  class Demoted
    def initialize
      @ticks = 0
      @beats = 0
    end

    def beat; @beats = @beats + 1; end
    def beats; @beats; end
    def ticks; @ticks; end

    def spin
      f = Fiber.new do
        @ticks = @ticks + 1
        Fiber.yield
      end
      f.resume
      @ticks
    end
  end
RUBY

# Reflection and GC: nothing here may crash, and every compiled read must see
# what the compiled writes stored.
DRIVER = <<~'RUBY'
  $failures = []
  def check(what, ok)
    puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
    $failures << what unless ok
  end

  # Eight steps: a raw 8 has no immediate tag bits, so a typed field misread as an
  # mrb_value is a wild object pointer (a raw 4 would pass as an immediate).
  puts '-- GC churn over compiled objects'
  live = []
  3000.times do |i|
    m = Mixed.new(i)
    8.times { m.step }
    Counter.new.hit
    live << m if i % 25 == 0
    GC.start if i % 250 == 0
  end
  GC.start
  check('surviving Mixed objects keep every ivar',
        live.each_with_index.all? { |m, k| m.label == "n#{k * 25}/8/false/stepped/2/true" })

  puts '-- old-generation object written after a full GC (write barrier)'
  old = Mixed.new(1)
  GC.start
  GC.start
  8.times { old.step }
  fresh = []
  500.times { fresh << "s#{fresh.size}" }
  GC.start
  check('a String stored in a :value slot of an old object survives', old.item_count == 2 && old.name == 'n1' && old.label == 'n1/8/false/stepped/2/true')

  puts '-- interpreted reflection'
  m = Mixed.new(6)
  m.step
  check('instance_variable_get reads a :value slot', m.instance_variable_get(:@name) == 'n6')
  check('instance_variable_defined? for a :value slot', m.instance_variable_defined?(:@items))
  names = m.instance_variables
  check('instance_variables lists the :value slots', names.include?(:@name) && names.include?(:@items))
  check('inspect does not crash', m.inspect.is_a?(String))
  GC.start
  check('reflection left the compiled reads intact', m.label == 'n6/1/true/stepped/0/true')
  m.instance_variable_set(:@name, 'renamed')
  check('instance_variable_set writes the :value slot compiled code reads', m.name == 'renamed')

  check('remove_instance_variable empties the :value slot', m.remove_instance_variable(:@name) == 'renamed')
  check('a removed slot reads nil and drops out of instance_variables',
        m.name.nil? && !m.instance_variables.include?(:@name))
  m.instance_variable_set(:@name, 'renamed')

  puts '-- dup / clone copy the whole payload'
  d = m.dup
  c = m.clone
  d.step
  check('dup copies typed and :value ivars', d.label == 'renamed/2/false/stepped/0/true')
  check('the original is unchanged by stepping the dup', m.label == 'renamed/1/true/stepped/0/true')
  check('clone copies the payload', c.label == m.label)
  GC.start
  check('dup and clone survive a GC', d.count == 2 && c.count == 1 && c.name == 'renamed')

  puts '-- typed-only owner'
  k = Counter.new
  8.times { k.hit }
  GC.start
  check('typed-only counter survives GC', k.hits == 8)
  check('typed-only bool survives GC', k.armed? == true)
  check('typed-only instance_variables does not crash', k.instance_variables.is_a?(Array))
  check('typed-only inspect does not crash', k.inspect.is_a?(String))
  check('typed-only dup keeps the raw fields', k.dup.hits == 8)

  puts '-- an ivar touched by an interpreted method is a boxed slot'
  dm = Demoted.new
  dm.beat
  check('spin runs interpreted', dm.spin == 1 && dm.spin == 2)
  GC.start
  check('the compiled reader sees the interpreted write', dm.ticks == 2)
  check('instance_variable_get reads the demoted slot', dm.instance_variable_get(:@ticks) == 2)
  check('the still-typed ivar is intact', dm.beats == 1)

  puts '-- a descriptor-bearing object with no payload (data == NULL)'
  hollow = NullPayload.make(200)
  GC.start
  check('GC marks NULL-payload objects without dereferencing them', hollow.size == 200)
  check('reflection on a NULL payload does not crash',
        hollow[0].instance_variables == [] && !hollow[0].instance_variable_defined?(:@name) &&
        hollow[0].instance_variable_get(:@name).nil? && hollow[0].inspect.is_a?(String))
  check('dup of a NULL payload does not crash', hollow[0].dup.instance_variables == [])

  puts '-- objects whose payload was never initialised'
  shells = Array.new(200) { Mixed.allocate }
  GC.start
  check('GC over allocate-only shells does not crash', shells.size == 200)
  check('reflection on a shell does not crash', shells[0].instance_variables.is_a?(Array) && shells[0].inspect.is_a?(String))
  check('dup of a shell does not crash', shells[0].dup.instance_variables.is_a?(Array))

  raise "#{$failures.size} check(s) failed" unless $failures.empty?
  puts 'driver ok'
RUBY

# String#[-n..] is nil for a string shorter than n, which would hide the message.
def tail_of(text, limit = 6000)
  text.length > limit ? text[-limit..] : text
end

def run(*cmd, env: {}, chdir: nil)
  opts = chdir ? { chdir: chdir } : {}
  out, status = Open3.capture2e(env, *cmd, **opts)
  [out, status]
end

def build_mruby(dir)
  return ENV['RDATA_SLOT_MRUBY_BUILD'] if ENV['RDATA_SLOT_MRUBY_BUILD']

  tree = File.join(dir, 'mruby')
  FileUtils.mkdir_p(tree)
  (Dir.children(CORE) - %w[build .git]).each { |entry| FileUtils.cp_r(File.join(CORE, entry), tree) }
  config = File.join(dir, 'mruby_build_config.rb')
  File.write(config, <<~RUBY)
    MRuby::Build.new('host') do
      toolchain :gcc
      gembox 'full-core'
      enable_cxx_exception
      enable_debug
      #{"cc.defines << 'MRB_GC_STRESS'\n      cxx.defines << 'MRB_GC_STRESS'" if STRESS}
    end
  RUBY
  out, status = run('rake', "-j#{Etc.nprocessors}", env: { 'MRUBY_CONFIG' => config }, chdir: tree)
  abort "mruby build failed:\n#{tail_of(out)}" unless status.success?
  tree
end

def section(text, header)
  start = text.index("== #{header} ==")
  return [] unless start

  rest = text[start..]
  stop = rest.index("\n==", 1)
  (stop ? rest[0...stop] : rest).lines.drop(1).map(&:strip).reject(&:empty?)
end

Dir.mktmpdir('rdata_slot_native') do |tmp|
  fixture = File.join(tmp, 'fixture.rb')
  File.write(fixture, FIXTURE)
  out_dir = File.join(tmp, 'gen')
  FileUtils.mkdir_p(out_dir)

  native = core_native_srcs(CORE)
  foreign = Dir[File.join(CORE, 'mrblib/**/*.rb')] + Dir[File.join(CORE, 'mrbgems/*/mrblib/**/*.rb')]
  env = {
    'MRBC' => MRBC, 'OUT_SYMBOL' => 'rdata_slot', 'OUT_DIR' => out_dir,
    'NATIVE_SRCS' => Shellwords.join(native), 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign),
    'SKIP_UNSUPPORTED' => '1', 'BC2CPP_SELF_REGISTERING' => '1'
  }
  cpp, diagnostics, status = Open3.capture3(env, RbConfig.ruby, BC2CPP, fixture)
  abort "bc2cpp failed:\n#{tail_of(diagnostics)}" unless status.success?
  File.write(File.join(out_dir, 'rdata_slot_gen.cpp'), cpp)

  embeds = section(diagnostics, 'classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)')
  abort "fixture: expected Mixed/Counter/Demoted to embed, got #{embeds.inspect}" unless
    %w[Mixed Counter Demoted].all? { |c| embeds.include?(c) }

  entries = section(diagnostics, 'compiled entry points').filter_map do |line|
    m = line.match(/^\s*(\S+) \/ \S+\s+\(([^#]+)#([^,]+), arity \d+\)(.*)$/)
    next unless m && embeds.include?(m[2])

    m.captures
  end
  register = +"#include <mruby.h>\n#include <mruby/compile.h>\n#include <mruby/error.h>\n#include <mruby/array.h>\n#include <mruby/data.h>\n#include <cstdio>\n"
  register << "#include \"rdata_slot_decls.h\"\n#include \"rdata_slot_gen.cpp\"\n"
  register << "static const char* const kFixture = R\"FIXTURE(#{FIXTURE})FIXTURE\";\n"
  register << "static const char* const kDriver = R\"DRIVER(#{DRIVER})DRIVER\";\n"
  # A descriptor-bearing type with data == NULL: what mrb_data_object_alloc(NULL)
  # or an interrupted mrb_iv_copy leaves behind, and what GC marking must skip.
  register << <<~CPP
    static mrb_value null_payloads(mrb_state* M, mrb_value) {
      mrb_int n;
      mrb_get_args(M, "i", &n);
      mrb_value ary = mrb_ary_new(M);
      int ai = mrb_gc_arena_save(M);
      for (mrb_int i = 0; i < n; ++i) {
        RClass* c = mrb_class_get(M, "Mixed");
        mrb_ary_push(M, ary, mrb_obj_value(mrb_data_object_alloc(M, c, nullptr, &Mixed_ivars_type)));
        mrb_gc_arena_restore(M, ai);
      }
      return ary;
    }
  CPP
  register << "static void install(mrb_state* M) {\n"
  register << "  mrb_define_module_function(M, mrb_define_module(M, \"NullPayload\"), \"make\", null_payloads, " \
              "MRB_ARGS_REQ(1));\n"
  embeds.each { |c| register << "  MRB_SET_INSTANCE_TT(mrb_class_get(M, #{c.dump}), MRB_TT_DATA);\n" }
  entries.each do |entry, owner, name, extra|
    definer = extra.include?('[private') ? 'mrb_define_private_method' : 'mrb_define_method'
    register << "  #{definer}(M, mrb_class_get(M, #{owner.dump}), #{name.dump}, #{entry}, MRB_ARGS_ANY());\n"
  end
  register << "}\n"
  register << <<~CPP
    static int run(mrb_state* M, const char* src) {
      mrb_load_string(M, src);
      if (M->exc) { mrb_print_error(M); return 1; }
      return 0;
    }
    int main() {
      mrb_state* M = mrb_open();
      if (!M) return 2;
      int rc = run(M, kFixture);
      if (rc == 0) { install(M); rc = run(M, kDriver); }
      mrb_close(M);
      return rc;
    }
  CPP
  File.write(File.join(out_dir, 'main.cxx'), register)

  if (keep = ENV['RDATA_SLOT_KEEP'])
    FileUtils.mkdir_p(keep)
    FileUtils.cp_r(Dir[File.join(out_dir, '*')], keep)
  end
  tree = build_mruby(tmp)
  lib_dir = File.join(tree, 'build/host')
  flags, = run(File.join(lib_dir, 'bin/mruby-config'), '--cxxflags')
  binary = File.join(tmp, 'rdata_slot_check')
  cxx = ENV['CXX'] || 'g++'
  out, status = run(cxx, '-std=c++17', '-O1', '-g', *Shellwords.split(flags.gsub('-O3', '').gsub('-O0', '')),
                    '-I', File.join(ROOT, 'include'), '-I', out_dir,
                    File.join(out_dir, 'main.cxx'), '-o', binary,
                    "-L#{File.join(lib_dir, 'lib')}", '-lmruby', '-lm')
  abort "compiling the generated code failed:\n#{tail_of(out)}" unless status.success?

  puts "bc2cpp installed #{entries.size} compiled methods on #{embeds.join(', ')}"
  out, status = run(binary)
  puts out
  unless status.success?
    why = status.signaled? ? "signal #{status.termsig}" : "exit #{status.exitstatus}"
    abort "FAIL: the compiled fixture died (#{why})"
  end
end
puts 'ok'
