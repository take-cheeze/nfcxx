#!/usr/bin/env ruby
# frozen_string_literal: true

# Core method facts declared in sig/native (docs/adr/0470). Host only, a few seconds:
# 1. each fact file loads, and its loader rejects the malformed shapes it exists to keep out;
# 2. the facts read from the RBS match the real 3rd/mruby sources (skipped, with a SKIP line, when the submodule is
#    not checked out): the native registrations' owners and arities, the mrblib bodies, the Proc call_proc entries;
# 3. bc2cpp_cfunc_proc_call_p (bc2cpp.rb) spells the same Proc names as sig/native/core_proc_calls.rbs;
# 4. RbsSignatures does not read the fact files as program signatures;
# 5. the hierarchy helpers the generator's ancestor tables come from.
#
# Usage: ruby scripts/bc2cpp/core_facts_rbs_check.rb
require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/core_fact_sigs'
require_relative '../../tools/bc2cpp/core_hierarchy_sigs'
require_relative '../../tools/bc2cpp/rbs_signatures'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/native_names'
require_relative '../../tools/bc2cpp/native_expression_devirt'
require_relative '../../tools/bc2cpp/compiled_gems'

ROOT = File.expand_path('../..', __dir__)
MRUBY = File.join(ROOT, '3rd/mruby')

failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end

def rejects(loader, text)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'bad.rbs')
    File.write(path, text)
    CoreFactSigs.public_send(loader, path)
    false
  rescue RuntimeError
    true
  end
end

# 1. Loaders.
check.call('frame readers: block readers return bool, frame readers Binding',
           CoreFactSigs.block_given_names == %w[block_given? iterator?] && CoreFactSigs.frame_reading_names == %w[binding])
check.call('enumerator makers load', CoreFactSigs.enumerator_makers == %w[to_enum enum_for])
check.call('Proc call names load', CoreFactSigs.proc_call_names == %w[call yield [] ===])
check.call('class-test owners keep the first-declaration order of names and owners',
           CoreFactSigs.class_test_owners.keys == %w[is_a? kind_of? instance_of? nil? ! raise respond_to? class] &&
             CoreFactSigs.class_test_owners['nil?'] == %w[Kernel NilClass])
check.call('loaded facts are frozen',
           [CoreFactSigs.frame_readers, CoreFactSigs.enumerator_makers, CoreFactSigs.proc_call_names,
            CoreFactSigs.class_test_owners].all?(&:frozen?) && CoreFactSigs.class_test_owners.values.all?(&:frozen?))
check.call('frame readers: rejects another return type', rejects(:frame_readers, "module Kernel\n  def caller: () -> Array[String]\nend\n"))
check.call('frame readers: rejects an argument', rejects(:frame_readers, "module Kernel\n  def binding: (Integer) -> Binding\nend\n"))
check.call('frame readers: rejects an owner other than Kernel', rejects(:frame_readers, "class Object\n  def binding: () -> Binding\nend\n"))
check.call('frame readers: rejects Kernel declared as a class', rejects(:frame_readers, "class Kernel\n  def binding: () -> Binding\nend\n"))
check.call('frame readers: rejects a block', rejects(:frame_readers, "module Kernel\n  def binding: () { () -> void } -> Binding\nend\n"))
check.call('frame readers: rejects an overload', rejects(:frame_readers, "module Kernel\n  def iterator?: () -> bool\n    | (Integer) -> bool\nend\n"))
check.call('frame readers: rejects a name declared twice',
           rejects(:frame_readers, "module Kernel\n  def iterator?: () -> bool\nend\nmodule Kernel\n  def iterator?: () -> bool\nend\n"))
