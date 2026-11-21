#!/usr/bin/env ruby
# frozen_string_literal: true

# INSTALLED_NAME_DEVIRT_GUARD (codegen_runtime_def.rb, installed_name_blocks_devirt?): in a closed world, a name the
# program installs or removes where the registry does not see it (CodeGen#symbol_installed_names) never binds
# statically, and when some installer's name is computed (the list is nil) no name does. Before, MONO and the other
# static binds consulted only the method being compiled, so a `remove_method` with a computed name elsewhere left
# `a.foo` calling the removed body directly. The check generates a program with a literal and one with a computed
# removal, reads the sites, and with a full-core libmruby runs the computed one interpreted and compiled: the call
# after the removal raises NoMethodError in both.
# CORE_ALIAS_DESTINATIONS / CORE_LOOP_ALIASES: with mruby-onig-regexp's Ruby compiled too, its
# `%i[sub gsub split scan].each { |v| alias_method v, :"onig_regexp_#{v}" }` replaces mrblib's String-only String#gsub with
# the C onig_regexp_gsub: that body is neither compiled nor registered, and a String receiver's gsub, exact or not, keeps
# dispatching by name.
# CORE_OUTSIDE_REDEFINED: a linked Ruby source the build does not compile that defines a core method again on the same
# owner (mruby-require's block-taking Hash#to_h over mruby-hash-ext's) leaves the core body neither compiled nor
# registered, and the call dispatches to the method the interpreter ends up with.
# Needs MRBC; the behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('installed_name_devirt_check')
suite.require_mrbc!

def source(removal)
  <<~RUBY
    class IdA
      def foo = 1
      def bar = 2
    end

    class IdDrive
      def go(a) = a.foo
      def other(a) = a.bar
      def kill(cls, name) = #{removal}
    end
  RUBY
end

OWNERS = %w[IdA IdDrive].freeze

def method_code(code, name)
  code[/^mrb_value IdDrive_#{name}_impl\(mrb_state\* M.*?^\}/m].to_s
end

Dir.mktmpdir('bc2cpp-installed-name-devirt') do |dir|
  literal_dir = File.join(dir, 'literal')
  Dir.mkdir(literal_dir)
  code, = Bc2cppFixtureRuntime.generate(source('cls.remove_method(:foo)'), literal_dir, core: true, only_owners: OWNERS)
  suite.check('a literally removed name keeps dispatching by name', !method_code(code, 'go').include?('MONO :foo'))
  suite.check('a name nothing removes still binds MONO', method_code(code, 'other').include?('MONO :bar'))

  computed_dir = File.join(dir, 'computed')
  Dir.mkdir(computed_dir)
  code, err = Bc2cppFixtureRuntime.generate(source('cls.remove_method(name)'), computed_dir, core: true, only_owners: OWNERS)
  suite.check('with a computed removal no name binds MONO',
              %w[go other].none? { |m| method_code(code, m).include?('MONO :') } && !method_code(code, 'go').empty?)

  onig_dir = File.join(dir, 'onig')
  Dir.mkdir(onig_dir)
  onig = <<~RUBY
    class IdGsub
      def literal = "xax".gsub("a", "b")
      def converted(s) = s.to_s.gsub(/a/, "b")
    end
  RUBY
  code, = Bc2cppFixtureRuntime.generate(onig, onig_dir, core: true, only_owners: %w[IdGsub],
                                        core_gems: BC2CPP_CANONICAL_CORE_GEMS + ['mruby-onig-regexp'])
  gsub_code = ->(name) { code[/^mrb_value IdGsub_#{name}_impl\(mrb_state\* M.*?^\}/m].to_s }
  suite.check("mrblib's String#gsub, which mruby-onig-regexp's alias loop replaces, is neither compiled nor registered",
              !code.include?('String_gsub_impl(') && !code.match?(/"\\x67\\x73\\x75\\x62", String_gsub\b/))
  suite.check('an exact String receiver and a converted one both dispatch gsub by name',
              %w[literal converted].all? { |m| gsub_code.call(m).include?('POLY :gsub') })

  shim_dir = File.join(dir, 'shim')
  Dir.mkdir(shim_dir)
  shim = <<~RUBY
    class Hash
      alias __core_to_h to_h

      def to_h(&block)
        return __core_to_h unless block

        result = {}
        each_pair { |k, v| pair = block.call([k, v]); result[pair[0]] = pair[1] }
        result
      end
    end
  RUBY
  code, = Bc2cppFixtureRuntime.generate("class IdShim\n  def go = { a: 1 }.to_h { |k, v| [v, k] }\nend\n", shim_dir,
                                        core: true, only_owners: %w[IdShim], foreign: [['hash_shim.rb', shim]])
  shim_go = code[/^mrb_value IdShim_go_impl\(mrb_state\* M.*?^\}/m].to_s
  suite.check("mruby-hash-ext's Hash#to_h, which a linked outside source defines again, is neither compiled nor registered",
              !code.include?('Hash_to_h_impl(') && !shim_go.empty?)

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP installed name devirt behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value id_new(mrb_state* M, const char* cls) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value d = id_new(M, "IdDrive");
        mrb_value a = id_new(M, "IdA");
        call(M, "go_before", d, "go", 1, &a);
        call(M, "other_before", d, "other", 1, &a);
        mrb_value kill_v[] = {mrb_obj_value(mrb_class_get(M, "IdA")), mrb_symbol_value(mrb_intern_lit(M, "foo"))};
        call(M, "kill", d, "kill", 2, kill_v);
        call(M, "go_after", d, "go", 1, &a);
        call(M, "other_after", d, "other", 1, &a);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(computed_dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    expected = ['go_before => 1', 'other_before => 2', 'kill => IdA', 'go_after => raised NoMethodError',
                'other_after => 2']
    suite.check('the interpreter gives the expected answers', interpreted == expected)
    puts "  interpreted: #{interpreted.inspect}" unless interpreted == expected
    suite.check('compiled matches interpreted', compiled == interpreted)
    puts "  compiled: #{compiled.inspect}" unless compiled == interpreted
  end
end

suite.finish!
