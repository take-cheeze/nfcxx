#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_ROWS_COMPILED (StaticDispatchRegistrations#core_excluded): the core rows run reads the core gem's generation like
# the engine's, so a core body that generation compiles looks up what its code does, not every symbol of its irep; and
# GENERATED_COMMENT: a whole-line comment of the generated code (the probe's annotations) gives no literal.
#
#   - live_core with +compiled+: a compiled body's sends are not read, an uncompiled one's still are once reachable;
#   - the literal scan: a POLY_DIAG comment's quoted name is no literal, a code line's is; a class body's
#     registration on `self` (SELF_REGISTRATION_STMT) is no literal either.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/core_rows_compiled_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('core_rows_compiled_check')
suite.require_mrbc!

CORE = <<~RUBY
  class Gizmo
    def spin
      compiled_send
    end

    def wobble
      uncompiled_send
    end
  end
RUBY

core = suite.compile(CORE) do |ireps, root|
  registry = build_registry(ireps, root)[0]
  body_of = {}
  owner_of = {}
  registry.each { |name, defs| defs.each { |d| (body_of[d.irep] = name) && (owner_of[d.irep] = d.owner) if d.irep } }
  [{ ireps: ireps, body_of: body_of, owner_of: owner_of, registry: registry }]
end
engine = suite.compile("def e(x)\n  x.spin\n  x.wobble\nend\n") { |e, _root| e }

names, = CoreNativeCandidates.reachable(engine, [], [], core: core)
suite.check('without the core generation, both reachable bodies count',
            names.include?('compiled_send') && names.include?('uncompiled_send'))
names, = CoreNativeCandidates.reachable(engine, [], [], core: core, compiled_core: Set['Gizmo#spin'])
suite.check("a compiled body's sends are the generation's, not its irep's",
            !names.include?('compiled_send') && names.include?('uncompiled_send'))

sdr = StaticDispatchRegistrations
gen = <<~'CPP'
  // POLY_DIAG path=chain receiver=runtime_class name="comment_only" arity=0 candidates=2
    // POLY_DIAG path=chain receiver=runtime_class name="indented_comment" arity=0
  mrb_value v = mrb_funcall(M, x, "code_literal", 0); // trailing "kept_trailing"
  mrb_define_method(M, mrb_class_ptr(self), "\x73\x65\x6c\x66\x5f\x64\x65\x66", Gizmo_self_def, MRB_ARGS_NONE());
CPP
text = gen.gsub(sdr::GENERATED_COMMENT, '').gsub(sdr::SELF_REGISTRATION_STMT, '')
lits = []
text.scan(sdr::STRING_LITERAL) { |(s)| lits << sdr.unescape(s) }
suite.check("a whole-line comment's quoted name is no literal (#{lits.join(', ')})",
            !lits.include?('comment_only') && !lits.include?('indented_comment'))
suite.check("a code line's literal is one, and a trailing comment is not stripped",
            lits.include?('code_literal') && lits.include?('kept_trailing'))
suite.check("a class body's registration on self is no literal", !lits.include?('self_def'))

suite.finish!
