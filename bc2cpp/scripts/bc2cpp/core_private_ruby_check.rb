#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_PRIVATE_RUBY (tools/bc2cpp/core_private_ruby.rb): which private methods of mruby's own Ruby (`private def` in
# mruby-io's kernel.rb) the closed build may remove because no lookup can reach them.
#
#   private_defs
#     - a TDEF whose result the next instruction hands to a self `private` is listed under its owner; a plain def is not;
#   Lookup (the name scan, with a candidate's unreachable occurrences left out)
#     - a send with an explicit receiver stops at a private method (vm.c checks OP_SEND, not OP_SSEND): not a use;
#     - an implicit-self send is a use, unless the method it is in belongs to a class that defines the name itself;
#     - a Symbol (`send(:name)`), an ALIAS's old name and a pool string are uses, and so is `super` in a method of the name;
#     - the def's own name is not a use, even in a body that also holds an ALIAS;
#   NOT_LOOKUPS
#     - native text that spells a name without looking it up is blanked.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/core_private_ruby_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('core_private_ruby_check')
suite.require_mrbc!

# A core file: private helpers, one public def, and a class that defines `owned_call` itself.
CORE = <<~'RUBY'
  module Kernel
    private def say(x); x; end
    private def hush; end
    private def named; end
    private def self_called; end
    private def aliased_old; end
    private def owned_call; end
    private def stringly; end
    def public_one; end
  end

  class Port
    def owned_call; end

    def run
      owned_call
    end
  end
RUBY

# The engine: an explicit send to `say`, an implicit one to `self_called`, a Symbol, an alias, a pool string.
ENGINE = <<~'RUBY'
  class Thing
    def go(io)
      io.say(1)
      self_called
      send(:named)
      @s = 'stringly'
      Port.new.run
    end

    alias aliased_new aliased_old
  end
RUBY

def file_of(ireps, root)
  registry, = build_registry(ireps, root)
  body_of = {}
  owner_of = {}
  registry.each do |name, defs|
    defs.each do |d|
      next unless d.irep

      body_of[d.irep] = name
      owner_of[d.irep] = d.owner
    end
  end
  { ireps: ireps, body_of: body_of, owner_of: owner_of, registry: registry }
end

core = suite.compile(CORE) { |ireps, root| file_of(ireps, root) }
engine = suite.compile(ENGINE) { |ireps, _root| ireps }

found = CorePrivateRuby.private_defs(core[:ireps], core[:owner_of]).keys.sort
suite.check("only a `private def` is listed (#{found.join(', ')})",
            found == %w[Kernel#aliased_old Kernel#hush Kernel#named Kernel#owned_call Kernel#say Kernel#self_called
                        Kernel#stringly])

candidates = found.to_set { |key| key.split('#', 2).last }
defined = Set['Port#owned_call']
owners = {}.compare_by_identity
owners.merge!(StaticDispatchRegistrations.enclosing_owners(core[:ireps], core[:owner_of]))
lookup = CorePrivateRuby::Lookup.new(candidates, owners, CorePrivateRuby.defines_proc(defined, {}))
names, = CoreNativeCandidates.reachable(engine, [], [], core: [core], lookup: lookup)

suite.check('an explicit-receiver send stops at the private method', !names.include?('say'))
suite.check('an implicit-self send reaches it', names.include?('self_called'))
suite.check('a Symbol, an alias and a pool string do', %w[named aliased_old stringly].all? { |n| names.include?(n) })
suite.check("a def's own name is no use, nor is a send from a class that defines it", !names.include?('hush') &&
            !names.include?('owned_call'))

some_native = 'x = mrb_method_search_vm(mrb, &c, MRB_SYM(puts)); const char *v = "p"MRB_STRINGIZE(1);'
stripped = CorePrivateRuby.strip_not_lookups(some_native)
suite.check('native spellings that look nothing up are blanked, size kept',
            !stripped.include?('puts') && !stripped.include?('"p"') && stripped.size == some_native.size)

suite.finish!
