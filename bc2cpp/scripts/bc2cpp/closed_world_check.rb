#!/usr/bin/env ruby
# encoding: UTF-8
# Check CLOSED_WORLD (docs/adr/0210): on a single-format build a guard chain
# that provably lists every class answering a name ends in bc2cpp_nomethod
# instead of a by-name dispatch, and that raises exactly what the dispatch did.
#
#   - the build check refuses an open gem set, a non-single-format build and a
#     host that compiles a non-literal Ruby source; build_config.rb enables the
#     mode for the single-format builds only;
#   - generated code: a complete chain ends in bc2cpp_nomethod; an incomplete
#     chain, a core-defined name and a receiver that may be a method_missing
#     class keep the dispatch; without the switch nothing changes;
#   - run against the real mruby core: nil and a wrong-class receiver raise the
#     same NoMethodError (class, message, name, args) as the interpreter, and
#     `rescue` catches it; the kept sites still reach method_missing and
#     inherited methods.

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'cxx'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The wio build's gem list (build_config.rb plus the gems it depends on).
core_gems = %w[mruby-array-ext mruby-hash-ext mruby-enum-ext mruby-io mruby-numeric-ext mruby-range-ext mruby-fiber
               mruby-exit mruby-sprintf mruby-time mruby-bigint mruby-pack mruby-string-ext mruby-struct
               mruby-metaprog mruby-enumerator]
wio_gems = core_gems.to_h { |g| [g, "#{root}/3rd/mruby/mrbgems/#{g}"] }
wio_gems.merge!('hal-wio-io' => "#{root}/app/wio/hal-wio-io", 'mruby-math-wio' => "#{root}/app/wio/mruby-math-wio",
                'mruby-stringio' => "#{root}/3rd/mruby-stringio", 'mruby-marshal' => "#{root}/3rd/mruby-marshal")
%w[mruby-lcf mruby-lcf-compiled mruby-rgss mruby-rgss-compiled mruby-rpg2k mruby-rpg2k-compiled
   mruby-core-compiled].each do |g|
  wio_gems[g] = "#{root}/#{g}"
end

# -- the build check ------------------------------------------------------------

check.call('the wio gem set is a closed world', bc2cpp_closed_world_violations('wio', wio_gems, root).empty?)
check.call('maix, with mruby-compiler, is one: its host only evaluates the literal probe',
           bc2cpp_closed_world_violations('maix', wio_gems.merge('mruby-compiler' => 'x'), root).empty?)
{ 'mruby-eval' => 'mruby-eval', 'mruby-rpgxp' => 'an RGSS script host', 'mruby-mvjs' => 'mruby-mvjs' }.each do |gem, what|
  errors = bc2cpp_closed_world_violations('wio', wio_gems.merge(gem => 'x'), root)
  check.call("a build with #{what} is refused", errors.any? { |e| e.include?(gem) })
end
check.call('a desktop build is refused', !bc2cpp_closed_world_violations('host', wio_gems, root).empty?)
check.call('a gem list without the closed-world gems is refused',
           !bc2cpp_closed_world_violations('wio', wio_gems.except('mruby-rpg2k'), root).empty?)
Dir.mktmpdir do |dir|
  host = File.join(dir, 'main.cxx')
  File.write(host, "constexpr char kOk[] = \"\\\"alive\\\"\";\nvoid f(mrb_state* M, const char* s) {\n" \
                   "  mrb_load_string(M, kOk);\n  mrb_load_string(M, s);\n}\n")
  errors = bc2cpp_closed_world_violations('maix', wio_gems.merge('mruby-compiler' => 'x'), root, host_srcs: [host])
  check.call('with mruby-compiler, a host compiling a runtime string is refused (and only that call)',
             errors.size == 1 && errors.first.include?('(s)'))
  File.write(host, "constexpr char kDef[] = \"def x; end\";\nvoid f(mrb_state* M) { mrb_load_string(M, kDef); }\n")
  errors = bc2cpp_closed_world_violations('maix', wio_gems.merge('mruby-compiler' => 'x'), root, host_srcs: [host])
  check.call('a literal that defines a method is refused too', errors.size == 1)
end

config = File.read(File.join(root, 'build_config.rb'), encoding: 'UTF-8')
check.call('build_config.rb enables the mode for single-format builds only',
           config.match?(/closed_world = proc do\n\s+if single_format_only\n\s+enable_bc2cpp_closed_world\n/) &&
             BC2CPP_COMPILED_GEMS.keys.all? { |g| config.include?("#{g}\", &closed_world if bc2cpp") })
check.call('every compiled gem passes the mode through the checked env',
           BC2CPP_COMPILED_GEMS.keys.all? do |g|
             rake = File.read(File.join(root, g, 'mrbgem.rake'))
             rake.include?('extend Bc2cppClosedWorldOption') && rake.include?('Bc2cppCompiledGemGeneration.generate(spec, ')
           end && File.read(File.join(root, 'tools/bc2cpp/compiled_gems.rb'))[/^def bc2cpp_compiled_gem_job.*?^end$/m]
                      .to_s.include?('.merge(bc2cpp_closed_world_env(spec, '))
spec = Struct.new(:name, :build) { include Bc2cppClosedWorldOption }
build = Struct.new(:name, :gems)
gem_list = ->(gems) { gems.map { |n, d| Struct.new(:name, :dir).new(n, d) } }
open_spec = spec.new('mruby-rpg2k-compiled', build.new('host', gem_list.call(wio_gems)))
check.call('a gem the build did not opt in passes no switch', bc2cpp_closed_world_env(open_spec, root) == {})
wio_spec = spec.new('mruby-rpg2k-compiled', build.new('wio', gem_list.call(wio_gems)))
wio_spec.enable_bc2cpp_closed_world
env = bc2cpp_closed_world_env(wio_spec, root)
check.call('an opted-in wio build passes the switch and its gem list',
           env['BC2CPP_CLOSED_WORLD'] == '1' && env['BC2CPP_BUILD_NAME'] == 'wio' &&
             Shellwords.split(env['BC2CPP_BUILD_GEMS']).include?("mruby-rpg2k=#{File.expand_path(root)}/mruby-rpg2k"))
bad_spec = spec.new('mruby-rpg2k-compiled', build.new('wio', gem_list.call(wio_gems.merge('mruby-eval' => 'x'))))
bad_spec.enable_bc2cpp_closed_world
raised = begin
  bc2cpp_closed_world_env(bad_spec, root)
  false
rescue RuntimeError => e
  e.message.include?('mruby-eval')
