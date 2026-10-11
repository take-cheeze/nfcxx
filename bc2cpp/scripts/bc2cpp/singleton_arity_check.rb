#!/usr/bin/env ruby
# encoding: UTF-8
# Checks the singleton-method and arity call resolution of docs/adr/0259 on a
# closed-world build:
#
#   - `Const.name(...)` on a stable class/module constant calls the singleton
#     definition mruby's lookup finds, including one inherited from a superclass
#     constant, an `attr_accessor` of `class << self`, and a definition with
#     optional parameters (padded like every direct call);
#   - an implicit-self call in a `def self.x` of a declared module is a direct
#     call (the closed-world counterpart of SINGLETON_LEXICAL_SELF), until
#     something spells `clone`;
#   - a send that provably reaches a plain-signature definition with the wrong
#     argument count raises mruby's own ArgumentError statically
#     (STATIC_ARGC_ERROR), including in the exact-class arms next to a chain;
#   - an optional-parameter definition joins a POLY chain;
#   - every refusal keeps dispatch: a singleton mixin in the way, a superclass
#     the closed world cannot name, a private singleton method, a rest
#     parameter, and a `clone` anywhere;
#   - compiled against the real mruby core, each case returns (or raises) what
#     the interpreter does. Needs BC2CPP_MRUBY_CORE (libmruby_core.a + include/)
#     and g++; skipped without them.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=build/mruby/host/mrbc] \
#          ruby scripts/bc2cpp/singleton_arity_check.rb
# SA_DUMP=SaCaller_kid,... prints those generated bodies instead of checking.

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative 'cxx'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

core_gems = %w[mruby-array-ext mruby-hash-ext mruby-enum-ext mruby-io mruby-numeric-ext mruby-range-ext mruby-fiber
               mruby-exit mruby-sprintf mruby-time mruby-bigint mruby-pack mruby-string-ext mruby-struct
               mruby-metaprog mruby-enumerator]
wio_gems = core_gems.to_h { |g| [g, "#{root}/3rd/mruby/mrbgems/#{g}"] }
wio_gems.merge!('hal-wio-io' => "#{root}/app/wio/hal-wio-io", 'mruby-math-wio' => "#{root}/app/wio/mruby-math-wio",
                'mruby-stringio' => "#{root}/3rd/mruby-stringio", 'mruby-marshal' => "#{root}/3rd/mruby-marshal")
%w[mruby-lcf mruby-lcf-compiled mruby-rgss mruby-rgss-compiled mruby-rpg2k mruby-rpg2k-compiled].each do |g|
  wio_gems[g] = "#{root}/#{g}"
end

WORLD = <<~'RUBY'
  module SaMod
    def self.twice(x); x * 2; end
    def self.quad(x); twice(twice(x)); end
    def self.pick(a, b = 10); a + b; end
    def self.pair(a, b); a - b; end
    def self.rest(a, *r); a; end
    class << self
      attr_accessor :level
      private
      def hidden(x); x; end
    end
    def self.lvl; level; end
  end
  class SaBase
    def self.make(x); x + 1; end
    def self.opt(a, b = 5); a * b; end
  end
  class SaKid < SaBase; end
  class SaOver < SaBase
    def self.make(x); x + 100; end
  end
  class SaCaller
    def kid; SaKid.make(1); end
    def over; SaOver.make(1); end
    def opt_default; SaBase.opt(3); end
    def opt_full; SaBase.opt(3, 4); end
    def mod_opt; SaMod.pick(1); end
    def pick_bad; SaMod.pick(1, 2, 3); end
    def quad; SaMod.quad(3); end
    def bad_pair; SaMod.pair(1); end
    def good_pair; SaMod.pair(5, 2); end
    def too_many; SaBase.make(1, 2); end
    def level; SaMod.level = 7; SaMod.level; end
    def lvl; SaMod.level = 9; SaMod.lvl; end
    def kept_hidden; SaMod.hidden(1); end
    def kept_rest; SaMod.rest(1, 2, 3); end
  end
  # Same-named instance methods keep every name off the unique-definition (MONO) path.
  class SaNoise
    def twice(x); x; end
    def level; 0; end
    def level=(v); v; end
    def hidden(x); x; end
    def pair(a); a; end
    def pick(a); a; end
    def opt(a); a; end
    def make(a); a; end
    def rest(a); a; end
  end
  class SaAlpha; def price(a); a; end; end
  class SaBeta; def price; 1; end; end
  class SaGamma; def price(a, b = 2); a + b; end; end
  class SaProbe
    def call_price(x); x.price(1); end
  end
