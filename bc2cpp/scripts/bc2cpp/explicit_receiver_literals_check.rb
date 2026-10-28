#!/usr/bin/env ruby
# frozen_string_literal: true

# EXPLICIT_RECEIVER_LITERALS (tools/bc2cpp/core_private_ruby.rb, strip_generated): which names the generated C++ spells
# still count as a use of a private core method (`Kernel#puts`). Only a spelling that cannot reach one is dropped:
#
#   CorePrivateRuby.strip_generated
#     - a symbol-table name every use of which calls with a register receiver (`rN`, the C++ of an OP_SEND) is dropped;
#     - one with a `self` receiver (the C++ of an OP_SSEND), a symbol value, or a mix of the two is kept;
#     - a comment, the name a registration defines, and the `$stderr.puts` of the failure reports are dropped;
#     - a literal in any other call (a computed `mrb_funcall`) is kept;
#   CoreNativeCandidates.reachable(exact_impls: true)
#     - an `_impl` call of another owner's method (`Port_hush_impl`) is no call of the core method of that name, and a
#       direct call makes the body live without making the name reachable;
#     - without the flag the name alone decides, as for the ROM entries.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/explicit_receiver_literals_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('explicit_receiver_literals_check')
suite.require_mrbc!

# The generated code of one gem: a symbol table, a registration, a comment, the failure report, and one use of each kind.
#   0 "from_reg"    register receiver only          -> dropped        4 "viaindex"  bc2cpp_send(M, r2, 4, ...)  -> dropped
#   1 "from_self"   `self` receiver                 -> kept           5 "mixed"     register and self           -> kept
#   2 "as_value"    mrb_symbol_value                -> kept           6 "computed"  register and a bare mrb_funcall string
#   3 "from_splat"  funcall_argv on a register      -> dropped
GENERATED = <<~'CPP'
  static const char* const bc2cpp_sym_names[7] = {
    "from_reg",
    "from_self",
    "as_value",
    "from_splat",
    "viaindex",
    "mixed",
    "computed",
  };
  // POLY_DIAG name="commented" arity=0
  void f(mrb_state* M, mrb_value self, mrb_value r2, mrb_value r3) {
    mrb_define_method(M, klass, "defined_here", Foo_defined_here, MRB_ARGS_NONE());
    r3 = bc2cpp_io_puts(M, r3, bc2cpp_sym(M, 0), 1, argv);
    r3 = bc2cpp_funcall_argv(M, self, bc2cpp_sym(M, 1), 0, NULL);
    r3 = mrb_symbol_value(bc2cpp_sym(M, 2));
    r3 = bc2cpp_funcall_argv(M, r3, bc2cpp_sym(M, 3), ary_size(r4), ary_items(r4));
    r3 = bc2cpp_send(M, r2, 4, 0);
    r3 = bc2cpp_send(M, r2, 5, 0);
    r3 = bc2cpp_funcall_argv(M, self, bc2cpp_sym(M, 5), 0, NULL);
    r3 = bc2cpp_send(M, r2, 6, 0);
    r3 = mrb_funcall(M, r3, "computed", 0);
    mrb_sym puts_id = mrb_intern_lit(M, "reported");
    if (mrb_respond_to(M, err, puts_id)) mrb_funcall_id(M, err, puts_id, 1, msg);
    mrb_sym other_id = mrb_intern_lit(M, "elsewhere");
    mrb_funcall_id(M, r3, other_id, 0);
  }
CPP

literals = lambda do |text|
  text.scan(StaticDispatchRegistrations::STRING_LITERAL).map { |(s)| StaticDispatchRegistrations.unescape(s) }.to_set
end
stripped = CorePrivateRuby.strip_generated(GENERATED)
kept = literals.call(stripped)
suite.check("a register-receiver use drops the name (#{kept.to_a.sort.join(', ')})",
            %w[from_reg from_splat viaindex].none? { |n| kept.include?(n) })
suite.check('a self receiver, a symbol value, a mixed use and a computed funcall keep it',
            %w[from_self as_value mixed computed].all? { |n| kept.include?(n) })
suite.check('a comment, a defined name and the stderr report are no use',
            %w[commented defined_here reported].none? { |n| kept.include?(n) })
suite.check('any other funcall on a register keeps its literal', kept.include?('elsewhere'))
suite.check('the table keeps its size, so the indexes still line up',
            stripped[StaticDispatchRegistrations::SYM_TABLE, 1].scan(StaticDispatchRegistrations::STRING_LITERAL).size == 7)

# The names a reachable scan finds with and without the strip: the private-name scan drops "from_reg", the other keeps it.
plain, = CoreNativeCandidates.reachable({}, [], [GENERATED])
strict, = CoreNativeCandidates.reachable({}, [], [GENERATED], strip_generated: CorePrivateRuby.method(:strip_generated))
suite.check('the receiver-blind scan still counts every literal', %w[from_reg commented defined_here].all? { |n| plain.include?(n) })
suite.check('the private-name scan does not count the explicit-receiver one', !strict.include?('from_reg'))

# exact_impls: the core file has the private Kernel#hush and #direct, and a public method of the same name on Port.
CORE = <<~'RUBY'
  module Kernel
    private def hush; hush_target; end
    private def direct; direct_target; end
    private def by_name_only; name_only_target; end
  end

  class Port
    def hush; end
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
  { ireps: ireps, body_of: body_of, owner_of: owner_of }
end

core = suite.compile(CORE) { |ireps, root| file_of(ireps, root) }
impls = ['Port_hush_impl', 'Kernel_direct_impl'].map { |t| "x = #{t}(M, self);" }
exact, = CoreNativeCandidates.reachable({}, [], impls, core: [core], exact_impls: true)
suite.check("another owner's _impl is no call of the core body, and no lookup of its name",
            !exact.include?('hush_target') && !exact.include?('hush'))
suite.check("the core owner's _impl makes its body live without making the name reachable",
            exact.include?('direct_target') && !exact.include?('direct'))
suite.check('a body nothing calls stays dead', !exact.include?('name_only_target'))

named, = CoreNativeCandidates.reachable({}, [], impls, core: [core])
suite.check('without the flag the name alone decides, as the ROM entries need',
            named.include?('hush_target') && named.include?('direct_target') && named.include?('direct'))

suite.finish!