end
check.call('an opted-in build that is not closed fails loudly', raised)

# -- generated code -------------------------------------------------------------

# No method_missing class: every chain may be complete.
WORLD = <<~'RUBY'
  class CwPet
    def cw_speak; 1; end
    def cw_fetch(a, b); a + b; end
    def cw_bark; 10; end
    def size; 5; end
  end
  class CwRobot
    def cw_speak; 2; end
    def cw_fetch(a, b); a - b; end
    def size; 6; end
  end
  class CwDog
    def cw_bark; 20; end
  end
  # A mixin on the way keeps INHERITED_GUARD from listing CwPuppy, so the
  # chain does not cover every class that answers cw_bark.
  module CwTrick
  end
  class CwPuppy < CwDog
    include CwTrick
  end
  class CwOther
  end
  class CwCaller
    def talk(x); x.cw_speak; end
    def fetch(x); x.cw_fetch(1, 2); end
    def bark(x); x.cw_bark; end
    def measure(x); x.size; end
  end
RUBY

# SELF_INSTANCE_RECEIVER: a `.singleton` definer cannot answer `self` in an instance method.
SINGLETON_WORLD = <<~'RUBY'
  module CwHolder
    def self.cw_hello; 9; end
  end
  class CwBase
    def cw_hello; 1; end
    def run; cw_hello; end
    def outside(x); x.cw_hello; end
  end
  class CwKid < CwBase
    def cw_hello; 2; end
  end
RUBY

RESPOND_WORLD = <<~'RUBY'
  class CwRespondee
    def cw_known; 1; end
  end
  class CwResponder
    def probe(x); x.respond_to?(:cw_known); end
  end
RUBY
RESPOND_HOOK_WORLD = "#{RESPOND_WORLD}class CwRespondHook\n  def respond_to_missing?(name, include_all = false); true; end\nend\n"

# A method_missing class: only a `self` receiver can be proven not to be one.
GHOST_WORLD = <<~'RUBY'
  class CwGhost
    def method_missing(name, *args); 42; end
  end
  class CwBase
    def cw_speak; 1; end
    def chat; cw_speak; end
  end
  class CwKid < CwBase
    def cw_speak; 3; end
  end
  class CwRobot
    def cw_speak; 2; end
  end
  class CwCaller
    def talk(x); x.cw_speak; end
  end
RUBY

# INHERITED_GUARD lists a plain subclass in the chain, which is then complete.
INHERIT_WORLD = <<~'RUBY'
  class CwWolf
    def cw_howl; 1; end
  end
  class CwWolfPup < CwWolf
  end
  class CwFox
    def cw_howl; 2; end
  end
  class CwCaller
    def howl(x); x.cw_howl; end
  end
RUBY

EXACT_CONSTRUCT_WORLD = <<~'RUBY'
  module CwExact
    class StableFresh
      def exact_value; 1; end
    end
    class Other
      def exact_value; 2; end
    end
    class Caller
      def call; StableFresh.new.exact_value; end
    end
  end

  module CwRebound
    class Fresh
      def exact_value; 3; end
    end
    class Other
      def exact_value; 4; end
    end
    Fresh = Other
    class Caller
      def call; Fresh.new.exact_value; end
    end
  end
RUBY

CONSTANT_OBJECT_WORLD = <<~'RUBY'
  module CwStableObject
    def self.value; 11; end
    def self.echo(x); x; end
  end
  module CwEchoOther
    def self.echo(x); x; end
  end
  module CwNamespace
    module StableObject
      def self.value; 12; end
    end
  end
  module CwOuter
    module StableObject
      def self.value; 13; end
    end
    module CwInner
      module StableObject
        def self.value; 14; end
      end
      class Caller
        def nested_shadow; StableObject.value; end
      end
    end
  end
  module CwQualifiedConstruct
    class Stable
      def initialize; @value = 5; end
    end
    class Caller
      def create; CwQualifiedConstruct::Stable.new; end
      def create_array; Array.new(3); end
      def create_hash; Hash.new(7); end
      def create_range; Range.new(1, 3, true); end
    end
  end
  class CwInstanceMixinConstruct
    include Enumerable
    def initialize; @value = 9; end
  end
  class CwInstanceMixinCaller
    def create; CwInstanceMixinConstruct.new; end
  end
  module CwModuleFunction
    def value(x); x + 3; end
    module_function :value
    def state; @state; end
    module_function :state
  end
  class CwBlockCaller
    def times_value; 3.times { |i| CwModuleFunction.value(i) }; end
  end
  module CwReplacementObject
    def self.value; 22; end
  end
  module CwBranchReplacementObject
    def self.value; 23; end
  end
  class CwValueTypeA
    def value_type_probe; 31; end
  end
  class CwValueTypeB
    def value_type_probe; 32; end
  end
  class CwValueTypeA
    def self.new; CwValueTypeB.allocate; end
  end
  CwValueTypeConstant = CwValueTypeA.new
  class CwStableCaller
    def stable; CwStableObject.value; end
    def after_branch(flag)
      if flag
        marker = 1
      else
        marker = 2
      end
      CwStableObject.value + marker
    end
    def branch_selected(flag)
      receiver = flag ? CwStableObject : CwBranchReplacementObject
      receiver.value
    end
    def block_argument(list); CwStableObject.echo(list.map { |item| item }); end
    def qualified; CwNamespace::StableObject.value; end
    def module_function; CwModuleFunction.value(4); end
    def module_function_state; CwModuleFunction.state; end
    def value_constant_type; CwValueTypeConstant.value_type_probe; end
  end
  class CwReboundCaller
    CwReboundObject = CwReplacementObject
    def rebound; CwReboundObject.value; end
  end
RUBY

mrbc = ENV['MRBC'] || 'mrbc'
generate = lambda do |source, name, closed, only_owners = nil, outside_srcs = nil|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1' }
    env['ONLY_OWNERS'] = only_owners.join(',') if only_owners
    # The real build's native and outside-Ruby sources: what makes core names like
    # respond_to? known natives.
    if outside_srcs
      env['NATIVE_SRCS'] = Shellwords.join(outside_srcs[0])
      env['FOREIGN_RUBY_SRCS'] = Shellwords.join(outside_srcs[1])
    end
    if closed
      env.merge!('BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                 'BC2CPP_BUILD_GEMS' => Shellwords.join(wio_gems.map { |n, d| "#{n}=#{d}" }),
                 # The fixtures' dead sites are the point; NOMETHOD_REVIEWED gates real gems.
                 NomethodReviewed::ALLOW_ENV => 'allow')
    end
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', path)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
    [out, err]
  end
