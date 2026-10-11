# frozen_string_literal: true

# INJECTIVE_MANGLE (codegen.rb#sanitize): every character outside [A-Za-z0-9]
# becomes `_` plus its two-digit lowercase hex code point.
#
# The map must be INJECTIVE, because cpp_name is `sanitize("#{owner}_#{name}")`
# and compile_all emits one `_impl` per registry leaf: two leaves whose
# (owner, name) pairs sanitize to the same string emit the same C++ function
# twice, and the translation unit fails to compile. That is not hypothetical --
# mruby-hash-ext's Hash#<, #<=, #> and #>= all collapsed to `Hash__`/`Hash___`
# under the previous run-to-underscore mapping.
#
# Also checks the mapping is total over the operator/punctuation names a closed
# world actually uses, and that every result is a valid C identifier.

require 'minitest/autorun'
require_relative '../../tools/bc2cpp/codegen'

class SanitizeTest < Minitest::Test
  # Every operator/punctuation method name in the closed world, plus a few
  # ordinary ones and two names that differ only by an underscore.
  NAMES = [
    '<', '>', '<=', '>=', '==', '===', '!=', '<=>', '<<', '>>', '[]', '[]=',
    '+', '-', '*', '/', '%', '**', '!', '~', '&', '|', '^', '+@', '-@', '=~',
    '!~', '`', 'call',
    'each', 'first', 'last', 'push', 'map', 'clear', 'min', 'max', 'sort',
    'initialize', 'to_h', 'to_ary', '_private', 'a_b', 'a__b', 'respond_to?',
    'nil?', 'zero?', 'instance_variable_get'
  ].freeze

  OWNERS = ['Array', 'Hash', 'Game::Actor', 'RPG2k::Scene::Map', 'Kernel',
            'Integer', 'String', 'Enumerable', 'Range', 'Comparable'].freeze

  # The real mapping under test. Duplicating the body here would let the copy
  # drift from the thing that actually mangles symbols, so bind the real one
  # (it is private) instead.
  SANITIZE = CodeGen.instance_method(:sanitize)

  def sanitize(s)
    SANITIZE.bind(CodeGen.allocate).call(s)
  end

  def test_colliding_operator_names_get_distinct_symbols
    # The exact regression: these four all produced Hash__ / Hash___ before.
    {
      '<' => 'Hash__', '>' => 'Hash__',
      '==' => 'Hash___', '<=' => 'Hash___', '>=' => 'Hash___', '!=' => 'Hash___'
    }.each_key do |name|
      refute_equal 'Hash__', "Hash_#{name}".then { |x| sanitize(x) },
                   "Hash##{name} must not sanitize to the < / > symbol"
    end

    symbols = %w[< > == <= >= !=].map { |n| sanitize("Hash_#{n}") }
    assert_equal symbols.size, symbols.uniq.size,
                 "Hash comparison operators collide: #{symbols.inspect}"
  end

  def test_sanitize_is_injective_over_every_owner_name_pair
    seen = {}
    OWNERS.each do |owner|
      NAMES.each do |name|
        sym = sanitize("#{owner}_#{name}")
        key = [owner, name]
        if seen.key?(sym)
          flunk "#{key.inspect} and #{seen[sym].inspect} both sanitize to #{sym}"
        end

        seen[sym] = key
      end
    end
    assert_equal OWNERS.size * NAMES.size, seen.size
  end

  def test_underscore_passes_through_so_symbols_stay_short
    # `_` is NOT escaped, so a separator costs one character. Escaping it (an
    # earlier revision did) lengthened every symbol and pushed the longest in
    # this program to 97 characters, past C++'s 63-significant-character
    # guarantee.
    assert_equal 'Game__Actor_update', sanitize('Game::Actor_update')
    assert_equal 'Widget_singleton_make', sanitize('Widget.singleton_make')
    assert_equal 'Array_bsearch', sanitize('Array_bsearch')
    assert_equal 'Array_$3c', sanitize('Array_<')
  end

  def test_no_legal_ruby_name_can_forge_an_escape_sequence
    # The separator is `$`, which a Ruby method or class name cannot contain, so
    # `Array__3c` (a legal name) cannot reach the `Array_$3c` that `Array_<`
    # produces. With `_` as the separator these two DID collide.
    refute_equal sanitize('Array_<'), sanitize('Array__3c')
    assert_equal 'Array__3c', sanitize('Array__3c')
    refute_includes sanitize('Array__3c'), '$'
  end

  def test_every_result_is_a_valid_c_identifier
    OWNERS.each do |owner|
      NAMES.each do |name|
        sym = sanitize("#{owner}_#{name}")
        assert_match(/\A[A-Za-z][A-Za-z0-9_]*\z/, sym,
                     "#{owner}##{name} -> #{sym} is not a C identifier")
        # must not end in a bare digit run that could read as a suffix
        refute_match(/_\z/, sym, "#{owner}##{name} -> #{sym} ends in a bare underscore")
      end
    end
  end

  def test_owner_and_method_words_keep_their_readable_form
    # Only characters outside [A-Za-z0-9] are mangled, so the owner and method
    # words stay legible in the generated C++.
    assert_equal 'Game__Actor_update', sanitize('Game::Actor_update')
    assert_equal 'Widget_singleton_make', sanitize('Widget.singleton_make')
    assert_equal 'Array_bsearch', sanitize('Array_bsearch')
    assert_equal 'Array_$3c', sanitize('Array_<')
  end

  def test_every_result_is_a_valid_c_identifier
    OWNERS.each do |owner|
      NAMES.each do |name|
        sym = sanitize("#{owner}_#{name}")
        # `$` is a legal C++ identifier character, and the symbol always starts
        # with a letter because every owner name does.
        assert_match(/\A[A-Za-z][A-Za-z0-9_.$]*\z/, sym,
                     "#{owner}##{name} -> #{sym} is not a C identifier")
        refute_match(/_\z/, sym, "#{owner}##{name} -> #{sym} ends in a bare underscore")
      end
    end
  end
end
