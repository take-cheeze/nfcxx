#!/usr/bin/env ruby
# encoding: UTF-8
# Interface tables: shared adapters, safe misses, and memo reset across VMs (ADR 0328).
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

CLASSES = (0...5).map { |i| "class It#{i}; def join(v = 5); v + #{i}; end; end" }.join("\n")
SOURCE = <<~RUBY
  #{CLASSES}
  class Array; end
  class ItSub < It0; end
  class ItOverride < It1; def join(v = 5); 99; end; end
  class ItAcc
    attr_accessor :join
    def initialize; @join = 7; end
  end
  class ItPrivate
    private
    def join; 44; end
  end
  class ItWrong; def join(a, b); 66; end; end
  class ItMiss; end
  class ItSmallA; def small; 1; end; end
  class ItSmallB; def small; 2; end; end
  class ItProbe
    def go(x); x.join; end
    def again(x); x.join; end
    def arg(x, v); x.join(v); end
    def small(x); x.small; end
    def block(x); x.join { 3 }; end
  end
RUBY
OWNERS = %w[It0 It1 It2 It3 It4 ItSub ItOverride ItAcc ItPrivate ItWrong ItMiss ItSmallA ItSmallB ItProbe].freeze
body = ->(code, fn) { code[/^mrb_value ItProbe_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
saved = ENV['BC2CPP_INTERFACE_TABLES']
begin
  Dir.mktmpdir do |dir|
    generate = lambda do |source = SOURCE, closed = true, enabled = '1'|
      ENV['BC2CPP_INTERFACE_TABLES'] = enabled
      runtime.generate(source, dir, closed: closed, only_owners: OWNERS)
    end
    off, = generate.call(SOURCE, true, '0')
    default, = generate.call(SOURCE, true, nil)
    check.call('disabled and default output are byte-identical and contain no interface tables',
               off == default && !off.include?('INTERFACE_TABLE'))
    code, err = generate.call
    go = body.call(code, 'go')
    table = go[/INTERFACE_TABLE :join\/0 -> (bc2cpp_poly_table_\d+)/, 1]
    check.call('five implementations automatically generate a table', !table.nil?)
    check.call('sites with the same method and arity share the table',
               table && body.call(code, 'again').include?("#{table})) {"))
    check.call('different arities use distinct adapters and tables',
               body.call(code, 'arg').include?('INTERFACE_TABLE :join/1') &&
               !body.call(code, 'arg').include?("#{table})) {"))
    argument_table = body.call(code, 'arg')[/INTERFACE_TABLE :join\/1 -> (bc2cpp_poly_table_\d+)/, 1]
    argument_rows = code[/static const bc2cpp_poly_entry #{argument_table}_rows\[\] = \{(.*?)\};/m, 1].to_s
    check.call('an argument-guarded Array native stays outside the table', !argument_rows.include?('// Array'))
    check.call('short chains and block calls retain their previous dispatch',
               !body.call(code, 'small').include?('INTERFACE_TABLE') && !body.call(code, 'block').include?('INTERFACE_TABLE'))
    rows = code[/static const bc2cpp_poly_entry #{table}_rows\[\] = \{(.*?)\};/m, 1].to_s
    check.call('table covers inherited methods, overrides, accessors and audited Array#join',
               %w[ItSub ItOverride ItAcc Array].all? { |klass| rows.include?("// #{klass}\n") })
    check.call('private methods and wrong arities are not table cells',
               !rows.include?('// ItPrivate') && !rows.include?('// ItWrong'))
    check.call('uniform adapters carry optional argument defaults and supplied counts',
               code.match?(/return It0_join_impl\(M, recv, mrb_nil_value\(\), 0\);/) &&
               code.match?(/return It0_join_impl\(M, recv, arg0, 1\);/))
    # The miss is the call checked against join's outside owners (ADR 0468): Array#join and the rest stay reachable.
    check.call('table misses retain the checked fallback',
               go.include?('CLOSED_WORLD owner-call: join') && go.match?(/BC2CPP_OWNERS\([^)]*"Array"/))
    open_code, = generate.call(SOURCE, false)
    check.call('an open world does not use interface tables', !open_code.include?('INTERFACE_TABLE'))
    singleton, = generate.call("#{SOURCE}\nclass ItProbe; def single(o); def o.join; 88; end; end; end\n")
    check.call('singleton makers withdraw the table proof', !singleton.include?('INTERFACE_TABLE'))
    installer, = generate.call("#{SOURCE}\nclass It0; alias_method :join, :initialize; end\n")
    check.call('a runtime alias of the name withdraws its tables', !installer.include?('INTERFACE_TABLE :join'))
    override, = generate.call("#{SOURCE}\nclass Array; def join; 55; end; end\n")
    check.call('a Ruby override withdraws the native Array cell', !override.include?('return mrb_ary_join(M, recv,'))

    hidden, = generate.call("#{SOURCE}\nclass Array; private :join; end\n")
    check.call('a visibility change withdraws the table', !hidden.include?('INTERFACE_TABLE :join'))
    rebound, = generate.call("#{SOURCE}\nArray = It0\n")
    check.call('a rebound Array constant is not a native table cell', !rebound.include?('return mrb_ary_join(M, recv,'))
    prepended, = generate.call("#{SOURCE}\nmodule ItShade; def join(v = 5); 77; end; end\nclass It0; prepend ItShade; end\n")
    prepended_rows = prepended.scan(/static const bc2cpp_poly_entry .*?_rows\[\] = \{(.*?)\};/m).flatten.join
    check.call('a prepended method is not bypassed by an original-class or inherited cell',
               !prepended_rows.include?('// It0') && !prepended_rows.include?('// ItSub'))
    setters = (0...5).map { |i| "class Is#{i}; def x=(v); v; end; end" }.join("\n")
    integer_args, = generate.call("#{SOURCE}\n#{setters}\nclass ItProbe; def setter(x, v); x.x = v; end; end\n")
    check.call('native integer coercion stays outside uniform table adapters',
               !integer_args.match?(/return rgss::(?:object_x_set_direct|rect_x_set_direct)\(/))

    code, err = generate.call
    if runtime.core && runtime.compiler? && ENV['IT_GENERATED_ONLY'] != '1'
      scenario = <<~CPP
        static int scenario(mrb_state* M) {
          if (compiled) {
            struct RProc* reader = mrb_proc_new_cfunc(M, ItAcc_join);
            reader->flags |= MRB_PROC_NOARG;
            mrb_method_t method;
            MRB_METHOD_FROM_PROC(method, reader);
            mrb_define_method_raw(M, mrb_class_get(M, "ItAcc"), mrb_intern_lit(M, "join"), method);
          }
          mrb_value p = mrb_obj_new(M, mrb_class_get(M, "ItProbe"), 0, nullptr);
          const char* classes[] = {"It0", "It4", "ItSub", "ItOverride", "ItAcc", "ItPrivate", "ItWrong", "ItMiss"};
          for (const char* klass : classes) {
            mrb_value x = mrb_obj_new(M, mrb_class_get(M, klass), 0, nullptr);
            call(M, klass, p, "go", 1, &x);
            call(M, klass, p, "again", 1, &x);
            mrb_value args[] = {x, mrb_int_value(M, 8)};
            call(M, klass, p, "arg", 2, args);
          }
          mrb_value a = mrb_ary_new(M);
          mrb_ary_push(M, a, mrb_str_new_cstr(M, "a"));
          mrb_ary_push(M, a, mrb_str_new_cstr(M, "b"));
          call(M, "array", p, "go", 1, &a);
          call(M, "array memo", p, "again", 1, &a);
          mrb_value args[] = {a, mrb_str_new_cstr(M, ",")};
          call(M, "array separator", p, "arg", 2, args);
          mrb_full_gc(M);
          call(M, "array after GC", p, "go", 1, &a);
          return 0;
        }
      CPP
      # Preserve mruby's attr_reader NOARG flag; the helper registers C entries as MRB_ARGS_ANY.
      built, output = runtime.run(dir, err, OWNERS, scenario, build: runtime.core, vms: [false, true, true])
      check.call('fixture builds against real mruby', built)
      puts output
      sections = output.split(/^== (?:interpreted|compiled)\n/).drop(1)
      values = ->(s) { s.lines.reject { |l| l.start_with?('  ') }.join }
      check.call('values and exceptions match the interpreter across two compiled VMs',
                 built && sections.size == 3 && sections.drop(1).all? { |s| values.call(s) == values.call(sections.first) })
      check.call('Ruby, inherited, accessor and native table hits make zero by-name calls',
                 built && sections.drop(1).all? do |s|
                   %w[It0 It4 ItSub ItOverride ItAcc array].all? { |label| s.match?(/^#{label} => .*\n  dispatches=0$/) }
                 end)
    else
      puts '  SKIP runtime: needs patched libmruby_core.a (BC2CPP_MRUBY_CORE) and C++ compiler'
    end
  end
ensure
  ENV['BC2CPP_INTERFACE_TABLES'] = saved
end
abort "interface tables: #{failures.size} failure(s): #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp interface tables check: PASS'