end
# The body of one compiled method, from its _impl definition to the next function.
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

open_code, = generate.call(WORLD, 'cw_open', false)
closed_code, closed_err = generate.call(WORLD, 'cw_closed', true)
ghost_code, ghost_err = generate.call(GHOST_WORLD, 'cw_ghost', true)
inherit_code, = generate.call(INHERIT_WORLD, 'cw_inherit', true)
exact_construct_code, = generate.call(EXACT_CONSTRUCT_WORLD, 'cw_exact_construct', true)
constant_object_code, = generate.call(CONSTANT_OBJECT_WORLD, 'cw_constant_object', true)
selective_constant_object_code, = generate.call(CONSTANT_OBJECT_WORLD, 'cw_constant_object_selective', true,
                                                 %w[CwStableCaller CwModuleFunction.singleton])

check.call('without the switch no fallback changes: no bc2cpp_nomethod, ancestry-aware owner lookup',
           !open_code.include?('bc2cpp_nomethod') && !open_code.include?('CLOSED_WORLD') &&
             body_of.call(open_code, 'CwCaller_talk').include?('bc2cpp_send(') &&
             open_code.include?('if (!mrb_const_defined(M, v, s)) return nullptr;'))
talk = body_of.call(closed_code, 'CwCaller_talk')
check.call('a complete chain (every definer, no subclass, no method_missing) ends in bc2cpp_nomethod',
           talk.include?('POLY_SMALL_N :cw_speak') && talk.match?(/\} else \{\n\s+r\d+ = bc2cpp_nomethod\(M, r\d+, \d+\);/) &&
             !talk.include?('bc2cpp_send('))
check.call('its arguments are passed on (NoMethodError#args)',
           body_of.call(closed_code, 'CwCaller_fetch').match?(/bc2cpp_nomethod\(M, r\d+, \d+, 2, r\d+, r\d+\);/))
bark = body_of.call(closed_code, 'CwCaller_bark')
check.call('a definer class the chain cannot list (CwPuppy, a mixin in the way) gets its own exact-class branch (ADR 0259: a direct call of the inherited definition); the else raises',
           bark.include?('UNLISTED_CLASS_CALL :cw_bark -> CwDog#cw_bark (receiver exactly CwPuppy)') &&
             bark.match?(/\} else \{\n\s+r\d+ = bc2cpp_nomethod\(M, r\d+, \d+\);/) &&
             !bark.include?('bc2cpp_send(') && !bark.include?('kept: unlisted_class'))
check.call('an inheriting subclass the chain lists (INHERITED_GUARD) completes it: bc2cpp_nomethod',
           body_of.call(inherit_code, 'CwCaller_howl').then do |howl|
             howl.include?('INHERITED_GUARD :cw_howl -- also CwWolfPup < CwWolf') &&
               howl.match?(/\} else \{\n\s+r\d+ = bc2cpp_nomethod\(M, r\d+, \d+\);/) && !howl.include?('bc2cpp_send(')
           end)
check.call('a name mruby core defines ends in the call checked against its core owners (ADR 0468), not a dispatch',
           body_of.call(closed_code, 'CwCaller_measure').then do |measure|
             measure.include?('CLOSED_WORLD owner-call: size') && measure.match?(/BC2CPP_OWNERS\([^)]*"Array"[^)]*"String"/) &&
               !measure.include?('bc2cpp_send(') && !measure.include?('CLOSED_WORLD kept:')
           end)
check.call('the guard names exactly the registry class (no lookup through ancestry)',
           closed_code.include?('if (!mrb_const_defined_at(M, v, s)) return nullptr;'))
check.call('the summary counts what was converted and why the rest was kept',
           closed_err.include?('== closed world fallbacks: 0 guards dropped, 3 bc2cpp_nomethod, 0 kept dispatching ==') &&
             !closed_err.include?('KEPT unlisted_class') && !closed_err.include?('KEPT core_or_native') &&
             closed_err.include?('OWNER_CALL: 1'))
check.call('a receiver that may be a method_missing instance keeps the dispatch',
           ghost_err.include?('method_missing classes: CwGhost') &&
             body_of.call(ghost_code, 'CwCaller_talk').include?('CLOSED_WORLD kept: method_missing_receiver'))
exact_call = body_of.call(exact_construct_code, 'CwExact__Caller_call')
rebound_call = body_of.call(exact_construct_code, 'CwRebound__Caller_call')
exact_marker = exact_call.index('EXACT_TYPED :exact_value -> CwExact::StableFresh#exact_value') ||
               exact_call.index('CLOSED_WORLD_EXACT_CLASS :exact_value -> CwExact::StableFresh#exact_value')
check.call('a fresh instance of a stable class constant drops the exact-class guard and fallback',
           exact_marker && exact_call[exact_marker..].include?('CwExact__StableFresh_exact_value_impl(M, r2)') &&
             !exact_call[exact_marker..].include?('bc2cpp_send('))
check.call('a class constant rebound in the closed world keeps guarded dynamic dispatch',
           !rebound_call.include?('CLOSED_WORLD_EXACT_CLASS') && rebound_call.include?('mrb_obj_class(M,') &&
             rebound_call.include?('mrb_funcall'))

singleton_code, = generate.call(SINGLETON_WORLD, 'cw_singleton', true)
singleton_self = body_of.call(singleton_code, 'CwBase_run')
singleton_other = body_of.call(singleton_code, 'CwBase_outside')
check.call('a self call in an instance method ignores a .singleton definer: class hierarchy analysis resolves it',
           singleton_self.include?('CLOSED_WORLD_SELF :cw_hello') && !singleton_self.include?('bc2cpp_send(') &&
             !singleton_self.include?('kept: singleton_definer'))
check.call('a non-self receiver may be the module object: it gets an identity arm (ADR 0369) and the else raises',
           singleton_other.include?('CLOSED_WORLD_CONSTANT_OBJECT :cw_hello -> CwHolder.singleton#cw_hello') &&
             singleton_other.include?('MRB_TT_MODULE && mrb_class_ptr(') && singleton_other.include?('bc2cpp_nomethod(') &&
             !singleton_other.include?('kept: singleton_definer'))
