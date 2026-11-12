#!/usr/bin/env ruby
# frozen_string_literal: true

# OPERATOR_ROWS (CoreNativeCandidates.candidates/reachable with +operators+, the core rows run): an operator's core ROM
# entry becomes a row once nothing reaches its name, as an identifier's does.
#
#   - an operator nothing reaches is a candidate only when operators are admitted; a reached one never is;
#   - a native's MRB_OPSYM(x) reaches the operator, the presym headers' macro definitions do not;
#   - the generated-code scan reads MRB_OPSYM references; the engine reading leaves an operator opcode to it.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/core_operator_rows_check.rb

require 'set'
require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('core_operator_rows_check')
suite.require_mrbc!

entries = [{ mt_class: 'Widget', kind: 'OPSYM', cname: 'lshift', name: '<<', installed: 'Widget' },
           { mt_class: 'Widget', kind: 'OPSYM', cname: 'add', name: '+', installed: 'Widget' },
           { mt_class: 'Widget', kind: 'SYM', cname: 'spin', name: 'spin', installed: 'Widget' }]
plain = CoreNativeCandidates.candidates(entries, Set['+'], Set.new)
ops = CoreNativeCandidates.candidates(entries, Set['+'], Set.new, {}, operators: true)
suite.check("operators stay out unless admitted (#{plain.join(', ')})", plain == %w[Widget#spin])
suite.check("an admitted operator nothing reaches is a candidate, a reached one is not (#{ops.join(', ')})",
            ops == %w[Widget#<< Widget#spin])

Dir.mktmpdir('core-operator-rows') do |dir|
  use = File.join(dir, 'widget.c')
  File.write(use, "static mrb_value f(mrb_state *mrb, mrb_value x) { return mrb_funcall_id(mrb, x, MRB_OPSYM(rshift), 0); }\n")
  presym = File.join(dir, 'include/mruby/presym/scanning.h')
  FileUtils.mkdir_p(File.dirname(presym))
  File.write(presym, "#define MRB_OPSYM__xor(mrb) MRB_PRESYM_SCANNING_TAGGED(\"^\")\n#define MRB_OPSYM__or(mrb) MRB_OPSYM(or)\n")
  names, = CoreNativeCandidates.reachable({}, [use, presym], [], operators: true)
  suite.check('a native MRB_OPSYM reaches its operator', names.include?('>>'))
  suite.check("a presym header's macro definitions reach nothing (#{(names & %w[^ |]).to_a.join(', ')})",
              !names.include?('^') && !names.include?('|'))
end

gen = <<~CPP
  static const char* const bc2cpp_sym_names[1] = {
    "x",
  };
  mrb_value f(mrb_state* M, mrb_value r1) {
    r1 = bc2cpp_funcall_keep(M, r1, MRB_OPSYM(mul), 0, nullptr);
    r1 = mrb_bool_value(mrb_symbol_p(r1) && mrb_symbol(r1) == MRB_OPSYM(div));
  }
CPP
found = CoreRows.generated_lookups(gen)
suite.check("a generated MRB_OPSYM reference is a lookup (#{found.to_a.join(', ')})", found.include?('*'))

engine = suite.compile("def e(x)\n  x + 1\nend\n") { |ireps, _root| ireps }
names = CoreRows.engine_names(engine, [], Set.new, Set.new)
suite.check("an engine operator opcode is left to the generated code (#{names.to_a.join(', ')})", !names.include?('+'))

suite.finish!
