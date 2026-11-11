#!/usr/bin/env ruby
# frozen_string_literal: true

# LEFT_OUT_ACCESSORS (codegen_emit.rb): a gem's registration removes each attr_* accessor of its own owners
# (ONLY_OWNERS) that the build's list leaves out, through bc2cpp_left_out (the removal itself is
# unregistered_verify_check's). An unlisted accessor, another gem's owner, a compiled entry's key and a run without
# ONLY_OWNERS emit nothing.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/left_out_accessors_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

ENV['BC2CPP_SIG_DIRS'] = ''
suite = FixtureCheck.new('left_out_accessors_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class VAcc
    attr_reader :gone, :kept
    attr_writer :wgone
    attr_accessor :compiled

    class << self
      attr_reader :cgone
    end
  end

  class VOther
    attr_reader :gone
  end
RUBY

ENTRIES = [{ owner: 'VAcc', name: 'compiled', entry: 'vacc_compiled', aspec: 'MRB_ARGS_NONE()', visibility: :public }].freeze
LISTED = Set['VAcc#gone', 'VAcc#wgone=', 'VAcc#compiled', 'VAcc.singleton#cgone', 'VOther#gone']

registration = lambda do |only_owners|
  suite.compile(SOURCE) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    gen.instance_variable_set(:@only_owners, only_owners)
    gen.emit_owner_registrations(ENTRIES, %w[VAcc], unregistered: LISTED)
  end
end

out = registration.call(%w[VAcc VAcc.singleton])
# c_string_literal spells names as \xNN escapes.
left_out = out.scan(/bc2cpp_left_out\(M, \w+, "([^"]*)", (true|false)\);/)
              .map { |name, singleton| [name.gsub(/\\x(\h\h)/) { Regexp.last_match(1).hex.chr }, singleton] }
suite.check('a listed reader, writer and singleton reader of the gem\'s own owners are left out',
            left_out.include?(%w[gone false]) && left_out.include?(%w[wgone= false]) && left_out.include?(%w[cgone true]))
suite.check('an unlisted accessor stays', !left_out.map(&:first).include?('kept'))
suite.check('another gem\'s owner is not this gem\'s to remove', out.scan('bc2cpp_owner_acc_VOther').empty?)
suite.check('a compiled entry\'s key goes through the compiled entry, once',
            left_out.count { |name, _| name == 'compiled' } == 1)
suite.check('the left-out runtime is emitted for accessors alone', out.include?('static void bc2cpp_left_out('))
suite.check('without ONLY_OWNERS no accessor is touched', !registration.call(nil).include?('bc2cpp_owner_acc_'))

suite.finish!
