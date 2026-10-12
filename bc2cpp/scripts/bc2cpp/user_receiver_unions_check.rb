#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'fixture_runtime'

SOURCE = <<~RUBY_SOURCE
  class UfResultA
    def tag; :a; end
  end
  class UfResultB
    def tag; :b; end
  end
  class UfLeft
    def user_result; UfResultA.new; end
  end
  class UfRight
    def user_result; UfResultB.new; end
  end
  class UfCommon
    def share(value); self.helper(value); end
    def helper(value); [value]; end
  end
  class UfCommonChild < UfCommon
    def helper(value); [value, value]; end
  end
  class UfCommonChild2 < UfCommon; end
  class UfOtherShare
    def share(value); [value, value, value]; end
  end
  class UfWrongArity
    def share(value, extra); [value, extra]; end
  end
  class UfBase
    def payload(value); value; end
    def run; payload([1]).size; end
    def poison(value); payload(value); end
  end
  class UfChild < UfBase
    def payload(value); [1, 2]; end
  end
  class UfDifferent < UfBase
    def payload(value); "different"; end
  end
  class UfAgree
    def payload(value); value; end
    def run; payload([1]).size; end
    def poison(value); payload(value); end
  end
  class UfAgreeChild < UfAgree
    def payload(value); [1, 2]; end
  end
  class UfAgreeChild2 < UfAgree
    def payload(value); [3]; end
  end
  class UfUnknown
    def payload(value); value; end
    def poison(value); payload(value); end
  end
  class UfCtor
    def self.new; UfUnknown.new; end
    def payload(value); [1]; end
  end
  class UfAlloc
    def self.allocate; UfUnknown.new; end
    def payload(value); [1]; end
  end
  class UfMissing; end
  class UfWide
    def payload(value); value; end
    def run; payload([1]).size; end
    def poison(value); payload(value); end
  end
  #{(1..8).map { |n| "class UfWide#{n} < UfWide; end" }.join("\n")}
  class UfFixture
    def direct(flag); value = flag ? UfCommonChild.new : UfCommonChild2.new; value.share(4).size; end
    def direct_disagree(flag); value = flag ? UfCommonChild.new : UfOtherShare.new; value.share(4).size; end
    def direct_missing(flag); value = flag ? UfCommonChild.new : UfMissing.new; value.share(4).size; end
    def direct_wrong_arity(flag); value = flag ? UfCommonChild.new : UfWrongArity.new; value.share(4).size; end
    def direct_nilable(flag); value = flag ? UfCommonChild.new : UfCommonChild2.new; value = nil if @uf_nil; value.share(4).size; end
    def user_disagree(flag); value = flag ? UfLeft.new : UfRight.new; value.user_result.tag; end
    def control(flag); @uf_nil = flag; @uf_other = flag; end
    def constructor_override; UfCtor.new.payload([1]).size; end
    def allocate_override; UfAlloc.new.payload([1]).size; end
    def agree(flag); value = flag ? UfAgreeChild2.new : UfAgreeChild.new; value.payload([1]).size; end
    def disagree(flag); value = flag ? UfChild.new : UfDifferent.new; value.payload([1]).size; end
    def nilable(flag); value = flag ? UfAgreeChild.new : UfAgreeChild2.new; value = nil if @uf_nil; value.payload([1]).size; end
    def unknown(other); value = @uf_nil ? UfAgreeChild.new : UfAgreeChild2.new; value = other if @uf_other; value.payload([1]).size; end
    def missing(flag); value = flag ? UfAgree.new : UfMissing.new; value.payload([1]).size; end
  end
