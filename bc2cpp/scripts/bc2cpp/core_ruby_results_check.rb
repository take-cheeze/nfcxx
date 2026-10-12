#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'fixture_runtime'

SOURCE = <<~RUBY
  class KrOther
    def size; 91; end
  end
  class KrRunner
    def mixed(flag); value = flag ? [1, 2, 3] : {a: 1, b: 2}; value.size; end
    def mixed_other(flag); value = flag ? [1, 2, 3] : {a: 1, b: 2}; value = KrOther.new if flag; value.size; end
    def mixed_nil(flag); value = flag ? [1, 2, 3] : {a: 1, b: 2}; value = nil if flag; value.size; end
    def mixed_map(flag); value = flag ? [1, 2] : {a: 1, b: 2}; value.map { |x| x }.size; end
    def mixed_map_other(flag); value = flag ? [1, 2] : KrOther.new; value.map { |x| x }.size; end
    def mixed_map_break(flag); value = flag ? [1, 2] : {a: 1}; value.map { |x| break KrOther.new }.size; end
    def reject_map(input); input.reject { |x| false }.map { |x| x }.compact.size; end
    def select_map(input); input.select { |x| true }.map { |x| x }.compact.size; end
    def unknown_reject(input); input.reject { |x| false }.size; end
    def unknown_filter(input); input.filter_map { |x| true }.size; end
    def unknown_break(input); input.filter_map { |x| break KrOther.new }.size; end
    def mapped; [1, 2].map { |x| x + 1 }.size; end
    def collected; [1, 2].collect { |x| x }.size; end
    def selected; [1, 2].select { |x| x == 1 }.size; end
    def found; [1, 2].find_all { |x| x == 1 }.size; end
    def rejected; [1, 2].reject { |x| x == 1 }.size; end
    def hash_map; {a: 1, b: 2}.map { |k, v| v }.size; end
    def range_map; (1..3).map { |x| x }.size; end
    def next_value; [1, 2].map { |x| next KrOther.new }.size; end
    def breaking; [1, 2].map { |x| break KrOther.new }.size; end
    def nested_break; [1, 2].map { |x| [1].each { break KrOther.new }; x }.size; end
    def nonlocal_return; [1, 2].map { |x| return KrOther.new }.size; end
    def forwarded(&block); [1, 2].map(&block).size; end
    def no_block; [1, 2].map.size; end
    def merged_block(flag, &block)
      chosen = flag ? proc { |x| x } : block
      [1, 2].map(&chosen).size
    end
    def keyword; [1, 2].map(extra: 1) { |x| x }.size; end
    def splat(args); [1, 2].map(*args) { |x| x }.size; end
    def entries; [1, 2].entries.size; end
    def deconstructed; [1, 2].deconstruct.size; end
    def hash_identity; {a: 1, b: 2}.to_h.size; end
    def tallied; [1, 1, 2].tally.size; end
    def partitioned; [1, 2].partition { |x| x == 1 }.size; end
    def nil_receiver(flag)
      ary = flag ? nil : [1, 2]
      ary.map { |x| x }.size
    end
    def stored; @items = [1, 2].map { |x| x }; end
    def read; @items.size; end
    def dedup; [1, 1, 2].uniq.size; end
    def dedup_block; [1, 1, 2].uniq { |x| x }.size; end
    def sorted; [3, 1, 2].sort_by { |x| x }.size; end
    def range_sorted; (1..3).to_a.sort_by { |x| -x }.size; end
    def range_strings; ('a'..'c').to_a.size; end
    def range_entries; ('a'..'c').entries.size; end
    def memo_array; [1, 2].each_with_object([]) { |x, out| out << x }.size; end
    def memo_hash; [1, 2].each_with_object({}) { |x, out| out[x] = x }.size; end
    def memo_unknown(input); [1, 2].each_with_object(input) { |x, out| x }.size; end
    def memo_nil; [1, 2].each_with_object(nil) { |x, out| x }.size; end
    def memo_unresolved(input); input.each_with_object([]) { |x, out| out << x }.size; end
    def memo_unresolved_hash(input); input.each_with_object({}) { |x, out| out[x] = x }.size; end
    def memo_unresolved_unknown(input, memo); input.each_with_object(memo) { |x, out| x }.size; end
    def memo_break; [1, 2].each_with_object([]) { |x, out| break KrOther.new }.size; end
    def memo_forwarded(&block); [1, 2].each_with_object([], &block).size; end
    def memo_no_block; [1, 2].each_with_object([]).size; end
    def memo_wrong_arity; [1, 2].each_with_object([], {}) { |x, out| x }.size; end
    def memo_keyword; [1, 2].each_with_object([], extra: 1) { |x, out| x }.size; end
    def memo_splat(args); [1, 2].each_with_object(*args) { |x, out| x }.size; end
    def dropped; [1, 2].drop(1).size; end
    def initialize; @sl = []; end
    # BOTTOM_BLOCK_RECEIVER: the receiver is a name or slot the growth loop has not classed yet when the block send is first run.
    def keys_sel(h); h.keys.select { |x| x }; end
    def keys_sel_size(h); keys_sel(h).size; end
    def sl_sel; @sl = @sl.select { |x| x }; @sl; end
    def sl_sel_size; sl_sel.size; end
    def dropped_unknown(input); input.drop(1).size; end
  end