check.call('enumerator makers: rejects a non-Enumerator return', rejects(:enumerator_makers, "module Kernel\n  def to_a: () -> Array[untyped]\nend\n"))
check.call('Proc calls: rejects a fixed arity', rejects(:proc_call_names, "class Proc\n  def call: (untyped) -> untyped\nend\n"))
check.call('Proc calls: rejects a typed return', rejects(:proc_call_names, "class Proc\n  def call: (*untyped) -> Integer\nend\n"))
check.call('Proc calls: rejects a superclass line', rejects(:proc_call_names, "class Proc < Object\n  def call: (*untyped) -> untyped\nend\n"))
check.call('class tests: rejects an owner outside the list', rejects(:class_test_owners, "class Object\n  def nil?: () -> bool\nend\n"))
check.call('class tests: rejects a singleton method', rejects(:class_test_owners, "module Kernel\n  def self.nil?: () -> bool\nend\n"))
check.call('class tests: rejects a rest parameter', rejects(:class_test_arities, "module Kernel\n  def raise: (*untyped) -> bot\nend\n"))

# 2. Against 3rd/mruby.
# (required, optional) of a registration's aspec; nil for a form this check does not read.
def aspec_arity(aspec)
  parts = aspec.to_s.split('|').map(&:strip).reject { |part| part == 'MRB_MT_PRIVATE' }
  return nil unless parts.size == 1

  case parts.first
  when 'MRB_ARGS_NONE()' then [0, 0]
  when /\AMRB_ARGS_REQ\((\d+)\)\z/ then [Regexp.last_match(1).to_i, 0]
  when /\AMRB_ARGS_OPT\((\d+)\)\z/ then [0, Regexp.last_match(1).to_i]
  when /\AMRB_ARGS_ARG\((\d+),\s*(\d+)\)\z/ then [Regexp.last_match(1).to_i, Regexp.last_match(2).to_i]
  end
end

# The C symbol spellings of a method name: "name", MRB_SYM(name), MRB_SYM_Q(name without ?), MRB_OPSYM(op).
OPSYMS = { '[]' => 'aref', '===' => 'eqq', '!' => 'not' }.freeze
def sym_patterns(name)
  base = name.delete_suffix('?')
  pats = [Regexp.escape("\"#{name}\"")]
  pats << (name.end_with?('?') ? "MRB_SYM_Q\\(#{Regexp.escape(base)}\\)" : "MRB_SYM\\(#{Regexp.escape(name)}\\)")
  pats << "MRB_OPSYM\\(#{OPSYMS[name]}\\)" if OPSYMS[name]
  "(?:#{pats.join('|')})"
end