respond_outside = bc2cpp_closed_world_outside_srcs('wio', wio_gems, root)
respond_code, = generate.call(RESPOND_WORLD, 'cw_respond', true, nil, respond_outside)
respond_hook_code, = generate.call(RESPOND_HOOK_WORLD, 'cw_respond_hook', true, nil, respond_outside)
respond_probe = body_of.call(respond_code, 'CwResponder_probe')
respond_hook_probe = body_of.call(respond_hook_code, 'CwResponder_probe')
check.call('respond_to? with no respond_to_missing? anywhere: hits answer directly and a miss is false, no send',
           respond_probe.include?('mrb_respond_to(') && respond_probe.include?('mrb_false_value()') &&
             !respond_probe.include?('bc2cpp_send('))
check.call('a respond_to_missing? override keeps the send on a miss',
           respond_hook_probe.include?('mrb_respond_to(') && respond_hook_probe.include?('bc2cpp_send(') &&
             !respond_hook_probe.include?('mrb_false_value()'))

constant_object_call = body_of.call(constant_object_code, 'CwStableCaller_stable')
qualified_constant_object_call = body_of.call(constant_object_code, 'CwStableCaller_qualified')
nested_shadow_call = body_of.call(constant_object_code, 'CwOuter__CwInner__Caller_nested_shadow')
module_function_call = body_of.call(constant_object_code, 'CwStableCaller_module_function')
inlined_block_call = body_of.call(constant_object_code, 'CwBlockCaller_times_value')
module_function_state_call = body_of.call(constant_object_code, 'CwStableCaller_module_function_state')
value_constant_type_call = body_of.call(constant_object_code, 'CwStableCaller_value_constant_type')
after_branch_call = body_of.call(constant_object_code, 'CwStableCaller_after_branch')
block_argument_call = body_of.call(constant_object_code, 'CwStableCaller_block_argument')
branch_selected_call = body_of.call(constant_object_code, 'CwStableCaller_branch_selected')
rebound_object_call = body_of.call(constant_object_code, 'CwReboundCaller_rebound')
qualified_construct_call = body_of.call(constant_object_code, 'CwQualifiedConstruct__Caller_create')
qualified_array_construct_call = body_of.call(constant_object_code, 'CwQualifiedConstruct__Caller_create_array')
qualified_hash_construct_call = body_of.call(constant_object_code, 'CwQualifiedConstruct__Caller_create_hash')
qualified_range_construct_call = body_of.call(constant_object_code, 'CwQualifiedConstruct__Caller_create_range')
instance_mixin_construct_call = body_of.call(constant_object_code, 'CwInstanceMixinCaller_create')
check.call('a constant receiver inside an inlined block body is resolved too (trace_idx, shifted registers)',
           inlined_block_call.include?('CLOSED_WORLD_CONSTANT_OBJECT :value') &&
             inlined_block_call.include?('CwModuleFunction_value_impl(') && !inlined_block_call.include?('bc2cpp_send('))
check.call('a stable class/module constant dispatches directly to its unique singleton method',
           constant_object_call.include?('CLOSED_WORLD_CONSTANT_OBJECT') &&
             constant_object_call.include?('CwStableObject_singleton_value_impl(') &&
             !constant_object_call.include?('bc2cpp_send('))
check.call('a branch before a fresh stable constant lookup preserves direct dispatch',
           after_branch_call.include?('CLOSED_WORLD_CONSTANT_OBJECT') &&
             after_branch_call.include?('CwStableObject_singleton_value_impl('))
check.call('a block in the argument list does not hide the dominating constant load (reaching definitions)',
           block_argument_call.include?('CLOSED_WORLD_CONSTANT_OBJECT :echo') &&
             block_argument_call.include?('CwStableObject_singleton_echo_impl('))
check.call('a branch-selected receiver keeps runtime dispatch',
           !branch_selected_call.include?('CLOSED_WORLD_CONSTANT_OBJECT') &&
             branch_selected_call.include?('bc2cpp_send('))
check.call('a qualified class constant resolves directly through its initializer',
           qualified_construct_call.include?('MONO :new -> CwQualifiedConstruct::Stable') &&
             qualified_construct_call.include?('CwQualifiedConstruct__Stable_initialize_impl(') &&
             !qualified_construct_call.include?('mrb_funcall(M, r') )
check.call('Array.new uses guarded direct object construction when Class#new is proven standard',
           qualified_array_construct_call.include?('MONO :new -> Array, generic direct object construction') &&
             qualified_array_construct_call.include?('mrb_obj_new(M, mrb_class_ptr(r') &&
             qualified_array_construct_call.include?('mrb_class_ptr(r') &&
             qualified_array_construct_call.include?('bc2cpp_send(M, r'))
check.call('Hash.new and Range.new use their stable mruby class pointers',
           qualified_hash_construct_call.include?('MONO :new -> Hash, generic direct object construction') &&
             qualified_hash_construct_call.include?('M->hash_class') &&
             qualified_range_construct_call.include?('MONO :new -> Range, generic direct object construction') &&
             qualified_range_construct_call.include?('M->range_class'))
check.call('an unresolved instance mixin does not block a proven class-object constructor',
           instance_mixin_construct_call.include?('MONO :new -> CwInstanceMixinConstruct') &&
             instance_mixin_construct_call.include?('CwInstanceMixinConstruct_initialize_impl(') &&
             !instance_mixin_construct_call.include?('bc2cpp_send(M, r'))
check.call("a qualified constant object's VM register retains its exact class/module type",
           qualified_constant_object_call.include?('CLOSED_WORLD_CONSTANT_OBJECT') &&
             qualified_constant_object_call.include?('CwNamespace__StableObject_singleton_value_impl(') &&
             !qualified_constant_object_call.include?('bc2cpp_send('))
check.call('the innermost lexical class/module constant wins over same-named outer constants',
           nested_shadow_call.include?('CLOSED_WORLD_CONSTANT_OBJECT') &&
             nested_shadow_call.include?('CwOuter__CwInner__StableObject_singleton_value_impl(') &&
             !nested_shadow_call.include?('bc2cpp_send('))
saved_construct_names = ConstructClassNames.table
ConstructClassNames.table = {
  'StableObject' => true,
  'CwOuter::StableObject' => true,
  'CwOuter::CwInner::StableObject' => true,
}
nested_construct_name = CodeGen.allocate.send(:lexically_resolve_construct_target,
                                                'StableObject', 'CwOuter::CwInner::Caller')
top_level_construct_name = CodeGen.allocate.send(:lexically_resolve_construct_target,
                                                  'StableObject', 'CwOther::Caller')
unknown_construct_name = CodeGen.allocate.send(:lexically_resolve_construct_target,
                                               'MissingObject', 'Unrelated')
