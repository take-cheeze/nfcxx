#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/main_roots'
require_relative '../../tools/bc2cpp/main_reachability'
require_relative '../../tools/bc2cpp/native_vm'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/initializer_tables'
require_relative '../../tools/bc2cpp/native_inventory'
require 'rake'

# The fixture defines its own program rather than the engine's signature classes.
ENV['BC2CPP_SIG_DIRS'] = ''

abort 'main roots check requires clang++' unless system(ENV.fetch('CLANG', 'clang++'), '--version', out: File::NULL)
checks = 0
check = lambda do |label, condition|
  abort "FAIL: #{label}" unless condition

  checks += 1
  puts "  #{label}"
end
root = Bc2cppFixtureRuntime::ROOT
Dir.mktmpdir('bc2cpp-main-roots') do |dir|
  host = File.join(dir, 'main.cpp')
  ast = File.join(dir, 'main.json')
  header = File.join(dir, 'host.h')
  File.write(header, <<~CPP)
    extern "C" int mrb_funcall(void*, int, const char*, int);
    extern void install(void (*)());
    extern int MainRootProbe_qr9z_direct_impl(void*, int);
    const char* diagnostic_label = "qr9z_label";
  CPP
  File.write(host, <<~CPP)
    #include "host.h"
    void unused() { mrb_funcall(0, 0, "qr9z_unused", 0); }
    void callback() { mrb_funcall(0, 0, "qr9z_callback", 0); }
    int initialize_host() { return mrb_funcall(0, 0, "qr9z_boot", 0); }
    int startup = initialize_host();
    int main(int argc, char**) {
      install(callback);
      MainRootProbe_qr9z_direct_impl(0, 0);
      const char* name = argc ? "qr9z_entry" : "qr9z_other";
      mrb_funcall(0, 0, name, 0);
    }
  CPP
  build_ast = lambda do |units = []|
    abort 'host AST generation failed' unless system(RbConfig.ruby, File.join(root, 'scripts/bc2cpp/main_ast.rb'), host, ast, *units.flat_map { |path| ['--unit', path] })
  end
  build_ast.call
  roots = MainRoots.read(ast)
  check.call('main reaches its helper callbacks and static initialization',
             %w[qr9z_entry qr9z_other qr9z_callback qr9z_boot].all? { |name| roots.names.include?(name) })
  check.call('an unused native function contributes no Ruby roots', !roots.names.include?('qr9z_unused'))
  check.call('finite conditional names are resolved', roots.refusals.empty?)
  strict_ast = File.join(dir, 'strict-main.json')
  abort 'strict host AST generation failed' unless system(RbConfig.ruby, File.join(root, 'scripts/bc2cpp/main_ast.rb'), host, strict_ast, '--lookup-names-only')
  strict_roots = MainRoots.read(strict_ast)
  check.call('lookup-only AST roots preserve calls while excluding unrelated string data',
             strict_roots.names.include?('qr9z_entry') && strict_roots.names.include?('qr9z_boot') &&
             roots.names.include?('qr9z_label') && !strict_roots.names.include?('qr9z_label'))

  source = <<~RUBY_SOURCE
    class MainRootProbe
      def qr9z_entry
        qr9z_chain
      end
      def qr9z_chain
        qr9z_leaf + 1
      end
      def qr9z_leaf
        40
      end
      def qr9z_callback
        qr9z_leaf + 2
      end
      def qr9z_other
        3
      end
      def qr9z_boot
        4
      end
      def qr9z_unused
        qr9z_dead_leaf
      end
      def qr9z_dead_leaf
        99
      end
      def qr9z_direct
        7
      end
      def qr9z_named(name = :qr9z_entry)
        respond_to?(name)
        8
      end
    end
  RUBY_SOURCE
  original_env = ENV['BC2CPP_MAIN_AST']
  original_unregistered = ENV['BC2CPP_UNREGISTERED_EXTRA']
  original_report = ENV['BC2CPP_MAIN_REPORT']
  begin
    # The fixture's internal methods stand in for checked, name-invisible entries.
    ENV['BC2CPP_UNREGISTERED_EXTRA'] = %w[qr9z_unused qr9z_dead_leaf qr9z_chain qr9z_leaf qr9z_direct]
                                         .map { |name| "MainRootProbe##{name}" }.join(',')
    ENV.delete('BC2CPP_MAIN_AST')
    full, = Bc2cppFixtureRuntime.generate(source, File.join(dir, 'full'), drop_native: ['/mruby-rgss/src/'])
    ENV['BC2CPP_MAIN_AST'] = ast
    ENV['BC2CPP_MAIN_REPORT'] = File.join(dir, 'reports')
    pruned_dir = File.join(dir, 'pruned')
    pruned, diagnostics = Bc2cppFixtureRuntime.generate(source, pruned_dir, drop_native: ['/mruby-rgss/src/'])
    check.call('pruning runs before method emission', full.include?('MainRootProbe_qr9z_unused_impl') &&
               !pruned.include?('MainRootProbe_qr9z_unused_impl'))
    check.call('unused callers do not keep their callees', !pruned.include?('MainRootProbe_qr9z_dead_leaf_impl'))
    check.call('transitive Ruby callees remain compiled', pruned.include?('MainRootProbe_qr9z_leaf_impl'))
    check.call('a direct native implementation call is a root', pruned.include?('MainRootProbe_qr9z_direct_impl'))
    check.call('methods still visible by name remain roots', pruned.include?('MainRootProbe_qr9z_named_impl'))
    check.call('the generated C++ is smaller', pruned.bytesize < full.bytesize)
    puts "  generated C++: #{full.bytesize} -> #{pruned.bytesize} bytes"
    manifest = File.read(File.join(pruned_dir, 'fixture_stubs.txt'))
    check.call('dead method bodies join the residual mrblib stub manifest', manifest.include?('MainRootProbe#qr9z_unused'))
    check.call('the census reports omitted methods', diagnostics.include?('unreachable: MainRootProbe#qr9z_unused'))
    report = JSON.parse(File.read(File.join(ENV['BC2CPP_MAIN_REPORT'], 'fixture_named_reachability.json')))
    entry = report.fetch('entries').find { |row| row['name'] == 'qr9z_entry' }
    check.call('named reachability reports host evidence independently of mandatory table roots',
               entry['bounded_name_reached'] && entry['reasons'].any? { |reason| reason['kind'] == 'host' })
    named = report.fetch('entries').find { |row| row['name'] == 'qr9z_named' }
    check.call('report-only candidates remain registered', !named['bounded_name_reached'] && !named['excluded'])
    summary, summary_err, summary_status = Open3.capture3(RbConfig.ruby, File.join(root, 'scripts/bc2cpp/dynamic_names_report.rb'),
                                                          '--main-report', File.join(ENV['BC2CPP_MAIN_REPORT'], 'fixture_named_reachability.json'))
    check.call('the report summarizes retention reasons without rerunning generation',
               summary_status.success? && summary_err.empty? && summary.include?('by primary retention reason'))

    alias_dir = File.join(dir, 'alias-analysis')
    FileUtils.mkdir_p(alias_dir)
    alias_path = File.join(alias_dir, 'fixture.rb')
    File.write(alias_path, source + "\nclass MainRootProbe; def qr9z_enum(payload); to_enum(:qr9z_entry, payload); end; end\n")
    alias_ireps, alias_root = compile_ireps([alias_path], 'alias', alias_dir, mrbc: Bc2cppFixtureRuntime.mrbc)
    alias_defs = build_registry(alias_ireps, alias_root).first
    alias_roots = MainRoots::Result.new(names: Set['qr9z_alias'], functions: Set.new, refusals: [], native_paths: Set.new)
    alias_keys = alias_defs.values.flatten.to_set { |d| "#{d.owner}##{d.name}" }
    alias_result = MainReachability.analyze(alias_ireps, alias_defs, alias_roots, prunable_keys: alias_keys,
                                            aliases: { ['MainRootProbe', 'qr9z_entry'] => ['qr9z_alias'] }, seed_named: false, trace: true)
    check.call('an alias reaches its original body and transitive callees',
               !alias_result.dead_keys.include?('MainRootProbe#qr9z_entry') && alias_result.names.include?('qr9z_leaf'))
    check.call('transitive retention has Ruby source evidence',
               alias_result.reasons.fetch('qr9z_leaf').any? { |reason| reason[:kind] == 'ruby' && reason[:source].include?('fixture.rb:') })
    enum_roots = MainRoots::Result.new(names: Set['qr9z_enum'], functions: Set.new, refusals: [], native_paths: Set.new)
    enum_result = MainReachability.analyze(alias_ireps, alias_defs, enum_roots, prunable_keys: alias_keys, seed_named: false)
    check.call('to_enum resolves the method name independently of forwarded iterator arguments',
               enum_result.refusals.empty? && enum_result.names.include?('qr9z_entry'))
    alias_source = <<~RUBY_SOURCE
      class MainRootProbe
        def qr9z_entry = 7
        alias qr9z_removed qr9z_entry
        alias qr9z_kept qr9z_entry
      end
    RUBY_SOURCE
    ENV['BC2CPP_UNREGISTERED_EXTRA'] = 'MainRootProbe#qr9z_removed'
    alias_code, alias_diagnostics = Bc2cppFixtureRuntime.generate(alias_source, File.join(dir, 'alias-tables'),
                                                                 path: '3rd/mruby/mrblib/alias_probe.rb', drop_native: ['/mruby-rgss/src/'])
    check.call('a proven alias exclusion leaves the source and other alias registered',
               StaticDispatchRegistrations.registrations(alias_code).select { |entry, _name| entry == 'MainRootProbe_qr9z_entry' }
                                          .map(&:last).sort == %w[qr9z_entry qr9z_kept])
    alias_built, alias_output = Bc2cppFixtureRuntime.run(File.join(dir, 'alias-tables'), alias_diagnostics, ['MainRootProbe'], <<~CPP, build: Bc2cppFixtureRuntime.full_or_build, full: true)
      static int scenario(mrb_state* M) {
        if (compiled) bc2cpp_register_owner_methods(M);
        mrb_value object = mrb_obj_new(M, mrb_class_get(M, "MainRootProbe"), 0, nullptr);
        call(M, "kept alias", object, "qr9z_kept");
        struct RClass* owner = mrb_obj_class(M, object);
        mrb_method_t method = mrb_method_search_vm(M, &owner, mrb_intern_lit(M, "qr9z_removed"));
        bool found = !MRB_METHOD_UNDEF_P(method);
        return M->exc || (compiled ? found : !found) ? 1 : 0;
      }
    CPP
    warn alias_output unless alias_built && alias_output.scan('kept alias => 7').size == 2
    check.call('the real method table removes only the proven alias and preserves calls through the retained alias',
               alias_built && alias_output.scan('kept alias => 7').size == 2)
    ENV['BC2CPP_UNREGISTERED_EXTRA'] = %w[qr9z_unused qr9z_dead_leaf qr9z_chain qr9z_leaf qr9z_direct]
                                         .map { |name| "MainRootProbe##{name}" }.join(',')
    reference = Bc2cppFixtureRuntime.full_or_build
    abort 'main roots check requires a full-core reference runtime' unless reference
    built, output = Bc2cppFixtureRuntime.run(pruned_dir, diagnostics, ['MainRootProbe'], <<~CPP, build: reference, full: true)
      static int scenario(mrb_state* M) {
        mrb_value object = mrb_obj_new(M, mrb_class_get(M, "MainRootProbe"), 0, nullptr);
        call(M, "entry", object, "qr9z_entry");
        call(M, "callback", object, "qr9z_callback");
        if (compiled) show(M, "direct", MainRootProbe_qr9z_direct_impl(M, object));
        else call(M, "direct", object, "qr9z_direct");
        return M->exc ? 1 : 0;
      }
    CPP
    check.call('pruned C++ links and runs with the real runtime', built)
    check.call('reachable calls preserve interpreted results', output.scan('entry => 41').size == 2 && output.scan('callback => 42').size == 2)
    check.call('the native root preserves interpreted results', output.scan('direct => 7').size == 2)

    reflected = source + <<~RUBY_SOURCE
      class MainRootProbe
        def qr9z_entry
          send(ARGV[0])
        end
      end
    RUBY_SOURCE
    kept, report = Bc2cppFixtureRuntime.generate(reflected, File.join(dir, 'reflection'), drop_native: ['/mruby-rgss/src/'])
    check.call('an unbounded Ruby send keeps all bodies', kept.include?('MainRootProbe_qr9z_unused_impl') && report.include?('retain all:'))
  ensure
    original_env ? ENV['BC2CPP_MAIN_AST'] = original_env : ENV.delete('BC2CPP_MAIN_AST')
    original_unregistered ? ENV['BC2CPP_UNREGISTERED_EXTRA'] = original_unregistered : ENV.delete('BC2CPP_UNREGISTERED_EXTRA')
    original_report ? ENV['BC2CPP_MAIN_REPORT'] = original_report : ENV.delete('BC2CPP_MAIN_REPORT')
  end

  ctor_source = <<~RUBY_SOURCE
    module Game
      class CtorLeaf
        def initialize(value); @value = value; end
        def value; @value; end
      end
      class CtorChild < CtorLeaf; end
      module CtorFactory
        def self.make(value); CtorLeaf.new(value); end
        def self.child(value); CtorChild.new(value); end
      end
    end
  RUBY_SOURCE
  ctor_dir = File.join(dir, 'constructors')
  _ctor_code, ctor_err = Bc2cppFixtureRuntime.generate(ctor_source, ctor_dir, core: true, drop_native: ['/mruby-rgss/src/'])
  ctor_keys = InitializerTables.proven([{ err: ctor_err }])
  check.call('all construction sites, including an inherited initializer, prove a tableless entry', ctor_keys.include?('Game::CtorLeaf#initialize'))
  check.call('missing unit evidence refuses the initializer proof', InitializerTables.proven([{ err: '' }]).empty?)
  bad_source = ctor_source + "\nmodule Game::CtorFactory; def self.bad; Game::CtorLeaf.new; end; end\n"
  _bad_code, bad_err = Bc2cppFixtureRuntime.generate(bad_source, File.join(dir, 'bad-constructors'), core: true, drop_native: ['/mruby-rgss/src/'])
  check.call('a wrong-arity new still requires the named initializer', !InitializerTables.proven([{ err: bad_err }]).include?('Game::CtorLeaf#initialize'))
  dynamic_source = ctor_source + "\nmodule Game::CtorFactory; def self.dynamic(object, name); object.send(name); end; end\n"
  _dynamic, dynamic_err = Bc2cppFixtureRuntime.generate(dynamic_source, File.join(dir, 'dynamic-constructors'), core: true, drop_native: ['/mruby-rgss/src/'])
  check.call('an unbounded reflective call refuses initializer table omission', InitializerTables.proven([{ err: dynamic_err }]).empty?)
  super_source = ctor_source + "\nclass Game::CtorOverride < Game::CtorLeaf; def initialize(value); super(value); end; end\n"
  _super_code, super_err = Bc2cppFixtureRuntime.generate(super_source, File.join(dir, 'super-constructors'), core: true, drop_native: ['/mruby-rgss/src/'])
  check.call('an unproven super route preserves its parent initializer', !InitializerTables.proven([{ err: super_err }]).include?('Game::CtorLeaf#initialize'))
  _load_code, load_err = Bc2cppFixtureRuntime.generate(ctor_source + "\nGame::CtorFactory.make(1)\n", File.join(dir, 'load-constructors'), core: true, drop_native: ['/mruby-rgss/src/'])
  check.call('a constructor caller that runs during load preserves the initializer', !InitializerTables.proven([{ err: load_err }]).include?('Game::CtorLeaf#initialize'))
  _foreign_code, foreign_err = Bc2cppFixtureRuntime.generate(ctor_source, File.join(dir, 'foreign-constructors'), core: true,
                                                            foreign: [['ctor_foreign.rb', 'module ForeignCtor; def self.make(klass, value); klass.new(value); end; end']],
                                                            drop_native: ['/mruby-rgss/src/'])
  check.call('an unmodeled foreign constructor refuses initializer omission', InitializerTables.proven([{ err: foreign_err }]).empty?)
  saved_extra = ENV['BC2CPP_UNREGISTERED_EXTRA']
  begin
    ENV['BC2CPP_UNREGISTERED_EXTRA'] = ctor_keys.to_a.join(',')
    omitted_dir = File.join(dir, 'omitted-constructors')
    _omitted, omitted_err = Bc2cppFixtureRuntime.generate(ctor_source, omitted_dir, core: true, drop_native: ['/mruby-rgss/src/'])
    ctor_built, ctor_output = Bc2cppFixtureRuntime.run(omitted_dir, omitted_err, ['Game::CtorLeaf', 'Game::CtorFactory.singleton'], <<~CPP, build: Bc2cppFixtureRuntime.full_or_build, full: true)
      static int scenario(mrb_state* M) {
        if (compiled) bc2cpp_register_owner_methods(M);
        mrb_value game = mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "Game"));
        mrb_value factory = mrb_const_get(M, game, mrb_intern_lit(M, "CtorFactory"));
        for (const char* name : {"make", "child"}) {
          mrb_value object = mrb_funcall(M, factory, name, 1, mrb_int_value(M, 47));
          if (M->exc) return 1;
          call(M, "constructed", object, "value");
        }
        struct RClass* leaf = mrb_class_ptr(mrb_const_get(M, game, mrb_intern_lit(M, "CtorLeaf")));
        struct RClass* definer = leaf;
        mrb_method_search_vm(M, &definer, mrb_intern_lit(M, "initialize"));
        return M->exc || (compiled ? definer == leaf : definer != leaf) ? 1 : 0;
      }
    CPP
    warn ctor_output unless ctor_built
    check.call('direct and inherited construction work with the initializer physically absent from its table',
               ctor_built && ctor_output.scan('constructed => 47').size == 4)
  ensure
    saved_extra ? ENV['BC2CPP_UNREGISTERED_EXTRA'] = saved_extra : ENV.delete('BC2CPP_UNREGISTERED_EXTRA')
  end

  native_source = File.join(dir, 'selected.c')
  pi = File.join(dir, 'selected.pi')
  depfile = File.join(dir, 'selected.d')
  inventory_path = File.join(dir, 'native-inventory.json')
  File.write(native_source, <<~'C')
    #define MRB_NATIVE_ONLY 1
    #define MRB_SYM(name) <@! #name !@>
    #define UNUSED_LOOKUP mrb_funcall(0, 0, "qr9z_macro", 0)
    #ifndef MRB_NATIVE_ONLY
    void compiler() { mrb_funcall(0, 0, "qr9z_compiler", 0); }
    #endif
    const mrb_mt_entry methods[] = {{0, MRB_SYM(qr9z_definition), 0}};
    void runtime() { mrb_funcall(0, 0, "qr9z_runtime", 0); mrb_funcall_id(0, 0, MRB_SYM(qr9z_tag), 0); }
  C
  abort 'fixture preprocessing failed' unless system('gcc', '-E', '-P', '-dD', '-MMD', '-MF', depfile, native_source, '-o', pi)
  NativeInventory.export([{ 'source' => native_source, 'preprocessed' => pi, 'depfile' => depfile }], inventory_path)
  inventory = NativeInventory.read(inventory_path)
  build_dir = File.join(dir, 'closed')
  FileUtils.mkdir_p(build_dir)
  gem_name = BC2CPP_COMPILED_GEMS.keys.first
  gem_dir = File.join(root, gem_name)
  registration = File.join(gem_dir, 'src/register.cxx')
  shard = File.join(build_dir, 'example_gen_shard1.cpp')
  File.write(shard, '// modeled Ruby')
  selected_pi = File.join(build_dir, 'selected.pi')
  Rake::FileTask.define_task(selected_pi => [native_source]) do
    abort 'fixture preprocessing failed' unless system('gcc', '-E', '-P', '-dD', '-MD', '-MF', "#{selected_pi}.inventory.d", native_source, '-o', selected_pi)
  end
  excluded = [registration, shard].map.with_index do |source, index|
    path = File.join(build_dir, "excluded#{index}.pi")
    Rake::FileTask.define_task(path => [source]) { raise 'modeled Ruby unit was preprocessed' }
    path
  end
  list = File.join(build_dir, 'presym')
  Rake::FileTask.define_task(list => [selected_pi, *excluded])
  compiler = Struct.new(:preprocess_options).new('-E')
  gem = Struct.new(:name, :dir, :compilers).new(gem_name, gem_dir, [])
  build = Struct.new(:build_dir, :presym, :exts, :compilers, :gems).new(
    build_dir, Struct.new(:list_path).new(list), Struct.new(:presym_preprocessed).new('.pi'), [compiler], [gem]
  )
  build_inventory = File.join(dir, 'build-inventory.json')
  NativeInventory.export_build(build, build_inventory)
  check.call('build inventory excludes compiled registration wrappers and generated Ruby shards',
             NativeInventory.read(build_inventory).fetch('units').map { |unit| unit.fetch('source') } == [native_source])
  check.call('inventory export restores compiler preprocessing options', compiler.preprocess_options == '-E')
  native_names = inventory.fetch('units').first.fetch('names')
  check.call('preprocessed inventory retains active calls and presym-tag names', %w[qr9z_runtime qr9z_tag].all? { |name| native_names.include?(name) })
  check.call('disabled compiler code, macro definitions and ROM destinations are not lookup roots',
             %w[qr9z_compiler qr9z_macro qr9z_definition].none? { |name| native_names.include?(name) })
  dynamic_table = 'const mrb_mt_entry rows[] = {{factory(), <@! "qr9z_dynamic_table" !@>, 0}};'
  check.call('unrecognized executable table initializers remain conservative input', NativeInventory.clean(dynamic_table).include?('qr9z_dynamic_table'))
  unlinked = File.join(dir, 'unlinked.c')
  File.write(unlinked, 'void unused() { mrb_funcall(0, 0, "qr9z_unlinked", 0); }')
  saved_inventory = ENV['BC2CPP_NATIVE_INVENTORY']
  saved_main = ENV['BC2CPP_MAIN_AST']
  begin
    ENV['BC2CPP_NATIVE_INVENTORY'] = inventory_path
    build_ast.call
    ENV['BC2CPP_MAIN_AST'] = ast
    generated = File.join(dir, 'profile_gen.cpp')
    Rake::FileTask.define_task(native_source => [generated])
    Rake::FileTask.define_task(generated => bc2cpp_main_prerequisites) { File.write(generated, '// generated') }.invoke
    check.call('profile generation avoids reverse edges through native registration sources', File.file?(generated))
    selected_roots = MainRoots::Result.new(names: Set.new, functions: Set.new, refusals: [], native_paths: Set.new)
    selected = MainReachability.analyze(alias_ireps, alias_defs, selected_roots, native_paths: [native_source, unlinked],
                                         prunable_keys: alias_keys, seed_named: false, trace: true)
    check.call('reachability consumes selected preprocessing instead of raw or unlinked branches',
               selected.refusals.empty? && selected.names.include?('qr9z_runtime') &&
               !selected.names.include?('qr9z_compiler') && !selected.names.include?('qr9z_unlinked'))
    check.call('preprocessed retention evidence records its selected source',
               selected.reasons.fetch('qr9z_runtime').any? { |reason| reason[:kind] == 'native_preprocessed' && reason[:source] == native_source })
  ensure
    saved_inventory ? ENV['BC2CPP_NATIVE_INVENTORY'] = saved_inventory : ENV.delete('BC2CPP_NATIVE_INVENTORY')
    saved_main ? ENV['BC2CPP_MAIN_AST'] = saved_main : ENV.delete('BC2CPP_MAIN_AST')
  end
  File.write(native_source, File.read(native_source) + "\n// changed\n")
  stale_inventory = false
  begin
    NativeInventory.read(inventory_path)
  rescue RuntimeError => e
    stale_inventory = e.message.include?('stale preprocessed native inventory')
  end
  check.call('source changes invalidate the preprocessed inventory', stale_inventory)

  native = File.join(dir, 'native.cpp')
  File.write(native, <<~CPP)
    #include "host.h"
    static void qr9z_forward(const char* name) { mrb_funcall(0, 0, name, 0); }
    void qr9z_library_boot() { qr9z_forward("qr9z_forwarded"); }
    namespace {
      void qr9z_internal(const char* name) { mrb_funcall(0, 0, name, 0); }
    }
    void qr9z_internal_boot() { qr9z_internal("qr9z_internal_name"); }
  CPP
  build_ast.call([native])
  covered = MainRoots.read(ast)
  check.call('native helper parameters are bounded by their direct callers', covered.names.include?('qr9z_forwarded') && covered.refusals.empty?)
  check.call('anonymous-namespace helpers also have finite internal callers', covered.names.include?('qr9z_internal_name') && covered.refusals.empty?)
  check.call('the manifest records analyzed native units', covered.native_paths.include?(File.realpath(native)))

  File.write(header, File.read(header) + "\n// changed\n")
  stale = false
  begin
    MainRoots.read(ast)
  rescue RuntimeError => e
    stale = e.message.include?('stale host AST')
  end
  check.call('changed included headers invalidate the AST', stale)
  File.write(host, <<~CPP)
    #include "host.h"
    int main(int argc, char** argv) { return mrb_funcall(0, 0, argv[argc - 1], 0); }
  CPP
  build_ast.call
  check.call('a name from runtime input refuses pruning', MainRoots.read(ast).refusals.any?)
  File.write(host, <<~CPP)
    #include "host.h"
    int main(int argc, char**) {
      const char* name = "first";
      if (argc) name = "second";
      return mrb_funcall(0, 0, name, 0);
    }
  CPP
  build_ast.call
  check.call('a reassigned name refuses pruning', MainRoots.read(ast).refusals.any?)
  File.write(host, <<~CPP)
    #include "host.h"
    int main(int argc, char** argv) {
      auto fn = mrb_funcall;
      return fn(0, 0, argv[argc - 1], 0);
    }
  CPP
  build_ast.call
  check.call('an indirect Ruby bridge refuses pruning', MainRoots.read(ast).refusals.any?)

  File.write(host, <<~CPP)
    #include "host.h"
    struct Base { virtual void notify() = 0; };
    struct Callback : Base {
      int field = mrb_funcall(0, 0, "qr9z_field", 0);
      void notify() { mrb_funcall(0, 0, "qr9z_virtual", 0); }
    };
    extern void invoke(Base*);
    int main() { Callback object; invoke(&object); }
  CPP
  build_ast.call
  object_roots = MainRoots.read(ast)
  check.call('virtual callbacks and default member initializers survive opaque native calls',
             object_roots.names.include?('qr9z_virtual') && object_roots.names.include?('qr9z_field'))

  File.write(host, <<~CPP)
    #include "host.h"
    typedef unsigned short mrb_sym;
    enum mruby_presym { MRB_SYM__qr9z_symbol = 1 };
    extern int mrb_funcall_id(void*, int, mrb_sym, int);
    extern mrb_sym mrb_intern_static(void*, const char*, unsigned long);
    int main() {
      mrb_funcall(0, 0, "", 0);
      mrb_funcall_id(0, 0, MRB_SYM__qr9z_symbol, 0);
      mrb_funcall_id(0, 0, mrb_intern_static(0, "qr9z_short_suffix", sizeof("qr9z_short") - 1), 0);
    }
  CPP
  build_ast.call
  symbol_roots = MainRoots.read(ast)
  check.call('empty strings, presyms and length-bounded interned names are resolved',
             symbol_roots.refusals.empty? && ['', 'qr9z_symbol', 'qr9z_short'].all? { |name| symbol_roots.names.include?(name) })

  native_dir = File.join(dir, 'native-vm')
  FileUtils.mkdir_p(native_dir)
  programs = [1, 2].map { |id| { 'id' => id, 'symbol' => "probe_#{id}", 'instructions' => [[0, 1, 'RETURN', [0]]] } }
  File.write(File.join(native_dir, 'programs.json'), JSON.generate(programs))
  pi = File.join(dir, 'active.pi')
  File.write(pi, "static const struct mrb_native_irep live_native_0 = {1u,0,NULL};\n")
  dispatch = File.join(dir, 'dispatch.inc')
  NativeVM.dispatch(native_dir, dispatch, active_ids: NativeVM.referenced_ids([pi]))
  check.call('stale continuation descriptors do not survive absent C++ metadata',
             File.read(dispatch).include?('case 1u:') && !File.read(dispatch).include?('case 2u:'))
  missing = false
  begin
    NativeVM.dispatch(native_dir, dispatch, active_ids: Set[3])
  rescue RuntimeError => e
    missing = e.message.include?('lacks descriptors')
  end
  check.call('an active continuation without a descriptor fails at build time', missing)
  File.write(pi, "inline const struct mrb_native_irep shared_native_0 = {2u,0,NULL};\n")
  check.call('sharded inline continuation metadata is retained', NativeVM.referenced_ids([pi]) == Set[2])
end
puts "main roots: #{checks} checks passed"