RUBY
OWNERS = (BC2CPP_CORE_OWNERS + %w[KrOther KrRunner]).freeze
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end
body_of = ->(code, name) { code[/^mrb_value KrRunner_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
exact_size = ->(code, name) { body_of.call(code, name).include?('CLOSED_WORLD_NATIVE_EXACT :size -> Array') }
runtime = Bc2cppFixtureRuntime
root = File.expand_path('../..', __dir__)
core_sources = core_compiled_mrblib_srcs(root, BC2CPP_CANONICAL_CORE_GEMS - BC2CPP_EXTERNAL_MRBLIB_GEMS)
core_inputs = core_sources.map { |path| [path.delete_prefix(root + '/'), File.read(path)] }
worlds = [
  ['core bodies', SOURCE, {}, true],
  ['kill switch', SOURCE, { 'BC2CPP_CORE_RUBY_RESULTS' => '0' }, false],
  ['union kill switch', SOURCE, { 'BC2CPP_NATIVE_EXPRESSION_UNIONS' => '0' }, true],
  ['name kill switch', SOURCE, { 'BC2CPP_CORE_RUBY_NAME_RESULTS' => '0' }, true],
  ['nested kill switch', SOURCE, { 'BC2CPP_CORE_RUBY_NESTED_RESULTS' => '0' }, true],
  ['receiver union kill switch', SOURCE, { 'BC2CPP_CORE_RUBY_RECEIVER_UNIONS' => '0' }, true],
  ['Hash map override', SOURCE + "class Hash; def map(&block); KrOther.new; end; end\n", {}, true],
  ['positional kill switch', SOURCE, { 'BC2CPP_CORE_RUBY_POSITIONAL_RESULTS' => '0' }, true],
  ['positional project override', SOURCE + "class Array; def each_with_object(obj, &block); KrOther.new; end; end\n", {}, true],
  ['positional foreign override', SOURCE + "class KrOther; def each_with_object(obj, &block); self; end; end\n", {}, true],
  ['positional core return', SOURCE, {}, true, nil, "module Enumerable; def each_with_object(obj, &block); KrOther.new; end; end"],
  ['positional core captured write', SOURCE, {}, true, nil, "module Enumerable; def each_with_object(obj, &block); self.each { obj = KrOther.new }; obj; end; end"],
  ['positional optional argument', SOURCE, {}, true, nil, "module Enumerable; def each_with_object(obj, extra = nil, &block); obj; end; end"],
  ['positional core arity', SOURCE, {}, true, nil, "module Enumerable; def each_with_object(obj, other, &block); obj; end; end"],
  ['positional rest argument', SOURCE, {}, true, nil, "module Enumerable; def each_with_object(obj, *rest, &block); obj; end; end"],
  ['positional keyword argument', SOURCE, {}, true, nil, "module Enumerable; def each_with_object(obj, extra: nil, &block); obj; end; end"],
  ['nested project override', SOURCE + "class Array; def collect!(&block); KrOther.new; end; end\n", {}, true],
  ['nested core override', SOURCE, {}, true, nil, "class Array; def collect!(&block); KrOther.new; end; end"],
  ['nested core recursion', SOURCE, {}, true, nil, "class Array; def collect!(&block); self.collect! { |x| x }; end; end"],
  ['nested caller break', SOURCE, {}, true, nil, "class Array; def sort_by(&block); ary = []; ary.collect! { break KrOther.new }; end; end"],
  ['super core override', SOURCE, {}, true, nil, "module Enumerable; def to_a; KrOther.new; end; end"],
  ['super included override', SOURCE + "module KrRangeMixin; def to_a; KrOther.new; end; end; Range.include KrRangeMixin\n", {}, false],
  ['native range switch', SOURCE, { 'BC2CPP_NATIVE_CLASS_RESULTS' => '0' }, true],
  ['project filter override', SOURCE + "class KrOther; def filter_map(&block); self; end; end\n", {}, true],
  ['filter installer', SOURCE + "module Enumerable; define_method(:filter_map) { |&block| KrOther.new }; end\n", {}, true],
  ['filter alias', SOURCE + "class KrOther; alias filter_map size; end\n", {}, true],
  ['native filter definition', SOURCE, {}, true],
  ['foreign filter definition', SOURCE, {}, true],
  ['method missing', SOURCE + "class KrOther; def method_missing(name, *args, &block); self; end; end\n", {}, true],
  ['outside filter definition', SOURCE, {}, true, nil, "class Array; def filter_map(&block); ignored = -> { 1 }; KrOther.new; end; end"],
  ['Array map override', SOURCE + "class Array; def map(&block); KrOther.new; end; end\n", {}, false],
  ['Enumerable alias override', SOURCE + "module Enumerable; def map(&block); KrOther.new; end; end\n", {}, false],
  ['Array prepend', SOURCE + "module KrMixin; def map(&block); KrOther.new; end; end; Array.prepend KrMixin\n", {}, false],
  ['Array include', SOURCE + "module KrMixin; def map(&block); KrOther.new; end; end; Array.include KrMixin\n", {}, false],
  ['alias replacement', SOURCE + "module Enumerable; def other_map(&block); KrOther.new; end; alias map other_map; end\n", {}, false],
  ['dynamic installer', SOURCE + "module Enumerable; define_method(:map) { |&block| KrOther.new }; end\n", {}, false],
  ['changed core return', SOURCE, {}, false, 'def collect(&block); KrOther.new; end'],
  ['core nonlocal return', SOURCE, {}, false, 'def collect(&block); ary = []; self.each { |x| return KrOther.new }; ary; end'],
  ['core captured write', SOURCE, {}, false, 'def collect(&block); ary = []; self.each { |x| ary = KrOther.new }; ary; end'],
  ['core block return', SOURCE, {}, false, 'def collect(&block); block; end'],
  ['interpreted core override', SOURCE, {}, false, nil, "class Array; def map(&block); ignored = -> { 1 }; KrOther.new; end; end"],
  ['conditional core override', SOURCE, {}, false, nil, "class Array; if Object.new; def map(&block); KrOther.new; end; end; end"],
  ['core accessor override', SOURCE, {}, false, nil, "class Array; attr_reader :map; end"],
  ['unmodelled core alias', SOURCE, {}, false, nil, "class Array; alias map size; end"],
  ['conditional core alias', SOURCE, {}, false, nil, "class Array; def different(&block); []; end; if Object.new; alias map different; end; end"],
  ['alias of interpreted core', SOURCE, {}, false, nil, "class Array; def different(&block); ignored = -> { 1 }; KrOther.new; end; alias map different; end"],
  ['core alias_method override', SOURCE, {}, false, nil, "class Array; alias_method :map, :size; end"],
  ['core remove_method override', SOURCE, {}, false, nil, "module Enumerable; remove_method :map; end"],
  ['core helper installer', SOURCE, {}, true, nil, "class Array; alias_method :__uniq, :size; end"],
  ['interpreted core helper', SOURCE, {}, true, nil, "class Array; def __uniq; ignored = -> { 1 }; KrOther.new; end; end"],
  ['core computed installer', SOURCE, {}, false, nil, "class Array; alias_method ('m' + 'ap'), :size; end"],
  ['bottom kill switch', SOURCE, { 'BC2CPP_BOTTOM_BLOCK_RECEIVERS' => '0' }, true],
  ['keys override', SOURCE + "class KrOther; def keys; self; end; end\n", {}, true],
  ['slot store of another class', SOURCE + "class KrRunner; def sl_other; @sl = KrOther.new; end; end\n", {}, true],
  ['open world', SOURCE, {}, false]
]
worlds.select! { |name, _| name == ENV['KRR_CASE'] } if ENV['KRR_CASE']
abort "unknown KRR_CASE: #{ENV['KRR_CASE']}" if worlds.empty?
if ENV['MRBC']
  worlds.each do |name, source, env, proven, core_collect, core_override|
    Dir.mktmpdir do |dir|
      saved = env.to_h { |key, _| [key, ENV[key]] }
      begin
        env.each { |key, value| ENV[key] = value }
        inputs = core_inputs.map do |path, text|
          replacement = core_collect && path.end_with?('/mrblib/enum.rb') ? text.sub(/def collect\(&block\).*?\n  end/m, core_collect) : text
          [path, replacement]
        end
        inputs << ['3rd/mruby/mrbgems/mruby-array-ext/mrblib/zz_override.rb', core_override] if core_override
        native = name == 'native filter definition' ? [['extra.c', 'void replace(mrb_state *mrb, struct RClass *c) { mrb_define_method(mrb, c, "filter_map", replacement, MRB_ARGS_NONE()); }']] : []
        linked = name == 'foreign filter definition' ? [['kr-foreign', File.join(dir, 'kr-foreign')]] : []
        FileUtils.mkdir_p(File.join(dir, 'kr-foreign/mrblib')) unless linked.empty?
        foreign = linked.empty? ? [] : [['kr-foreign/mrblib/outside.rb', 'module Enumerable; def filter_map(&block); Object.new; end; end']]
        code, err = runtime.generate(source, dir, extra: inputs, native: native, foreign: foreign, build_gems: linked, only_owners: OWNERS, closed: name != 'open world')
        check.call("#{name}: mapped result", exact_size.call(code, 'mapped') == proven) unless name == 'filter installer' || name == 'filter alias'
        if ['core bodies', 'kill switch', 'receiver union kill switch', 'Hash map override', 'Array map override', 'Array prepend', 'dynamic installer', 'open world'].include?(name)
          union_proven = name == 'core bodies'
          check.call("#{name}: every union member returns Array", exact_size.call(code, 'mixed_map') == union_proven)
          check.call("#{name}: reject-map-compact chain", exact_size.call(code, 'reject_map') == union_proven)
          check.call("#{name}: unknown union member stays unproved", !exact_size.call(code, 'mixed_map_other'))
          check.call("#{name}: union caller break stays unproved", !exact_size.call(code, 'mixed_map_break'))
          if ['core bodies', 'kill switch'].include?(name)
            check.call('core bodies: union map preserves both receiver paths',
                       !body_of.call(code, 'reject_map').include?('Array receiver for inlined #map'))
            check.call("#{name}: select-map preserves both receiver paths",
                       !body_of.call(code, 'select_map').include?('Array receiver for inlined #map'))
          end
        end
        if name.start_with?('positional ') || ['core bodies', 'kill switch', 'open world', 'name kill switch', 'method missing'].include?(name)
          positional_proven = ['core bodies', 'name kill switch', 'method missing', 'positional foreign override'].include?(name)
          check.call("#{name}: positional Array memo", exact_size.call(code, 'memo_array') == positional_proven)
          check.call("#{name}: positional Hash memo", body_of.call(code, 'memo_hash').include?('CLOSED_WORLD_NATIVE_EXACT :size -> Hash') == positional_proven)
          check.call("#{name}: unresolved receiver memo", exact_size.call(code, 'memo_unresolved') == (name == 'core bodies'))
          check.call("#{name}: unresolved receiver Hash memo", body_of.call(code, 'memo_unresolved_hash').include?('CLOSED_WORLD_NATIVE_EXACT :size -> Hash') == (name == 'core bodies'))
          check.call("#{name}: unresolved unknown memo stays unproved", !exact_size.call(code, 'memo_unresolved_unknown'))
          %w[memo_unknown memo_nil memo_break memo_forwarded memo_no_block memo_keyword memo_splat].each do |method|
            check.call("#{name}: #{method} stays unproved", !exact_size.call(code, method))
          end
          check.call("#{name}: positional call arity", exact_size.call(code, 'memo_wrong_arity') == (name == 'positional core arity'))
          if ['core bodies', 'positional kill switch', 'kill switch', 'open world', 'name kill switch'].include?(name)
            check.call("#{name}: positional drop result", exact_size.call(code, 'dropped') == ['core bodies', 'name kill switch'].include?(name))
            check.call("#{name}: unresolved drop result", exact_size.call(code, 'dropped_unknown') == (name == 'core bodies'))
          end
        end
        if ['core bodies', 'bottom kill switch', 'keys override', 'slot store of another class', 'kill switch', 'open world'].include?(name)
          # A literal-block send on a not-yet-classed receiver waits for the loop instead of dropping the name.
          check.call("#{name}: keys.select enters the return table", err.include?('RETCLASS keys_sel (Array)') == %w[core\ bodies slot\ store\ of\ another\ class].include?(name))
          check.call("#{name}: @sl = @sl.select enters the return table", err.include?('RETCLASS sl_sel (Array)') == %w[core\ bodies keys\ override].include?(name))
        end
        check.call("#{name}: nested sort result", exact_size.call(code, 'sorted') == (name == 'core bodies')) if ['core bodies', 'kill switch', 'nested kill switch', 'nested project override', 'nested core override', 'nested core recursion', 'nested caller break', 'open world'].include?(name)
        if ['core bodies', 'kill switch', 'nested kill switch', 'super core override', 'super included override', 'native range switch', 'open world'].include?(name)
          check.call("#{name}: range helper and super result", exact_size.call(code, 'range_strings') == (name == 'core bodies'))
          check.call("#{name}: range sort result", exact_size.call(code, 'range_sorted') == (name == 'core bodies'))
          check.call("#{name}: aliased super stays unproved", !exact_size.call(code, 'range_entries'))
        end
        if ['core bodies', 'kill switch', 'name kill switch', 'union kill switch', 'project filter override', 'filter installer', 'filter alias', 'outside filter definition', 'native filter definition', 'foreign filter definition', 'method missing', 'open world'].include?(name)
          check.call("#{name}: unknown filter result", exact_size.call(code, 'unknown_filter') == ['core bodies', 'union kill switch'].include?(name))
          check.call("#{name}: unknown break stays unproved", !exact_size.call(code, 'unknown_break'))
          check.call("#{name}: reject joins Array and Hash without dispatch", body_of.call(code, 'unknown_reject').include?('NATIVE_EXPRESSION_UNION :size') == ['core bodies', 'project filter override', 'outside filter definition', 'native filter definition', 'foreign filter definition', 'filter alias'].include?(name))
        end
        check.call("#{name}: helper result stays unproved", !exact_size.call(code, 'dedup')) if %w[core\ helper\ installer interpreted\ core\ helper].include?(name)
        if ['core bodies', 'union kill switch'].include?(name)
          check.call("#{name}: mixed exact classes", body_of.call(code, 'mixed').include?('NATIVE_EXPRESSION_UNION :size') == (name == 'core bodies'))
          check.call("#{name}: unrepresented class keeps dispatch", !body_of.call(code, 'mixed_other').include?('NATIVE_EXPRESSION_UNION :size'))
          check.call("#{name}: nil keeps error path", !body_of.call(code, 'mixed_nil').include?('NATIVE_EXPRESSION_UNION :size'))
        end
        if ['core bodies', 'kill switch', 'positional kill switch', 'positional project override', 'positional foreign override'].include?(name)
          %w[collected selected found rejected hash_map range_map next_value partitioned nil_receiver].each do |method|
            check.call("#{name}: #{method} result", exact_size.call(code, method) == proven)
          end
          %w[hash_identity tallied].each do |method|
            check.call("#{name}: #{method} result", body_of.call(code, method).include?('CLOSED_WORLD_NATIVE_EXACT :size -> Hash') == proven)
          end
          %w[breaking nested_break forwarded no_block merged_block keyword splat entries deconstructed].each do |method|
            check.call("#{name}: #{method} stays unproved", !exact_size.call(code, method))
          end
          check.call("#{name}: stored result pool", exact_size.call(code, 'read') == proven)
        end
        next unless ['core bodies', 'kill switch', 'Hash map override', 'receiver union kill switch', 'positional kill switch', 'positional project override', 'positional foreign override'].include?(name)
        next if ENV['KRR_GENERATED_ONLY'] == '1'
        build = runtime.full_or_build
        unless build
          puts '-- SKIP runtime parity: no full-core mruby build'
          next
        end

        harness = <<~CPP
          static int scenario(mrb_state* M) {
            mrb_value runner = mrb_obj_new(M, mrb_class_get(M, "KrRunner"), 0, nullptr);
            for (const char* name : {"mapped", "collected", "selected", "found", "rejected", "hash_map", "range_map", "next_value", "breaking", "nested_break", "nonlocal_return", "no_block", "dedup", "dedup_block", "sorted", "range_sorted", "range_strings", "hash_identity", "tallied", "partitioned", "memo_array", "memo_hash", "memo_nil", "memo_break", "memo_no_block", "memo_wrong_arity", "memo_keyword", "dropped"}) {
              call(M, name, runner, name);
            }
            for (mrb_value flag : {mrb_true_value(), mrb_false_value()}) {
              call(M, "mixed", runner, "mixed", 1, &flag);
              call(M, "mixed_other", runner, "mixed_other", 1, &flag);
              call(M, "mixed_nil", runner, "mixed_nil", 1, &flag);
              call(M, "mixed_map", runner, "mixed_map", 1, &flag);
              call(M, "mixed_map_other", runner, "mixed_map_other", 1, &flag);
              call(M, "mixed_map_break", runner, "mixed_map_break", 1, &flag);
            }
            mrb_value unknown = mrb_ary_new(M);
            mrb_ary_push(M, unknown, mrb_fixnum_value(1));
            mrb_ary_push(M, unknown, mrb_fixnum_value(2));
            call(M, "unknown_reject", runner, "unknown_reject", 1, &unknown);
            call(M, "reject_map", runner, "reject_map", 1, &unknown);
            call(M, "select_map", runner, "select_map", 1, &unknown);
            call(M, "unknown_filter", runner, "unknown_filter", 1, &unknown);
            call(M, "unknown_break", runner, "unknown_break", 1, &unknown);
            call(M, "memo_unresolved", runner, "memo_unresolved", 1, &unknown);
            call(M, "memo_unresolved_hash", runner, "memo_unresolved_hash", 1, &unknown);
            mrb_value memo_args[] = {unknown, mrb_ary_new(M)};
            call(M, "memo_unresolved_unknown", runner, "memo_unresolved_unknown", 2, memo_args);
            call(M, "dropped_unknown", runner, "dropped_unknown", 1, &unknown);
            call(M, "memo_unknown", runner, "memo_unknown", 1, &unknown);
            unknown = mrb_hash_new(M);
            mrb_hash_set(M, unknown, mrb_fixnum_value(1), mrb_fixnum_value(2));
            call(M, "hash_reject", runner, "unknown_reject", 1, &unknown);
            call(M, "hash_reject_map", runner, "reject_map", 1, &unknown);
            call(M, "hash_select_map", runner, "select_map", 1, &unknown);
            call(M, "stored", runner, "stored");
            call(M, "read", runner, "read");
            for (mrb_value flag : {mrb_true_value(), mrb_false_value()}) {
              call(M, "nil_receiver", runner, "nil_receiver", 1, &flag);
            }
            return 0;
          }
        CPP
        built, output = runtime.run(dir, err, %w[KrOther KrRunner], harness, build: build, full: true)
        sections = runtime.sections(output).transform_values { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
        # Object inspect embeds VM-specific addresses.
        ok = built && sections['compiled'].map { |line| line.gsub(/0x[0-9a-f]+/, 'ADDR') } == sections['interpreted'].map { |line| line.gsub(/0x[0-9a-f]+/, 'ADDR') } && output.include?('breaking => 91')
        check.call("#{name}: compiled/interpreted parity", ok)
        warn output unless ok
      ensure
        saved.each { |key, value| ENV[key] = value }
      end
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp core Ruby results check: PASS'