RUBY_SOURCE
OWNERS = %w[UfResultA UfResultB UfLeft UfRight UfCommon UfCommonChild UfCommonChild2 UfOtherShare UfWrongArity UfBase UfChild UfDifferent UfAgree UfAgreeChild UfAgreeChild2 UfUnknown UfCtor UfCtor.singleton UfAlloc UfAlloc.singleton UfMissing UfWide UfFixture] + (1..8).map { |n| "UfWide#{n}" }
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end
abort 'SKIP: set MRBC' unless ENV['MRBC']
runtime = Bc2cppFixtureRuntime
exact = lambda do |code, owner, name|
  body = code[/mrb_value #{owner}_#{name}_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s
  !body.empty? && body.include?('CLOSED_WORLD_NATIVE_EXACT :size ->')
end
Dir.mktmpdir('user-unions') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  if ENV['UF_KEEP_DIR']
    FileUtils.mkdir_p(ENV['UF_KEEP_DIR'])
    File.write(File.join(ENV['UF_KEEP_DIR'], 'fixture.cxx'), code)
    File.write(File.join(ENV['UF_KEEP_DIR'], 'fixture.stderr'), err)
  end
  enabled = ENV['BC2CPP_USER_RECEIVER_UNIONS'] != '0'
  contextual = enabled && ENV['BC2CPP_CALL_CONTEXT_RESULTS'] != '0'
  direct = ->(generated, name) { generated[/mrb_value UfFixture_#{name}_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s.include?('USER_RECEIVER_UNION :share ->') }
  check.call('shared body called directly', direct.call(code, 'direct') == enabled)
  cases = ->(generated, name) { generated[/mrb_value UfFixture_#{name}_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s.include?('USER_RECEIVER_CASES :share') }
  check.call('different bodies use exhaustive direct cases', cases.call(code, 'direct_disagree') == enabled)
  check.call('missing method retains dispatch', !cases.call(code, 'direct_missing') && !direct.call(code, 'direct_missing'))
  check.call('wrong arity retains dispatch', !cases.call(code, 'direct_wrong_arity') && !direct.call(code, 'direct_wrong_arity'))
  check.call('nilable direct receiver retains dispatch', !direct.call(code, 'direct_nilable'))
  check.call('receiver union agrees' , exact.call(code, 'UfFixture', 'agree') == contextual)
  check.call('lexical family agrees', exact.call(code, 'UfAgree', 'run') == contextual)
  disagree_body = code[/mrb_value UfFixture_user_disagree_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s
  check.call('different user results stay unresolved', !disagree_body.empty? && !disagree_body.include?('EXACT_CLASS :tag ->'))
  check.call('lexical override differs' , !exact.call(code, 'UfBase', 'run'))
  check.call('wide family stays unresolved', !exact.call(code, 'UfWide', 'run'))
  %w[disagree nilable unknown missing constructor_override allocate_override].each do |name|
    check.call("#{name} stays unresolved", !exact.call(code, 'UfFixture', name))
  end
  outside = File.join(dir, 'outside')
  FileUtils.mkdir_p(File.join(outside, 'uf-foreign/mrblib'))
  foreign_code, = runtime.generate(SOURCE, outside, only_owners: OWNERS,
                                  foreign: [['uf-foreign/mrblib/payload.rb', 'class UfAgreeChild; def payload(value); Object.new; end; end'],
                                            ['uf-foreign/mrblib/share.rb', 'class UfCommonChild; def share(value); [99]; end; end']],
                                  build_gems: [['uf-foreign', File.join(outside, 'uf-foreign')]])
  omitted_code, = runtime.generate(SOURCE, File.join(dir, 'omitted'), only_owners: OWNERS - ['UfCommon'])
  check.call('unemitted shared body retains dispatch', !direct.call(omitted_code, 'direct'))
  check.call('unemitted case body retains dispatch', !cases.call(omitted_code, 'direct_disagree'))
  check.call('outside replacement withdraws direct call' , !direct.call(foreign_code, 'direct'))
  check.call('outside replacement withdraws union', !exact.call(foreign_code, 'UfFixture', 'agree'))
  check.call('opaque descendant withdraws lexical family', !exact.call(foreign_code, 'UfAgree', 'run'))
  unless ENV['UF_GENERATED_ONLY'] == '1'
    build = runtime.full_or_build
    if build
      harness = <<~CPP
        static int scenario(mrb_state* M) {
          mrb_value obj = mrb_obj_new(M, mrb_class_get(M, "UfFixture"), 0, nullptr);
          for (mrb_value flag : {mrb_true_value(), mrb_false_value()}) {
            call(M, "control", obj, "control", 1, &flag);
            for (const char* name : {"agree", "disagree", "user_disagree", "nilable", "missing", "direct", "direct_disagree", "direct_nilable", "direct_missing", "direct_wrong_arity"})
              call(M, name, obj, name, 1, &flag);
          }
          for (const char* name : {"constructor_override", "allocate_override"})
            call(M, name, obj, name);
          mrb_value unknown_flag = mrb_true_value();
          call(M, "control", obj, "control", 1, &unknown_flag);
          for (const char* klass : {"UfBase", "UfChild", "UfDifferent", "UfAgree", "UfAgreeChild", "UfAgreeChild2", "UfWide", "UfWide8"}) {
            mrb_value value = mrb_obj_new(M, mrb_class_get(M, klass), 0, nullptr);
            call(M, klass, value, "run");
            call(M, "unknown", obj, "unknown", 1, &value);
          }
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err, OWNERS, harness, build: build, full: true)
      sections = runtime.sections(output).transform_values { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
      check.call('runtime parity', built && sections['compiled'] == sections['interpreted'])
      warn output unless built && sections['compiled'] == sections['interpreted']
    else
      puts 'SKIP runtime: no full-core build'
    end
  end
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp user receiver unions check: PASS'
