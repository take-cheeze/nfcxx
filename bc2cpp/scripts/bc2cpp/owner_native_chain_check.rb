#!/usr/bin/env ruby
# frozen_string_literal: true

# OWNER_NATIVE_CHAIN (tools/bc2cpp/codegen_owner_native_chain.rb): with BC2CPP_OWNER_NATIVE_READ=1, CHA_SELF's name gate
# asks whether each outside definer of `read` (IO#read, StringIO#read, Dir#read) is off the lookup path of `self` and its
# descendants, instead of refusing the name for having any outside definer.
#
#   generated code, flag on:
#     - a `read` self-send in a record class whose 18 descendants inherit the class's own `read` (more than
#       POLY_SMALL_N_INHERITED_MAX, so the POLY chain could not list them) is a direct call to that `_impl`, with no
#       owner call (CLOSED_WORLD_SELF);
#     - the same site with an overriding descendant still has no owner call: the overrider is an exact-class arm, the
#       inherited definition is the else;
#   generated code, flag on, stays by name:
#     - a descendant that includes a module defining `read` (the mixin is on its path);
#     - a self-send in a class whose superclass is StringIO (a native `read` on the path);
#   generated code, flag off: the first case keeps its owner call, so the output is the one the name-level gate made.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/owner_native_chain_check.rb
#   BC2CPP_TOOL=path/to/other/bc2cpp.rb names another bc2cpp.rb (the one before this change, to see the checks fail).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('owner_native_chain_check')
suite.require_mrbc!

KIDS = 18.times.map { |i| "OnKid#{i}" }.freeze
DESCENDANTS = KIDS.map { |kid| "class #{kid} < OnRec; end" }.join("\n")

SOURCE = <<~RUBY
  class OnRec
    def table(id) = read(id, :Array1D)
    def read(id, type) = [id, type]
  end
  #{DESCENDANTS}
  class OnOver < OnRec
    def read(id, type) = [:over, id]
  end

  module OnMix
    def read(id, type) = [:mix, id]
  end
  class OnMixBase
    def table(id) = read(id, :Array1D)
    def read(id, type) = [id, type]
  end
  class OnMixKid < OnMixBase
    include OnMix
  end

  class OnStr < StringIO
    def table(id) = read(id)
  end
RUBY
OWNERS = (%w[OnRec OnOver OnMixBase OnMixKid OnMix OnStr] + KIDS).freeze

def body_of(code, fn)
  start = code.index(/^mrb_value #{Regexp.escape(fn)}_impl\(mrb_state\* M, [^\n]*\{$/)
  return '' unless start

  rest = code[start..]
  rest[0, rest.index("\n}\n") || rest.size]
end

def generate_with_flag(source, dir, flag)
  ENV['BC2CPP_OWNER_NATIVE_READ'] = flag
  Bc2cppFixtureRuntime.generate(source, dir, only_owners: OWNERS).first
ensure
  ENV.delete('BC2CPP_OWNER_NATIVE_READ')
end

Dir.mktmpdir('bc2cpp-owner-native-chain') do |dir|
  on_code = generate_with_flag(SOURCE, File.join(dir, 'on'), '1')
  record = body_of(on_code, 'OnRec_table')
  suite.check('flag on, 18 descendants and an overrider: the record\'s read self-send is a direct call',
              record.include?('CLOSED_WORLD_SELF :read -> OnRec#read') && record.include?('OnRec_read_impl(M, self'))
  suite.check('flag on: no owner call is left for the record\'s read self-send',
              !record.include?('owner-call: read') && !record.include?('bc2cpp_owner_call'))

  mixin = body_of(on_code, 'OnMixBase_table')
  suite.check('flag on, a descendant includes a module defining read: the self-send stays by name',
              !mixin.include?('CLOSED_WORLD_SELF :read') && mixin.include?('owner-call: read'))

  stringio = body_of(on_code, 'OnStr_table')
  suite.check('flag on, a StringIO superclass on the path: the self-send stays by name',
              !stringio.include?('CLOSED_WORLD_SELF :read') && stringio.include?('owner-call: read'))

  off_code = generate_with_flag(SOURCE, File.join(dir, 'off'), nil)
  off_record = body_of(off_code, 'OnRec_table')
  suite.check('flag off: the record\'s read self-send keeps its owner call (the name-level gate)',
              !off_record.include?('CLOSED_WORLD_SELF :read') && off_record.include?('owner-call: read'))
end

suite.finish!