ConstructClassNames.table = saved_construct_names
check.call('construct resolution selects the first binding in Ruby lexical nesting',
           nested_construct_name == 'CwOuter::CwInner::StableObject')
check.call('construct resolution falls back to a proven top-level constant',
           top_level_construct_name == 'StableObject')
check.call('construct resolution leaves an unproven top-level constant unresolved',
           unknown_construct_name.nil?)
check.call('a single-assignment instance constant supplies a guarded class and falls back for a custom constructor result',
           value_constant_type_call.include?('TYPED :value_type_probe -> CwValueTypeA') &&
             value_constant_type_call.include?('CwValueTypeA_value_type_probe_impl('))
check.call('a closed-world module_function copy calls its original compiled body directly',
           module_function_call.include?('CLOSED_WORLD_CONSTANT_OBJECT') &&
             module_function_call.include?('module_function copy of CwModuleFunction#value') &&
             module_function_call.include?('CwModuleFunction_value_impl(') &&
             !module_function_call.include?('bc2cpp_send('))
check.call('selecting only the module singleton owner emits its copied body for cross-owner direct calls',
           selective_constant_object_code.include?('CwModuleFunction_value_impl(mrb_state* M') &&
             body_of.call(selective_constant_object_code, 'CwStableCaller_module_function')
               .include?('CwModuleFunction_value_impl('))
check.call('a module_function body that observes instance state keeps dynamic dispatch',
           !module_function_state_call.include?('CLOSED_WORLD_CONSTANT_OBJECT') &&
             module_function_state_call.include?('bc2cpp_send('))
check.call('a lexically rebound class/module constant declines direct singleton dispatch',
           !rebound_object_call.include?('CLOSED_WORLD_CONSTANT_OBJECT') &&
             rebound_object_call.include?('bc2cpp_send('))
# CHA_SELF (ADR 0254): the descendants of CwBase are all known, so the call has no
# by-name arm at all: an exact-class arm for the one override, then CwBase's own.
chat_body = body_of.call(ghost_code, 'CwBase_chat')
check.call('a self receiver in a class with no method_missing descendant needs no dispatch and no bc2cpp_nomethod',
           chat_body.include?('CLOSED_WORLD_SELF :cw_speak -> CwBase#cw_speak') &&
             chat_body.include?('only CwKid (CwKid) override') && !chat_body.include?('bc2cpp_send(') &&
             !chat_body.include?('bc2cpp_nomethod('))

# CLOSED_WORLD_SELF: a self call into an embedding owner nothing subclasses
# needs no guard at all; a subclass that cannot resolve the name elsewhere
# (CHA_SELF) does not need one either, and one that could (alias_method) keeps it.
native_bang = MethodDef.new(name: '!', owner: '<native>', irep: nil, visibility: :public)
native_only_world = ClosedWorld.new(ireps: {}, registry: { '!' => [native_bang] }, class_decls: {}, walked: Set.new,
                                    native_paths: [], ruby_paths: [])
single_write_irep = Irep.new(label: 'single-write', nlocals: 0, nregs: 3, pool: [], syms: [], reps: [], lv: [],
                             instructions: [Insn.new(lineno: 1, addr: 0, op: 'SETCONST', args: 'CwSingleValue R2', raw: '')])
single_write_world = ClosedWorld.new(ireps: { 'single-write' => single_write_irep }, registry: {}, class_decls: {},
                                     walked: Set['single-write'], native_paths: [], ruby_paths: [])
repeated_write_irep = Irep.new(label: 'repeated-write', nlocals: 0, nregs: 3, pool: [], syms: [], reps: [], lv: [],
                               instructions: [0, 1].map do |addr|
                                 Insn.new(lineno: addr + 1, addr: addr, op: 'SETCONST', args: 'CwRepeatedValue R2', raw: '')
                               end)
repeated_write_world = ClosedWorld.new(ireps: { 'repeated-write' => repeated_write_irep }, registry: {}, class_decls: {},
                                       walked: Set['repeated-write'], native_paths: [], ruby_paths: [])
check.call('closed world proves one bytecode assignment for an untouched value constant',
           single_write_world.single_assignment_constant?('CwSingleValue'))
check.call('closed world rejects multiple bytecode assignments to a value constant',
           !repeated_write_world.single_assignment_constant?('CwRepeatedValue'))
deferred_write_world = ClosedWorld.new(ireps: { 'single-write' => single_write_irep }, registry: {}, class_decls: {},
                                       walked: Set.new, native_paths: [], ruby_paths: [])
check.call('closed world rejects a constant write inside a deferred method body',
           !deferred_write_world.single_assignment_constant?('CwSingleValue'))
Dir.mktmpdir do |dir|
  foreign_const = File.join(dir, 'foreign_const.rb')
  File.write(foreign_const, "CwSingleValue = Object.new\n")
  foreign_write_world = ClosedWorld.new(ireps: { 'single-write' => single_write_irep }, registry: {}, class_decls: {},
                                        walked: Set['single-write'], native_paths: [], ruby_paths: [foreign_const])
  check.call('closed world rejects a bytecode single-assignment constant touched by foreign Ruby',
             !foreign_write_world.single_assignment_constant?('CwSingleValue'))
  File.write(foreign_const, "def read_value; CwSingleValue; end\n")
  foreign_read_world = ClosedWorld.new(ireps: { 'single-write' => single_write_irep }, registry: {}, class_decls: {},
                                       walked: Set['single-write'], native_paths: [], ruby_paths: [foreign_const])
  check.call('a foreign read alone does not poison the constant single-assignment fact',
             foreign_read_world.single_assignment_constant?('CwSingleValue'))
  File.write(foreign_const, "Object.const_set(:CwSingleValue, Object.new)\n")
  dynamic_write_world = ClosedWorld.new(ireps: { 'single-write' => single_write_irep }, registry: {}, class_decls: {},
                                        walked: Set['single-write'], native_paths: [], ruby_paths: [foreign_const])
  check.call('closed world rejects value-constant proof when outside Ruby can mutate constants dynamically',
             !dynamic_write_world.single_assignment_constant?('CwSingleValue'))
  native_const = File.join(dir, 'native_const.c')
  File.write(native_const, 'void f(mrb_state* M) { mrb_const_set(M, mrb_obj_value(M->object_class), ' \
                           'mrb_intern_lit(M, "CwSingleValue"), mrb_nil_value()); }')
  native_write_world = ClosedWorld.new(ireps: { 'single-write' => single_write_irep }, registry: {}, class_decls: {},
                                      walked: Set['single-write'], native_paths: [native_const], ruby_paths: [])
  check.call('closed world rejects a literal native write to a value constant by name',
             !native_write_world.single_assignment_constant?('CwSingleValue'))
  File.write(native_const, 'void f(mrb_state* M, mrb_sym sym) { mrb_const_set(M, ' \
                           'mrb_obj_value(M->object_class), sym, mrb_nil_value()); }')
  dynamic_native_world = ClosedWorld.new(ireps: { 'single-write' => single_write_irep }, registry: {}, class_decls: {},
                                         walked: Set['single-write'], native_paths: [native_const], ruby_paths: [])
  check.call('closed world rejects a computed native constant write',
             !dynamic_native_world.single_assignment_constant?('CwSingleValue'))
