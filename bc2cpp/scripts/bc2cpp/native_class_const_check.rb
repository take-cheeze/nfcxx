#!/usr/bin/env ruby
# encoding: UTF-8
# Check StableClassConstants.analyze_native (tools/bc2cpp/const_site_cache.rb):
# a bare name a native mrbgem defines exactly once as a class/module (Symbol,
# Array, and every other core/native class the ordinary Ruby-statement-based
# StableClassConstants.analyze can never see) is admitted into the SAME
# const-site cache set, provided it is never reassigned/removed/autoloaded --
# a Ruby-level REOPENING of that same class must still be admitted (reopening
# never rebinds the constant), while a genuinely ambiguous native definition,
# a reassignment, or a foreign-Ruby-defined same-named class must not be.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SRC = <<~'RUBY'
  class User
    def read_builtin
      Symbol
    end

    def read_reopened
      Reopened
    end

    def read_ambiguous
      Ambiguous
    end

    def read_reassigned
      Reassigned
    end

    def read_foreign_defined
      ForeignDefined
    end
  end

  class Reopened
    def extra; end
  end
  Reassigned = String
RUBY

Dir.mktmpdir do |dir|
  source = File.join(dir, 'native_class.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_native_class', dir)
  order = dfs_order(ireps, root_label)

  native = File.join(dir, 'native.cxx')
  File.write(native, <<~CXX)
    void f1(mrb_state* M) {
      mrb->symbol_class = mrb_define_class_id(M, MRB_SYM(Symbol), M->object_class);
    }
    void f2(mrb_state* M) {
      mrb_define_class_id(M, MRB_SYM(Reopened), M->object_class);
    }
    // Two DIFFERENT native definitions of the same bare name -- ambiguous.
    void f3(mrb_state* M) {
      mrb_define_module(M, "Ambiguous");
    }
    void f4(mrb_state* M) {
      RClass* holder = mrb_define_module(M, "Elsewhere");
      mrb_define_class_under(M, holder, "Ambiguous", M->object_class);
    }
    void f5(mrb_state* M) {
      mrb_define_class(M, "Reassigned", M->object_class);
    }
  CXX
  clean_foreign = File.join(dir, 'clean.rb')
  File.write(clean_foreign, "class Foreign; end\n")
  # A foreign source REOPENING the same native class (mruby core's own real
  # shape: 3rd/mruby/mrblib/symbol.rb reopens `class Symbol` to add methods)
  # must NOT disqualify it -- reopening never rebinds the constant, whether
  # the reopening is in the closed world's own bytecode or a foreign source.
  foreign_reopener = File.join(dir, 'foreign_reopener.rb')
  File.write(foreign_reopener, "class ReopenedByForeign\n  def extra; end\nend\n")
  reopened_native = File.join(dir, 'native_reopened.cxx')
  File.write(reopened_native, 'void g(mrb_state* M) { mrb_define_class(M, "ReopenedByForeign", M->object_class); }')
  # A foreign source that REASSIGNS the same bare name (`Name = value`) is a
  # real risk and must disqualify it.
  foreign_reassigner = File.join(dir, 'foreign_reassigner.rb')
  File.write(foreign_reassigner, "ForeignReassigned = String\n")
  reassigned_native = File.join(dir, 'native_reassigned.cxx')
  File.write(reassigned_native, 'void h(mrb_state* M) { mrb_define_class(M, "ForeignReassigned", M->object_class); }')

  admitted = StableClassConstants.analyze_native(ireps, [native], [clean_foreign])
  check.call('a native-defined builtin class is admitted', admitted.include?('Symbol'))
  check.call('a native class Ruby code merely reopens is still admitted (reopening never rebinds)',
             admitted.include?('Reopened'))
  check.call('two distinct native definitions of the same bare name are refused (ambiguous)',
             !admitted.include?('Ambiguous'))
  check.call('a name also assigned with `Name = ...` is refused', !admitted.include?('Reassigned'))
  check.call('without the native/foreign inputs nothing can be proven',
             StableClassConstants.analyze_native(ireps, nil, [clean_foreign]).empty? &&
               StableClassConstants.analyze_native(ireps, [native], nil).empty?)

  mutating_foreign = File.join(dir, 'mutating.rb')
  File.write(mutating_foreign, "Object.const_set(:Sneaky, Class.new)\n")
  check.call('a program that calls const_set caches nothing',
             StableClassConstants.analyze_native(ireps, [native], [mutating_foreign]).empty?)

  check.call('a native class a foreign source only REOPENS (adds methods to) is still admitted',
             StableClassConstants.analyze_native(ireps, [reopened_native], [foreign_reopener]).include?('ReopenedByForeign'))
  check.call('a native class a foreign source REASSIGNS (`Name = ...`) is refused',
             !StableClassConstants.analyze_native(ireps, [reassigned_native], [foreign_reassigner]).include?('ForeignReassigned'))

  # A name StableClassConstants.analyze itself would already admit (a plain
  # Ruby class/module statement, no native touch at all) is untouched by the
  # native proof -- the two never need to agree on the SAME name to both be
  # individually correct, but analyze_native must not invent evidence for a
  # name it was given no native source for.
  check.call('a name with no matching native definition at all is not admitted',
             !StableClassConstants.analyze_native(ireps, [native], [clean_foreign]).include?('Foreign'))

  # --- emission: identical mechanism as the ordinary StableClassConstants path
  CodeGen.stable_class_constants = admitted
  registry = build_registry(ireps, root_label)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  reader = registry.fetch('read_builtin').find { |md| md.owner == 'User' }
  irep = ireps.fetch(reader.irep)
  idx = irep.instructions.index { |insn| insn.op == 'GETCONST' }
  code = gen.compile_insn(irep.instructions[idx], irep, reader, idx)
  check.call('a builtin bare name reads through the SAME per-site cache helper as a Ruby-defined one',
             code.match?(/r\d+ = bc2cpp_cconst_0\(M\);/) && !code.include?('mrb_const_get'))
  CodeGen.stable_class_constants = Set.new
end

if failures.empty?
  puts 'bc2cpp native class constant check: PASS'
else
  warn "bc2cpp native class constant check: #{failures.size} failure(s)"
  exit 1
end
