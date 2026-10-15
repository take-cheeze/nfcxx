# frozen_string_literal: true

# OUTSIDE_RUBY_IVAR_SCOPES (tools/bc2cpp/outside_ruby_ivar_scopes.rb): an outside Ruby `@name` written in an
# instance method lexically inside `class C` is attributed to C; everything the lexical rule cannot pin to
# one class stays global, so a missed case costs a typed slot, never soundness.

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/bc2cpp/outside_ruby_ivar_scopes'

class OutsideRubyIvarScopesCheck < Minitest::Test
  def analyze(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'outside.rb')
      File.write(path, source)
      global, scoped = OutsideRubyIvarScopes.analyze([path])
      [global, scoped.transform_values { |classes| classes.to_a.sort }]
    end
  end

  def test_instance_methods_are_scoped_to_their_lexical_class
    global, scoped = analyze(<<~RUBY)
      class A
        def m(x = @dflt) = @a = "\#{@interp}"
        class B < A
          def n; @b; @a; end
        end
      end
      module M
        class C; def r; @c += 1; end; end
      end
      class D::E; def s; @e ||= 1; end; end
    RUBY
    assert_empty global
    assert_equal({ 'a' => %w[A A::B], 'b' => ['A::B'], 'c' => ['M::C'], 'dflt' => ['A'], 'e' => ['D::E'],
                   'interp' => ['A'] }, scoped)
  end

  def test_unpinnable_spellings_stay_global
    global, scoped = analyze(<<~RUBY)
      @main = 1
      class A
        @class_object = 1
        def self.s = @singleton_def
        class << self; def t = @singleton_class; end
        def m
          [1].each { @block }
          -> { @lambda }
          instance_variable_get(:@symbol)
          instance_variable_set("@string", 1)
          /@regexp/
        end
      end
      module M; def q = @module; end
      class ::Top; def z = @top_level_path; end
      # @comment
    RUBY
    assert_equal %w[block class_object comment lambda main module regexp singleton_class singleton_def string
                    symbol top_level_path], global.to_a.sort
    assert_empty scoped
  end

  def test_a_global_spelling_anywhere_wins_over_a_scoped_one
    global, scoped = analyze("class A; def m = @x; end\n[1].each { @x }\n")
    assert_equal ['x'], global.to_a
    assert_empty scoped
  end

  def test_an_unparsable_file_is_all_global
    global, scoped = analyze("class A\n  def m = @x\n  def (\n")
    assert_includes global, 'x'
    assert_empty scoped
  end

  def test_enumerator_size_is_scoped_to_enumerator
    path = File.expand_path('../../3rd/mruby/mrbgems/mruby-enumerator/mrblib/enumerator.rb', __dir__)
    skip 'needs 3rd/mruby' unless File.file?(path)

    global, scoped = OutsideRubyIvarScopes.analyze([path])
    refute_includes global, 'size'
    assert_equal ['Enumerator'], scoped['size'].to_a
  end
end