end
check.call('closed world accepts a sole ownerless native definition', native_only_world.ownerless_native_dispatch_safe?('!'))
check.call('closed world treats an unresolved symbolic class hint as unknown',
           !native_only_world.stable_class_constant?(:unknown) && !native_only_world.stable_constant_identity?(:unknown))
overridden_world = ClosedWorld.new(ireps: {}, registry: { '!' => [native_bang,
                                                                    MethodDef.new(name: '!', owner: 'CwOverride',
                                                                                  irep: 1, visibility: :public)] },
                                   class_decls: {}, walked: Set.new, native_paths: [], ruby_paths: [])
check.call('closed world rejects a registered Ruby override for an ownerless native method',
           !overridden_world.ownerless_native_dispatch_safe?('!'))
Dir.mktmpdir do |dir|
  override = File.join(dir, 'override.rb')
  File.write(override, "class CwOverride\n  def !; true; end\nend\n")
  external_override_world = ClosedWorld.new(ireps: {}, registry: { '!' => [native_bang] }, class_decls: {}, walked: Set.new,
                                            native_paths: [], ruby_paths: [override])
  check.call('closed world rejects an outside Ruby definition for an ownerless native method',
             !external_override_world.ownerless_native_dispatch_safe?('!'))
end

# TouchScan (docs/adr/0256): an outside file makes a class opaque only when it
# can create, reopen, subclass or rebind it; a mention (a call, a constant
# read, an instantiation, a native define of a class Ruby also declares) does not.
Dir.mktmpdir do |dir|
  decl = { super: :none, outer_nil: true }
  decls = { 'CwTouched' => [decl], 'CwBoom' => [decl], 'CwMod::CwInner' => [decl] }
  n = 0
  opaque_by = lambda do |name, lang, source|
    n += 1
    path = File.join(dir, "touch#{n}.#{lang}")
    File.write(path, source)
    world = ClosedWorld.new(ireps: {}, registry: {}, class_decls: decls, walked: Set.new,
                            native_paths: lang == 'rb' ? [] : [path], ruby_paths: lang == 'rb' ? [path] : [])
    world.send(:opaque?, name)
  end
  ruby_cases = [
    ['a Ruby file that only mentions a class', false, "x = CwTouched\ndef f; CwTouched.new; CwTouched::LIMIT; end\n"],
    ['a Ruby file that reopens a class', true, "class CwTouched\n  def y; end\nend\n"],
    ['a Ruby file that subclasses a class', true, "class CwKid < CwTouched\nend\n"],
    ['a Ruby file that subclasses through a non-constant expression', true, "class CwKid < CwTouched.pick\nend\n"],
    ['a Ruby file that rebinds a class constant', true, "CwTouched = 5\n"],
    ['a Ruby file that rebinds a class constant with ||=', true, "CwTouched ||= 5\n"],
    ['a Ruby file that aliases a class and reopens it', true, "CwAlias = CwTouched\nclass CwAlias\nend\n"],
    ['a Ruby file that reopens a class through class_eval', true, "k = CwTouched\nk.class_eval { def z; end }\n"],
    ['a Ruby file that copies a class with dup', true, "k = CwTouched\nk.dup\n"],
    ['a Ruby file that extends a class from outside', true, "CwTouched.extend(Mixin)\n"],
    ['a Ruby file that only reopens another namespace of the same simple name', false,
     "module CwElse\n  class CwInner\n  end\nend\n"],
    ['a Ruby file that reopens the qualified class', true, "module CwMod\n  class CwInner\n  end\nend\n"],
    ['a Ruby file that reopens the qualified class by path', true, "class CwMod::CwInner\nend\n"],
    ['a Ruby file whose lookup reaches the class through an included namespace', true,
     "include CwMod\nclass CwKid < CwInner\nend\n"],
    ['a Ruby file whose only `class` is prose in a comment', false, "def f; end # a class of CwTouched things\n"]
  ]
  ruby_cases.each do |what, opaque, source|
    name = source.include?('CwInner') ? 'CwMod::CwInner' : 'CwTouched'
    check.call(what, opaque_by.call(name, 'rb', source) == opaque)
  end
  native_prelude = 'void f(mrb_state* M, mrb_value obj, mrb_value v) { ' \
                   'mrb_const_set(M, obj, mrb_intern_lit(M, "CW_MARK"), v); '
  native_cases = [
    ['a native file that only instantiates and adds methods to a class', false,
     'RClass* k = mrb_class_get(M, "CwTouched"); mrb_define_method(M, k, "foo", g, MRB_ARGS_NONE()); ' \
     'mrb_obj_new(M, mrb_class_get(M, "CwTouched"), 0, NULL);'],
    ['a native file that only defines a class the closed world declares', false,
     'mrb_define_class(M, "CwTouched", M->object_class);'],
    ['a native file that subclasses a class', true,
     'mrb_define_class(M, "CwKid", mrb_class_get(M, "CwTouched"));'],
    ['a native file that subclasses through a variable', true,
     'mrb_define_class(M, "CwKid", k); mrb_class_get(M, "CwTouched");'],
    ['a native file that subclasses a built-in handle the closed world reopens', true,
     'mrb_define_class(M, "CwKid", M->eCwBoom_class);', 'CwBoom'],
    ['a native file that subclasses a class the closed world does not declare', false,
     'mrb_define_class(M, "CwKid", E_STANDARD_ERROR); mrb_class_get(M, "CwTouched");'],
    ['a native file that makes a class with mrb_class_new', true,
     'mrb_class_new(M, mrb_class_get(M, "CwTouched"));'],
    ['a native file that rebinds a class constant by name', true,
     'mrb_const_set(M, obj, mrb_intern_lit(M, "CwTouched"), v);'],
    ['a native file that mixes a module into a class', true,
     'mrb_include_module(M, mrb_class_get(M, "CwTouched"), mod);'],
    ['a native file that instantiates through a class it cannot see', true,
     'mrb_obj_new(M, klass, 0, NULL); mrb_class_get(M, "CwTouched");'],
    ['a native file that sends new to a class it cannot see', true,
     'mrb_funcall_id(M, mrb_obj_value(klass), MRB_SYM(new), 0); mrb_class_get(M, "CwTouched");'],
    ['a native file that sends an unrelated literal name', false,
     'mrb_funcall_id(M, obj, MRB_SYM(clear), 0); mrb_class_get(M, "CwTouched");']
  ]
  native_cases.each do |what, opaque, body, name|
    check.call(what, opaque_by.call(name || 'CwTouched', 'c', "#{native_prelude}#{body} }") == opaque)
  end
  # Defining a class natively is the origin of a class the closed world declares,
  # but it still touches an owner the closed world does not declare.
  path = File.join(dir, 'origin.c')
  File.write(path, 'void f(mrb_state* M) { mrb_define_class(M, "CwNative", M->object_class); }')
  origin_world = ClosedWorld.new(ireps: {}, registry: {}, class_decls: decls, walked: Set.new,
                                 native_paths: [path], ruby_paths: [])
  check.call('a native define touches a name the closed world does not declare',
             origin_world.send(:touches_for, ['CwNative'], source: true).any? &&
               origin_world.send(:touches_for, ['CwNative'], source: false).empty?)
