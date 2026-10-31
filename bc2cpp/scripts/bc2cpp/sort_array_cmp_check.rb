#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/codegen_sort_array_cmp'

ENV['BC2CPP_SIG_DIRS'] = ''
failures = []
check = lambda do |name, condition|
  puts "#{condition ? 'ok' : 'FAIL'} #{name}"
  failures << name unless condition
end
SOURCE = <<~'RUBY'
  class SortCmp
    def tuples(a); a.sort_by { |x| x }; end
  end
RUBY
Dir.mktmpdir('sort-array-cmp') do |dir|
  code, diagnostics = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: %w[SortCmp])
  check.call('sort calls the direct key helper', code.match?(/bc2cpp_sort_c_\d+ = bc2cpp_sort_key_cmp\(/))
  check.call('only exact Array receivers bypass dispatch', code.include?('mrb_class(M, a) != M->array_class'))
  check.call('elements preserve native comparison dispatch', code.include?('mrb_cmp(M, RARRAY_PTR(a)[i], RARRAY_PTR(b)[i])'))
  saved = ENV['BC2CPP_SORT_ARRAY_CMP']
  ENV['BC2CPP_SORT_ARRAY_CMP'] = '0'
  off, = Bc2cppFixtureRuntime.generate(SOURCE, File.join(dir, 'off'), core: true, only_owners: %w[SortCmp])
  check.call('disable switch keeps the original comparison', !off.include?('bc2cpp_sort_key_cmp(') && off.match?(/bc2cpp_sort_c_\d+ = mrb_cmp\(/))
  saved.nil? ? ENV.delete('BC2CPP_SORT_ARRAY_CMP') : ENV['BC2CPP_SORT_ARRAY_CMP'] = saved
  replaced, = Bc2cppFixtureRuntime.generate(SOURCE + "\nclass Array; def <=>(other); 0; end; end\n", File.join(dir, 'replace'), core: true, only_owners: %w[SortCmp])
  check.call('Array replacement refuses the direct helper', !replaced.include?('bc2cpp_sort_key_cmp('))
  aliased, = Bc2cppFixtureRuntime.generate(SOURCE + "\nclass Array; alias <=> size; end\n", File.join(dir, 'alias'), core: true, only_owners: %w[SortCmp])
  check.call('Array alias replacement refuses the direct helper', !aliased.include?('bc2cpp_sort_key_cmp('))
  prepended, = Bc2cppFixtureRuntime.generate(SOURCE + "\nmodule ReverseCmp; def <=>(other); 0; end; end\nclass Array; prepend ReverseCmp; end\n", File.join(dir, 'prepend'), core: true, only_owners: %w[SortCmp])
  check.call('Array prepend refuses the direct helper', !prepended.include?('bc2cpp_sort_key_cmp('))

  native, = Bc2cppFixtureRuntime.generate(SOURCE, File.join(dir, 'native'), core: true, only_owners: %w[SortCmp], native: [['override.c', 'void init(mrb_state* mrb) { mrb_define_method(mrb, mrb->array_class, "<=>", other_cmp, MRB_ARGS_REQ(1)); }']])
  check.call('native Array replacement refuses the direct helper', !native.include?('bc2cpp_sort_key_cmp('))
  model = CodeGen.allocate
  array_source = File.binread(File.join(Bc2cppFixtureRuntime::ROOT, '3rd/mruby/src/array.c'))
  check.call('the native body and registration match the model', model.sort_array_cmp_source_matches?(array_source))
  check.call('changed comparison body refuses the model', !model.sort_array_cmp_source_matches?(array_source.sub('if (n != 0) return mrb_fixnum_value(n);', 'if (n != 0) return mrb_fixnum_value(-n);')))
  check.call('changed native binding refuses the model', !model.sort_array_cmp_source_matches?(array_source.sub('MRB_MT_ENTRY(mrb_ary_cmp,', 'MRB_MT_ENTRY(other_cmp,')))

  build = Bc2cppFixtureRuntime.full_or_build
  abort 'full-core fixture runtime is required' unless build
  driver = <<~'RUBY'
    class ReverseArray < Array
      def <=>(other); -(self[0] <=> other[0]); end
    end
    class Key
      def initialize(n); @n = n; end
      def <=>(other); GC.start; @n <=> other.number; end
      def number; @n; end
      def inspect; "K#{@n}"; end
    end
    singled = [1]
    def singled.<=>(other); -(self[0] <=> other[0]); end
    singled2 = [2]
    def singled2.<=>(other); -(self[0] <=> other[0]); end
    f = SortCmp.new
    cases = [[], [[2, 1], [1, 9], [1], [1, 9]], [[2.5], [1], []],
             [[Key.new(2)], [Key.new(1)]],
             [ReverseArray.new([1]), ReverseArray.new([2])],
             [[[2]], [[1]]], [singled, singled2], [[1], [nil]], [[1], ["x"]], [3, 1, 2]]
    cases.each do |a|
      begin
        p f.tuples(a)
      rescue ArgumentError => e
        puts "ArgumentError"
      end
    end
    puts 'end'
  RUBY
  body = <<~CPP
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      mrb_load_string(M, R"SORTCMP(#{driver})SORTCMP");
      std::fflush(stdout);
      if (M->exc) { mrb_print_error(M); return 1; }
      return 0;
    }
  CPP
  built, output = Bc2cppFixtureRuntime.run(dir, diagnostics, %w[SortCmp], body, build: build, full: true)
  sections = Bc2cppFixtureRuntime.sections(output)
  check.call('tuple, custom element, subclass and error semantics match mruby', built && sections['interpreted'] == sections['compiled'] && sections['compiled']&.last == 'end')
  puts output unless built && sections['interpreted'] == sections['compiled']
end
abort "sort_array_cmp_check: #{failures.size} failed" unless failures.empty?
puts 'sort_array_cmp_check: passed'