if File.file?(File.join(MRUBY, 'src/kernel.c'))
  natives = core_native_srcs(MRUBY)
  registrations, opaque = NativeExpressionDevirt.scan_class_registrations(natives)
  owners_of = ->(name) { registrations.fetch(name, []).map { |entry| entry[:owner]&.fetch(:class_name, nil) }.uniq.sort }

  CoreFactSigs.class_test_arities.each do |owner, name, required, optional|
    entries = registrations.fetch(name, []).select { |entry| entry[:owner]&.fetch(:class_name, nil) == owner }
    check.call("class tests: #{owner}##{name} is one native registration taking #{required}..#{required + optional} arguments",
               entries.size == 1 && aspec_arity(entries.first[:aspec]) == [required, optional])
  end
  CoreFactSigs.class_test_owners.each do |name, owners|
    check.call("class tests: #{name} is registered on #{owners.join(', ')} and nothing else",
               owners_of.call(name) == owners.sort && opaque.fetch(name, []).empty?)
  end

  CoreFactSigs.block_given_names.each do |name|
    entries = registrations.fetch(name, [])
    check.call("frame readers: Kernel##{name} is mrb_f_block_given_p_m with no arguments",
               owners_of.call(name) == %w[Kernel] && entries.all? { |e| e[:function] == 'mrb_f_block_given_p_m' && aspec_arity(e[:aspec]) == [0, 0] })
  end
  CoreFactSigs.frame_reading_names.each do |name|
    re = /mrb_define_private_method_id\(\s*mrb,\s*mrb->kernel_module,\s*#{sym_patterns(name)},\s*\w+,\s*MRB_ARGS_NONE\(\)\s*\)/
    hits = natives.select { |path| File.binread(path).match?(re) }
    check.call("frame readers: Kernel##{name} is a private native on Kernel taking no arguments (#{hits.map { |h| h.delete_prefix("#{MRUBY}/") }.join(', ')})",
               hits.size == 1)
  end

  enum_text = File.binread(File.join(MRUBY, 'mrbgems/mruby-enumerator/mrblib/enumerator.rb'))
  kernel = enum_text[/^module Kernel\n(.*?)^end\n/m, 1].to_s
  makers = CoreFactSigs.enumerator_makers
  defined = makers.select do |name|
    kernel.match?(/^  def #{Regexp.escape(name)}\(meth=:each, \*args, \*\*kwd\)\n    Enumerator\.new self, meth, \*args, \*\*kwd\n  end\n/)
  end
  check.call("enumerators: mruby-enumerator's Kernel defines #{defined.join(', ')} as `Enumerator.new self, meth, ...`", !defined.empty?)
  (makers - defined).each do |name|
    check.call("enumerators: Kernel##{name} is an alias of a modelled maker",
               defined.any? { |target| kernel.match?(/^  alias #{Regexp.escape(name)} #{Regexp.escape(target)}\n/) })
  end

  proc_init = File.binread(File.join(MRUBY, 'src/proc.c'))[/^mrb_init_proc\(mrb_state \*mrb\)\n\{\n.*?^\}\n/m].to_s
  proc_ext = File.binread(File.join(MRUBY, 'mrbgems/mruby-proc-ext/mrblib/proc.rb'))
  proc_ext_class = proc_ext[/^class Proc\n(.*?)^end\n/m, 1].to_s
  CoreFactSigs.proc_call_names.each do |name|
    raw = proc_init.include?('MRB_METHOD_FROM_PROC(m, &call_proc);') &&
          proc_init.match?(/mrb_define_method_raw\(mrb, pc, #{sym_patterns(name)}, m\);/)
    ruby = proc_ext_class.match?(/^  def #{Regexp.escape(name)}\(\*args\)\n    call\(\*args\)\n  end\n/)
    check.call("Proc calls: Proc##{name} is call_proc (src/proc.c) or `call(*args)` (mruby-proc-ext)", raw ^ ruby)
  end
else
  puts '  SKIP the real 3rd/mruby is not checked out'
end

# 3. The runtime's spelling of the Proc call names.
runtime = File.read(File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'))[/static bool bc2cpp_cfunc_proc_call_p\(.*?\n    \}\n/m].to_s
spelled = runtime[/if \(!name \|\| !\((.*?)\)\) return false;/, 1].to_s.scan(/!strcmp\(name, "([^"]+)"\)/).flatten
check.call('bc2cpp_cfunc_proc_call_p spells exactly sig/native/core_proc_calls.rbs', spelled == CoreFactSigs.proc_call_names)

# 4. Not program signatures.
listed = RbsSignatures.files_in([File.join(ROOT, 'sig')]).map { |f| File.expand_path(f) }
check.call('RbsSignatures skips the fact files and still reads the other sig/native files',
           (listed & CoreFactSigs::FILES).empty? && listed.include?(CoreHierarchySigs::PATH))

# 5. Hierarchy helpers.
check.call('ancestors: Object, then Kernel, then BasicObject', CoreHierarchySigs.ancestors('Object') == %w[Object Kernel BasicObject])
check.call('ancestors: Array mixes Enumerable in before Object', CoreHierarchySigs.ancestors('Array') == %w[Array Enumerable Object Kernel BasicObject])
check.call('superclasses_below: Integer up to Object', CoreHierarchySigs.superclasses_below('Integer', 'Object') == %w[Integer Numeric])
check.call('superclasses_below: rejects a stop that is not a superclass',
           begin
             CoreHierarchySigs.superclasses_below('Integer', 'String')
             false
           rescue RuntimeError
             true
           end)
check.call('subclasses: Numeric has Integer and Float', CoreHierarchySigs.subclasses('Numeric') == %w[Integer Float])
check.call('scan spellings follow their class', CoreHierarchySigs.with_scan_spellings(%w[NilClass Object BasicObject]) ==
                                               %w[NilClass Nil Object BasicObject Basic_object])

puts failures.empty? ? 'core facts rbs: all checks passed' : "core facts rbs: #{failures.size} failure(s)"
exit(failures.empty? ? 0 : 1)