end

COUNTER = <<~'RUBY'
  class CwCounter
    def initialize; @n = 0; end
    def bump; @n = @n + 1; end
    def twice; bump; bump; end
  end
RUBY
native, ruby = bc2cpp_closed_world_outside_srcs('wio', wio_gems, root)
[['no subclass', COUNTER, true], ['a plain subclass', "#{COUNTER}class CwCounterKid < CwCounter; end\n", true],
 ['a subclass aliasing the name', "#{COUNTER}class CwCounterKid < CwCounter\n  def other; 1; end\n  " \
                                  "alias_method :bump, :other\nend\n", false]].each do |what, src, dropped|
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'counter.rb')
    File.write(path, src)
    ireps, root_label = compile_ireps(path, 'bc2cpp_cw_counter', dir)
    registry, superclass_of, _c, included, prepended, unknown, _s, class_decls, walked = build_registry(ireps, root_label)
    world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: class_decls, walked: walked,
                            native_paths: native, ruby_paths: ruby)
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, nil, nil, nil,
                      included, prepended, unknown, closed_world: world)
    gen.instance_variable_get(:@ivar_layout)['CwCounter'] = { 'n' => :fixnum }
    code = gen.compile_method(registry.fetch('twice').find { |d| d.owner == 'CwCounter' }.irep).fetch(:code)
    ok = if dropped
           code.include?('CLOSED_WORLD_SELF :bump') && !code.include?('mrb_obj_class')
         else
           # An aliased `bump` may resolve elsewhere on the subclass: the guard and the dispatch stay.
           code.include?('MONO_EMBED_GUARD :bump') && code.include?('mrb_obj_class') && code.include?('mrb_funcall(')
         end
    check.call("a self call into an embedding owner with #{what} #{dropped ? 'drops' : 'keeps'} the guard", ok)
  end
end

# A globally polymorphic name can still have one closed-world target for an
# exactly traced class when that target is inherited through a complete MRO.
Dir.mktmpdir do |dir|
  path = File.join(dir, 'inherited.rb')
  File.write(path, <<~RUBY)
    class CwMonoBase
      def value; 1; end
    end
    class CwMonoChild < CwMonoBase
      def call; CwMonoChild.new.value; end
    end
    class CwMonoOther
      def value; 2; end
    end
  RUBY
  ireps, root_label = compile_ireps(path, 'bc2cpp_cw_inherited', dir)
  registry, superclass_of, _c, included, prepended, unknown, _s, class_decls, walked = build_registry(ireps, root_label)
  world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: class_decls, walked: walked,
                          native_paths: native, ruby_paths: ruby)
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, nil, nil, nil,
                    included, prepended, unknown, closed_world: world)
  code = gen.compile_method(registry.fetch('call').find { |d| d.owner == 'CwMonoChild' }.irep).fetch(:code)
  check.call('a traced fresh receiver resolves a globally polymorphic inherited method without fallback',
             (code.include?('EXACT_TYPED :value -> CwMonoBase#value') ||
               code.include?('CLOSED_WORLD_EXACT_CLASS :value -> CwMonoBase#value')) &&
               code.include?('CwMonoBase_value_impl(M, r2)') && !code.include?('bc2cpp_send('))
end

# -- run against the real mruby core ---------------------------------------------

