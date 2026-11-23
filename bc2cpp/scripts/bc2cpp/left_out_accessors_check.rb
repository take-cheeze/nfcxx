#!/usr/bin/env ruby
# frozen_string_literal: true

# LEFT_OUT_ACCESSORS (codegen_emit.rb): a gem's registration removes each attr_* accessor of its own owners
# (ONLY_OWNERS) that the build's list leaves out, through bc2cpp_left_out (the removal itself is
# unregistered_verify_check's). An unlisted accessor, another gem's owner, a compiled entry's key and a run without
# ONLY_OWNERS emit nothing. LEFT_OUT_ATTR (codegen_class_body.rb): the class unit defines none of what the
# registration removes (registration_removed_keys, which must name exactly the registration's removals).
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

units = lambda do |only_owners|
  suite.compile(SOURCE) do |ireps, root|
    gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    gen.instance_variable_set(:@only_owners, only_owners)
    removed = gen.registration_removed_keys(ENTRIES, %w[VAcc], unregistered: LISTED)
    gen.registration_removed = removed
    [removed, gen.compile_top_class_units(ireps.fetch(root)).map { |u| u[:code] }.join]
  end
end
# The attr names a unit still defines: each bc2cpp_mod_attr's registers, as the symbol lines before it last set them.
defined_attrs = lambda do |code|
  regs = {}
  code.each_line.flat_map do |line|
    if (m = line.match(/(r\d+) = mrb_symbol_value\((?:MRB_SYM\((\w+)\)|mrb_intern_cstr\(M, "(\w+)"\))\);/))
      regs[m[1]] = m[2] || m[3]
      next []
    end
    m = line.match(/bc2cpp_mod_attr\(M, self, (true|false), (true|false), \{([^}]*)\}\)/)
    next [] unless m

    m[3].split(', ').flat_map { |reg| [m[1] == 'true' ? regs[reg] : nil, m[2] == 'true' ? "#{regs[reg]}=" : nil].compact }
  end
end
removed, code = units.call(%w[VAcc VAcc.singleton])
suite.check('the removed keys are the registration\'s removals',
            removed == Set['VAcc#gone', 'VAcc#wgone=', 'VAcc#compiled', 'VAcc.singleton#cgone'])
attrs = defined_attrs.call(code)
suite.check('the class unit defines only the accessors the registration keeps',
            attrs.sort == %w[compiled= gone kept].sort && code.include?('LEFT_OUT_ATTR'))
suite.check('another gem\'s owner keeps its accessor', attrs.include?('gone'))
ENV['BC2CPP_LEFT_OUT_ATTR'] = '0'
suite.check('BC2CPP_LEFT_OUT_ATTR=0 defines every accessor',
            defined_attrs.call(units.call(%w[VAcc VAcc.singleton])[1]).sort == %w[cgone compiled compiled= gone gone kept wgone=].sort)
ENV.delete('BC2CPP_LEFT_OUT_ATTR')

suite.finish!
