#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/main_roots'
require_relative '../../tools/bc2cpp/main_reachability'
require_relative '../../tools/bc2cpp/native_vm'
require_relative '../../tools/bc2cpp/bc2cpp'

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