candidates = [ENV['BC2CPP_MRUBY_CORE']].compact + Dir[File.join(root, 'build*/mruby/host/mrbc')]
core = candidates.find { |d| File.exist?(File.join(d, 'lib/libmruby_core.a')) && File.directory?(File.join(d, 'include')) }
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP behavioural comparison: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  run = lambda do |code, ruby, defines, probes|
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'gen.cpp'), code)
      harness = File.join(dir, 'harness.cpp')
      File.write(harness, <<~CPP)
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
          // NameError/NoMethodError live in mruby's mrblib, which the core build lacks.
          load(M, #{File.read(File.join(root, '3rd/mruby/mrblib/10error.rb')).inspect});
          load(M, #{ruby.inspect});
          #{defines}
          #{probes}
          mrb_close(M);
          return 0;
        }
      CPP
      binary = File.join(dir, 'harness')
      built = Bc2cppCxx.system('-std=c++17', '-w', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS',
                     "-I#{dir}", "-I#{core}/include", "-I#{root}/3rd/mruby/include", harness,
                     "#{core}/lib/libmruby_core.a", '-o', binary)
      built ? IO.popen(binary, err: %i[child out], &:read) : nil
    end
  end
  define = ->(klass, meth, argc) { "mrb_define_method(M, mrb_class_get(M, \"#{klass}\"), \"#{meth}\", #{klass}_#{meth}, MRB_ARGS_REQ(#{argc}));" }

  # Each case runs the compiled method and the interpreter on the same
  # receiver; the harness compares both exceptions' class, message, name and
  # args. (mrb_open_core has no mrblib, so no iterators here.)
  compare = <<~RUBY
    $cases = []
    def cw_case(r)
      a = begin; CwCaller.new.talk(r); rescue NoMethodError => e; e; end
      b = begin; r.cw_speak; rescue NoMethodError => e; e; end
      $cases << [a, b]
      a = begin; CwCaller.new.fetch(r); rescue NoMethodError => e; e; end
      b = begin; r.cw_fetch(1, 2); rescue NoMethodError => e; e; end
      $cases << [a, b]
    end
    cw_case(nil)
    cw_case(CwOther.new)
    cw_case(7)
    $rescued = begin; CwCaller.new.talk(nil); :missed; rescue StandardError; :rescued; end
    $values = [CwCaller.new.talk(CwPet.new), CwCaller.new.talk(CwRobot.new), CwCaller.new.fetch(CwPet.new),
               CwCaller.new.bark(CwPuppy.new), CwCaller.new.measure(CwRobot.new),
               CwCaller.new.measure([1, 2, 3]), CwCaller.new.measure("ab")]
    $measure_nil = [(begin; CwCaller.new.measure(nil); rescue NoMethodError => e; e.message; end),
                    (begin; nil.size; rescue NoMethodError => e; e.message; end)]
  RUBY
  probes = <<~'CPP'
    mrb_value cases = mrb_gv_get(M, mrb_intern_lit(M, "$cases"));
    int same = 0, raised = 0;
    for (mrb_int i = 0; i < RARRAY_LEN(cases); ++i) {
      mrb_value pair = mrb_ary_ref(M, cases, i);
      mrb_value a = mrb_ary_ref(M, pair, 0), b = mrb_ary_ref(M, pair, 1);
      if (!mrb_exception_p(a) || !mrb_exception_p(b)) continue;
      ++raised;
      mrb_sym name = mrb_intern_lit(M, "@name"), args = mrb_intern_lit(M, "@args");
      bool eq = mrb_obj_class(M, a) == mrb_obj_class(M, b) &&
                mrb_equal(M, mrb_funcall(M, a, "message", 0), mrb_funcall(M, b, "message", 0)) &&
                mrb_equal(M, mrb_iv_get(M, a, name), mrb_iv_get(M, b, name)) &&
                mrb_equal(M, mrb_iv_get(M, a, args), mrb_iv_get(M, b, args));
      if (eq) ++same; else std::printf("differ: %s vs %s\n", str(M, a), str(M, b));
    }
    std::printf("raised %d of %d, identical %d\n", raised, (int)RARRAY_LEN(cases), same);
    std::printf("rescued %s\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$rescued"))));
    std::printf("values %s\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$values"))));
    std::printf("measure nil %s\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$measure_nil"))));
  CPP
  defines = [define.call('CwCaller', 'talk', 1), define.call('CwCaller', 'fetch', 1), define.call('CwCaller', 'bark', 1),
             define.call('CwCaller', 'measure', 1)].join("\n")
  output = run.call(closed_code, WORLD, "#{defines}\nload(M, #{compare.inspect});", probes)
  check.call('the closed-world code compiles and runs against the real mruby core', !output.nil?)
  if output
    puts output.lines.map { |l| "  #{l}" }.join
    check.call('nil, a wrong-class object and an Integer raise the identical NoMethodError (class, message, name, args)',
               output.include?('raised 6 of 6, identical 6'))
    check.call('rescue catches it', output.include?('rescued :rescued'))
    check.call('listed receivers, an inherited method and a core name still answer', output.include?('values [1, 2, 3, 20, 6, 3, 2]'))
    check.call('the owner call raises dispatch\'s NoMethodError for nil (ADR 0468)',
               output[/^measure nil \[(".*?"), \1\]$/] && output.include?("undefined method 'size'"))
  end

  module_function_probe = <<~CPP
    load(M, "$values = [CwStableCaller.new.module_function, CwModuleFunction.value(4)]");
    std::printf("module_function values %s\\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$values"))));
  CPP
  module_function_define = 'mrb_define_method(M, mrb_class_get(M, "CwStableCaller"), "module_function", ' \
                           'CwStableCaller_module_function, MRB_ARGS_NONE());'
  module_function_output = run.call(constant_object_code, CONSTANT_OBJECT_WORLD,
                                    module_function_define, module_function_probe)
  check.call('a direct module_function call agrees with mruby singleton-copy dispatch',
             module_function_output&.include?('module_function values [7, 7]'))

  value_constant_probe = <<~CPP
    load(M, "$values = [CwStableCaller.new.value_constant_type, CwValueTypeConstant.value_type_probe]");
    std::printf("value constant values %s\\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$values"))));
  CPP
  value_constant_defines = define.call('CwStableCaller', 'value_constant_type', 0)
  value_constant_output = run.call(constant_object_code, CONSTANT_OBJECT_WORLD, value_constant_defines,
                                   value_constant_probe)
check.call('single-assignment constant receiver dispatch preserves the runtime result',
           value_constant_output&.include?('value constant values [32, 32]'))

array_construct_probe = <<~CPP
  load(M, "$values = [CwQualifiedConstruct::Caller.new.create_array.size, " \
          "CwQualifiedConstruct::Caller.new.create_hash[:missing], " \
          "CwQualifiedConstruct::Caller.new.create_range.end, " \
          "CwQualifiedConstruct::Caller.new.create_range.exclude_end?]");
  std::printf("constructor values %s\\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$values"))));
CPP
array_construct_output = run.call(constant_object_code, CONSTANT_OBJECT_WORLD, '', array_construct_probe)
check.call('guarded direct Array/Hash/Range construction preserves mruby initialization',
           array_construct_output&.include?('constructor values [3, 7, 3, true]'))

  ghost_ruby = <<~RUBY
    $values = [CwCaller.new.talk(CwGhost.new), CwKid.new.chat, CwBase.new.chat, CwCaller.new.talk(CwRobot.new)]
  RUBY
  ghost_defines = [define.call('CwCaller', 'talk', 1), define.call('CwBase', 'chat', 0)].join("\n")
  ghost_probe = 'std::printf("values %s\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$values"))));'
  output = run.call(ghost_code, GHOST_WORLD, "#{ghost_defines}\nload(M, #{ghost_ruby.inspect});", ghost_probe)
  check.call('the method_missing world compiles and runs', !output.nil?)
  if output
    puts output.lines.map { |l| "  #{l}" }.join
    check.call('a kept site still reaches method_missing; the converted self site still dispatches by class',
               output.include?('values [42, 3, 1, 2]'))
  end
end

if failures.empty?
  puts 'bc2cpp closed world check: PASS'
else
  warn "bc2cpp closed world check: #{failures.size} failure(s)"
  exit 1
end
