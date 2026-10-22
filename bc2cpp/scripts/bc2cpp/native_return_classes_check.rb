#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks tools/bc2cpp/native_return_classes.rb (option B): a native name is admitted with a class only when every
# native registration of it is attributed, has one proven body, and agrees. Fixtures build NativeOwnerMap results
# directly, so each rule is exercised on its own.
#
#   ruby scripts/bc2cpp/native_return_classes_check.rb

require 'set'
require 'fileutils'
require 'tmpdir'
require_relative '../../tools/bc2cpp/native_return_classes'
require_relative '../../tools/bc2cpp/foreign_string_results'

failures = []
check = lambda do |name, ok|
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end

def map_of(by_name, computed: Set.new, computed_unknown: false, core_dynamic_unknown: 0)
  NativeOwnerMap::Result.new(by_name: by_name, computed: computed, computed_unknown: computed_unknown,
                             core_dynamic_unknown: core_dynamic_unknown, refusals: Hash.new(0), calls: 0)
end

def set(*items) = Set.new(items)

by_name = { 'to_i' => set('Integer', 'String'), 'to_f' => set('Float') }
rom = [['Integer', 'to_i', 'self_i'], ['String', 'to_i', 'str_to_i'], ['Float', 'to_f', 'self_f']]
kinds = { 'self_i' => 'self', 'str_to_i' => 'Integer', 'self_f' => 'self' }
exact = set('Integer', 'Float')
result = NativeReturnClasses.admit(map_of(by_name), rom, kinds, exact_self: exact)
check.call('same class from every owner is admitted (self on an exact owner counts as that owner)',
           result[:admitted]['to_i'] == 'Integer')
check.call('exact-self owners come from the sources: Integer and Float on numeric.c, never Struct',
           NativeReturnClasses.exact_self_owners([File.expand_path('../../3rd/mruby/src/numeric.c', __dir__)]) == set('Float', 'Integer')) if File.file?(File.expand_path('../../3rd/mruby/src/numeric.c', __dir__))
check.call('a self return on a non-exact owner is refused',
           NativeReturnClasses.admit(map_of({ 'x' => set('String') }), [['String', 'x', 'selfs']], { 'selfs' => 'self' })[:refused].first&.reason == :self_return_not_exact)
check.call('an unproven body is refused',
           NativeReturnClasses.admit(map_of({ 'y' => set('String') }), [['String', 'y', 'f']], { 'f' => nil })[:refused].first&.reason == :body_not_proven)
check.call('a registration with no ROM entry is refused',
           NativeReturnClasses.admit(map_of({ 'z' => set('String', 'Array') }), [['String', 'z', 'f']], { 'f' => 'String' })[:refused].first&.reason == :registration_without_rom_entry)
check.call('classes that disagree are refused',
           NativeReturnClasses.admit(map_of({ 'w' => set('String', 'Integer') }),
                                     [['String', 'w', 'a'], ['Integer', 'w', 'b']], { 'a' => 'String', 'b' => 'Integer' })[:refused].first&.reason == :classes_disagree)
check.call('an unknown owner refuses the name',
           NativeReturnClasses.admit(map_of({ 'u' => set(NativeOwnerMap::UNKNOWN, 'String') }), [['String', 'u', 'f']], { 'f' => 'String' })[:refused].first&.reason == :owner_unknown)
check.call('an unresolved computed registration on the owner refuses the name',
           NativeReturnClasses.admit(map_of({ 'c' => set('String') }, computed: set('String')), [['String', 'c', 'f']], { 'f' => 'String' })[:refused].first&.reason == :computed_registration_on_owner)
check.call('an unknown computed registration outside the core refuses every name',
           NativeReturnClasses.admit(map_of({ 'v' => set('String') }, computed_unknown: true), [['String', 'v', 'f']], { 'f' => 'String' })[:admitted].empty?)

benchmark = File.expand_path('../../3rd/mruby/mrbgems/mruby-benchmark/mrblib/benchmark.rb', __dir__)
if File.file?(benchmark)
  check.call('an audited outside to_s is admitted for String; the same file is not audited for inspect',
             ForeignStringResults.audited_string_paths('to_s', [benchmark]) == [benchmark] &&
             ForeignStringResults.audited_string_paths('inspect', [benchmark]).empty?)
  Dir.mktmpdir do |dir|
    # A copy at the audited path with other content: the digest no longer matches, so the audit does not count it.
    edited = File.join(dir, '3rd/mruby/mrbgems/mruby-benchmark/mrblib/benchmark.rb')
    FileUtils.mkdir_p(File.dirname(edited))
    File.write(edited, File.read(benchmark) + "\n# edited\n")
    check.call('an audited file whose digest changed is not counted as a String result',
               ForeignStringResults.audited_string_paths('to_s', [edited]).empty?)
  end
end
check.call('a path no audit lists is never counted',
           ForeignStringResults.audited_string_paths('to_s', ['/x/3rd/mruby/src/unlisted.rb']).empty?)

if failures.empty?
  puts 'native return classes: all checks passed'
else
  puts "native return classes: #{failures.size} failed"
  exit 1
end