RUBY

CLONE_WORLD = <<~'RUBY'
  module SaMod
    def self.twice(x); x * 2; end
    def self.quad(x); twice(twice(x)); end
  end
  class SaCopy
    def copy; SaMod.clone; end
  end
RUBY

MIXIN_WORLD = <<~'RUBY'
  module SaHook
    def make(x); x - 1; end
  end
  class SaBase
    class << self
      prepend SaHook
    end
    def self.make(x); x + 1; end
  end
  class SaKid < SaBase; end
  class SaOpaque < Struct.new(:a); end
  class SaCaller
    def own; SaBase.make(1); end
    def kid; SaKid.make(1); end
    def opaque; SaOpaque.make(1); end
  end
RUBY

generate = lambda do |source, name|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    env = { 'MRBC' => ENV['MRBC'] || 'mrbc', 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
            'BC2CPP_BUILD_GEMS' => Shellwords.join(wio_gems.map { |n, d| "#{n}=#{d}" }),
            NomethodReviewed::ALLOW_ENV => 'allow' }
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), path)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
    out
  end
end
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

code = generate.call(WORLD, 'sa_world')
if ENV['SA_DUMP'] # SA_DUMP=SaCaller_kid,SaMod_singleton_quad prints those compiled bodies and stops
  ENV['SA_DUMP'].split(',').each { |fn| puts "==== #{fn}", body_of.call(code, fn) }
  exit
end

puts '-- constant receivers'
kid = body_of.call(code, 'SaCaller_kid')
check.call('a subclass constant calls the singleton method it inherits',
           kid.include?('CLOSED_WORLD_CONSTANT_OBJECT :make -> SaBase.singleton#make') &&
             kid.include?('inherited from SaBase') && kid.match?(/SaBase_singleton_make_impl\(M, r\d+, r\d+\)/) &&
             !kid.include?('bc2cpp_send('))
over = body_of.call(code, 'SaCaller_over')
check.call('an overriding singleton method wins over the inherited one',
           over.include?('SaOver.singleton#make') && !over.include?('inherited from') && !over.include?('bc2cpp_send('))
opt_default = body_of.call(code, 'SaCaller_opt_default')
opt_full = body_of.call(code, 'SaCaller_opt_full')
check.call('an omitted optional argument is padded, with the given-optional count',
           opt_default.match?(/SaBase_singleton_opt_impl\(M, r\d+, r\d+, mrb_nil_value\(\), 0\)/) &&
             opt_full.match?(/SaBase_singleton_opt_impl\(M, r\d+, r\d+, r\d+, 1\)/) &&
             !opt_default.include?('bc2cpp_send(') && !opt_full.include?('bc2cpp_send('))
check.call('a module singleton method with an optional parameter is a direct call',
           body_of.call(code, 'SaCaller_mod_opt').match?(/SaMod_singleton_pick_impl\(M, r\d+, r\d+, mrb_nil_value\(\), 0\)/))
level = body_of.call(code, 'SaCaller_level')
check.call('an attr_accessor of `class << self` is a bare ivar access on the constant',
           level.include?('singleton attr accessor') && level.include?('mrb_iv_set(') && level.include?('mrb_iv_get(') &&
             !level.include?('bc2cpp_send('))
