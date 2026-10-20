#!/usr/bin/env ruby
# frozen_string_literal: true

# Host check of ElementType (tools/bc2cpp/element_type.rb): the one-level generic term's join, its erasure to a class
# mask, and the refusal of a nested term. Pure Ruby, no MRBC.

require_relative '../../tools/bc2cpp/element_type'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

arr = NumericFlow::ARR
hsh = NumericFlow::HSH
int = NumericFlow::INT
str = NumericFlow::STR
nil_bit = NumericFlow::NIL

a_int = ElementType.generic(arr, int)
a_str = ElementType.generic(arr, str)
a_unknown = ElementType.generic(arr, nil)
h_is = ElementType.generic(hsh, int, str)

check.call('Array[Integer] joined with Array[String] is Array[Integer|String]',
           ElementType.join(a_int, a_str) == ElementType.generic(arr, int | str))
check.call('an unknown element absorbs: Array[Integer] | Array[untyped] is Array[untyped]',
           ElementType.join(a_int, a_unknown) == ElementType.generic(arr, nil))
check.call('a plain Array mask joined with Array[Integer] erases to the Array bit',
           ElementType.join(arr, a_int) == arr)
check.call('Array[Integer] with Hash[Integer, String] erases to ARR | HSH',
           ElementType.join(a_int, h_is) == (arr | hsh))
check.call('the join is idempotent', ElementType.join(a_int, a_int) == a_int)
check.call('the join is commutative', ElementType.join(a_int, a_str) == ElementType.join(a_str, a_int))
check.call('a plain class mask joins by OR', ElementType.join(int, str) == (int | str))
check.call('Hash parameters join pairwise', ElementType.join(h_is, ElementType.generic(hsh, str, int)) ==
           ElementType.generic(hsh, int | str, str | int))
check.call('element_of an Array[Integer] is Integer', ElementType.param(a_int, 0) == int)
check.call('element_of an Array[untyped] is unknown', ElementType.param(a_unknown, 0).nil?)
check.call('element_of a plain mask is unknown', ElementType.param(arr, 0).nil?)
check.call('classes of a term is its container bit', ElementType.classes(h_is) == hsh)
check.call('a nested term is refused', (ElementType.generic(arr, a_int) rescue ArgumentError) == ArgumentError)
check.call('a parameter count mismatch is refused', (ElementType.generic(hsh, int) rescue ArgumentError) == ArgumentError)
check.call('nil bit joins as a plain class', ElementType.join(nil_bit, a_int) == (nil_bit | arr))

if failures.empty?
  puts "element_type_check: #{failures.size} failures, all checks passed"
else
  abort "element_type_check: #{failures.size} failure(s)"
end