check.call('a private singleton method keeps dispatch (NoMethodError)', body_of.call(code, 'SaCaller_kept_hidden').include?('bc2cpp_send('))
check.call('a rest parameter raises no static argument error (dispatched, or a direct call that builds the rest Array, ADR 0265)',
           (body_of.call(code, 'SaCaller_kept_rest').include?('bc2cpp_send(') ||
             body_of.call(code, 'SaCaller_kept_rest').include?('mrb_ary_new_from_values(')) &&
             !body_of.call(code, 'SaCaller_kept_rest').include?('STATIC_ARGC_ERROR'))

puts '-- self in a module singleton method'
check.call('an implicit-self call in a module `def self.x` is a direct call',
           body_of.call(code, 'SaMod_singleton_quad').match?(/LEXICAL_SELF :twice -> SaMod\.singleton#twice.*\n\s+r\d+ = SaMod_singleton_twice_impl\(M, self, /) &&
             !body_of.call(code, 'SaMod_singleton_quad').include?('bc2cpp_send('))
check.call('an implicit-self singleton accessor is a direct ivar read',
           body_of.call(code, 'SaMod_singleton_lvl').include?('LEXICAL_SELF_IVAR_ACCESSOR :level') &&
             !body_of.call(code, 'SaMod_singleton_lvl').include?('bc2cpp_send('))
clone_code = generate.call(CLONE_WORLD, 'sa_clone')
check.call('a `clone` anywhere in the closed world keeps the self call dynamic (a clone runs the copied singleton with another self)',
           !body_of.call(clone_code, 'SaMod_singleton_quad').include?('LEXICAL_SELF'))

puts '-- static ArgumentError'
bad = body_of.call(code, 'SaCaller_bad_pair')
check.call('too few arguments to a plain signature raise ArgumentError without dispatch',
           bad.include?('STATIC_ARGC_ERROR :pair') && bad.include?('mrb_argnum_error(M, 1, 2, 2)') &&
             !bad.include?('SaMod_singleton_pair_impl') && !bad.include?('bc2cpp_send('))
too_many = body_of.call(code, 'SaCaller_too_many')
check.call('too many arguments do the same, through the inherited singleton method',
           too_many.include?('mrb_argnum_error(M, 2, 1, 1)') && !too_many.include?('bc2cpp_send('))
check.call('the right count still calls', body_of.call(code, 'SaCaller_good_pair').match?(/SaMod_singleton_pair_impl\(M, r\d+, r\d+, r\d+\)/))

pick_bad = body_of.call(code, 'SaCaller_pick_bad')
check.call('an optional-parameter callee reports the mandatory count only, as its ENTER does',
           pick_bad.include?('mrb_argnum_error(M, 3, 1, 1)') && !pick_bad.include?('bc2cpp_send('))

puts '-- chains'
price = body_of.call(code, 'SaProbe_call_price')
check.call('an optional-parameter definition joins the chain, padded',
           price.include?('POLY_SMALL_N :price -> SaAlpha, SaGamma') &&
             price.match?(/SaGamma_price_impl\(M, r\d+, r\d+, mrb_nil_value\(\), 0\)/))
check.call('the class whose definition rejects the argument count raises statically in its own arm; the else is nomethod',
           price.include?('STATIC_ARGC_ERROR :price -> SaBeta#price') && price.include?('mrb_argnum_error(M, 1, 0, 0)') &&
             price.match?(/\} else \{\n\s+r\d+ = bc2cpp_nomethod\(M, r\d+, \d+, 1, r\d+\);/) && !price.include?('bc2cpp_send('))

puts '-- refusals'
mixin_code = generate.call(MIXIN_WORLD, 'sa_mixin')
check.call('a prepend onto a singleton keeps every constant call dynamic',
           %w[own kid].all? { |m| body_of.call(mixin_code, "SaCaller_#{m}").then { |b| b.include?('bc2cpp_send(') && !b.include?('CONSTANT_OBJECT') } })
check.call('a superclass the closed world cannot name keeps dispatch',
           body_of.call(mixin_code, 'SaCaller_opaque').then { |b| b.include?('bc2cpp_send(') && !b.include?('CONSTANT_OBJECT') })

puts '-- run against the real mruby core'
candidates = [ENV['BC2CPP_MRUBY_CORE']].compact + Dir[File.join(root, 'build*/mruby/host/mrbc')]
core = candidates.find { |d| File.exist?(File.join(d, 'lib/libmruby_core.a')) && File.directory?(File.join(d, 'include')) }
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP behavioural comparison: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  driver = <<~'RUBY'
    def sa_try(obj, meth, *args)
      obj.__send__(meth, *args)
    rescue ArgumentError => e
      [e.class, e.message]
    end
    def sa_run
      c = SaCaller.new
      [sa_try(c, :kid), sa_try(c, :over), sa_try(c, :opt_default), sa_try(c, :opt_full), sa_try(c, :mod_opt),
       sa_try(c, :quad), sa_try(c, :bad_pair), sa_try(c, :good_pair), sa_try(c, :too_many), sa_try(c, :level),
       sa_try(c, :pick_bad), sa_try(c, :lvl), sa_try(SaProbe.new, :call_price, SaAlpha.new), sa_try(SaProbe.new, :call_price, SaGamma.new),
       sa_try(SaProbe.new, :call_price, SaBeta.new)]
    end
    $interp = sa_run
  RUBY
  after = 'load(M, "$comp = sa_run; $same = ($interp == $comp)");'
  methods = %w[kid over opt_default opt_full mod_opt pick_bad quad bad_pair good_pair too_many level lvl]
  defines = methods.map do |m|
    "mrb_define_method(M, mrb_class_get(M, \"SaCaller\"), \"#{m}\", SaCaller_#{m}, MRB_ARGS_NONE());"
  end
  defines << 'mrb_define_method(M, mrb_class_get(M, "SaProbe"), "call_price", SaProbe_call_price, MRB_ARGS_REQ(1));'
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'gen.cpp'), code)
    File.write(File.join(dir, 'harness.cpp'), <<~CPP)
      #include "gen.cpp"
      #include <mruby/compile.h>
      #include <cstdio>
      #include <cstdlib>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      static const char* str(mrb_state* M, mrb_value v) { return mrb_str_to_cstr(M, mrb_inspect(M, v)); }
      static void load(mrb_state* M, const char* ruby) {
        mrb_load_string(M, ruby);
        if (M->exc) { std::printf("uncaught %s\\n", str(M, mrb_obj_value(M->exc))); std::exit(1); }
      }
      int main() {
        mrb_state* M = mrb_open_core();
        load(M, #{File.read(File.join(root, '3rd/mruby/mrblib/10error.rb')).inspect});
        load(M, #{WORLD.inspect});
        load(M, #{driver.inspect});
        #{defines.join("\n  ")}
        #{after}
        std::printf("interpreted %s\\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$interp"))));
        std::printf("compiled    %s\\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$comp"))));
        std::printf("same %s\\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$same"))));
        mrb_close(M);
        return 0;
      }
    CPP
    binary = File.join(dir, 'harness')
    built = Bc2cppCxx.system('-std=c++17', '-w', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS',
                   "-I#{dir}", "-I#{core}/include", "-I#{root}/3rd/mruby/include", File.join(dir, 'harness.cpp'),
                   "#{core}/lib/libmruby_core.a", '-o', binary)
    output = built ? IO.popen(binary, err: %i[child out], &:read) : nil
    check.call('the generated code compiles and runs against the real mruby core', !output.nil?)
    if output
      puts output.lines.map { |l| "  #{l}" }.join
      check.call('every compiled case returns, or raises, exactly what the interpreter does', output.include?('same true'))
      check.call('the ArgumentError messages are mruby\'s own',
                 output.include?('wrong number of arguments (given 1, expected 2)') &&
                   output.include?('wrong number of arguments (given 2, expected 1)') &&
                   output.include?('wrong number of arguments (given 3, expected 1)'))
    end
  end
end

if failures.empty?
  puts 'bc2cpp singleton/arity check: PASS'
else
  warn "bc2cpp singleton/arity check: #{failures.size} failure(s)"
  exit 1
end
