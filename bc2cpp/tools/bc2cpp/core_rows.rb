# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'diagnostics'
require_relative 'native_names'
require_relative 'c_call_rows'

# CORE_ROWS (closed only): core ROM entries the closed build keeps as rows (MRB_MT_CTOR_ROW, value 2 in the exclusion
# header) instead of method-table entries. A row answers only a lookup made for a receiver the compiler proved
# (bc2cpp_find_proven: owner calls, native singleton calls, the frame-free resolution); a by-name lookup, respond_to?
# and the method list do not see it. So an entry may become a row when the proof finds no other lookup of its name:
# CoreNativeCandidates.reachable runs again with the engine read through `engine_names` instead of every symbol its
# ireps hold, and with the generated code's symbol table left out of its literals.
module CoreRows
  module_function

  SYM_TABLE = /^[^\n]*bc2cpp_sym_names\[\d+\] = \{\n.*?^\};/m
  SYMREF = /bc2cpp_sym\(M, (\d+)\)/
  PRESYM = /MRB_(Q?SYM|SYM_[QBE])\(\s*([a-z_]\w*)\s*\)/
  OPSYM = /MRB_OPSYM\(\s*(\w+)\s*\)/
  SUFFIX = { 'SYM_Q' => '?', 'SYM_B' => '!', 'SYM_E' => '=' }.freeze
  # The by-name send helper, whose third argument is a symbol table index.
  INDEX_SEND = /\bbc2cpp_send\(M, [^,]+, (\d+)/
  # Lines whose symbol operands look no method up by name: variables and constants, keyword tables and hashes, a
  # Symbol value or a Symbol compared (a Symbol that may reach a lookup is SYMBOL_USES' to name), a table entry
  # (defines its name), and the diagnostics of a site proven to raise (bc2cpp_nomethod and the violation reports).
  INERT_LINES = [
    /mrb_iv_get\(|mrb_iv_set\(|bc2cpp_iv_set\(|mrb_gv_get\(|mrb_gv_set\(|bc2cpp_gv_set\(|mrb_const_|bc2cpp_const_/,
    /mrb_vm_define_(?:class|module)\(|mrb_define_(?:class|module)/,
    /bc2cpp_kw_table\[\d+\] = \{/,
    /mrb_hash_set\(M, bc2cpp_kwh, mrb_symbol_value\(/,
    /\A\s*r\d+ = mrb_symbol_value\((?:bc2cpp_sym\(M, \d+\)|MRB_(?:Q?SYM|SYM_[QBE])\(\w+\))\);\s*\z/,
    /\A\s*r\d+ = mrb_bool_value\(mrb_symbol_p\(r\d+\) && mrb_symbol\(r\d+\) == (?:bc2cpp_sym\(M, \d+\)|MRB_(?:Q?SYM|SYM_[QBE])\(\w+\))\);\s*\z/,
    /MRB_MT_ENTRY\w*\(/,
    /\bbc2cpp_(?:nomethod|guard_violation|hint_violation|nil_receiver)\w*\(/,
    # STEP_SUPER_STATIC: the name only names the frame of the entry called (StaticDispatchRegistrations::STEP_SUPER_STATIC_NAME).
    /\bbc2cpp_dyn_super_static\(/
  ].freeze
  # `mrb_sym name = <sym>;` is inert only as the operand of the constant read on the next line.
  CONST_NAME = /\A\s*mrb_sym name = bc2cpp_sym\(M, \d+\);\s*\z/
  # Bytecode operands that look nothing up: a send's (compiled as an owner or direct call, see generated_lookups), a
  # Symbol literal's (SYMBOL_USES) and a definition's name.
  QUIET_OPS = (BytecodeIR::Ops::SEND | %i[LOADSYM DEF TDEF SDEF]).freeze

  # What the engine may look up by name: the engine proof's dynamic names of the engine's own giving (Symbol literals
  # that may name a method, identifier literals that may be looked up, sends that may run as bytecode, names in a
  # native source outside 3rd/; not the core Ruby, 3rd/ native and generated-literal ones this run reads itself), the
  # names a `super` reaches, every other symbol operand of an engine irep (an alias source, an undef, ...), and the
  # lookups left in the generated code.
  def engine_names(ireps, generated, dynamic, super_names)
    names = Set.new(dynamic).merge(super_names)
    ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn, _index|
        # An operator opcode is compiled like a send (OPERATOR_ROWS): its by-name fallback, if any, is in +generated+.
        names << insn.sym.to_s if insn.sym && !QUIET_OPS.include?(insn.op)
        # An unresolved alias source keeps every symbol, as lookup_names does.
        names.merge(irep.syms.map(&:to_s)) if insn.op == :ALIAS && insn.first_of(:name).nil?
      end
    end
    # C_CALL_ROWS: a generated funcall's literal name finds a row where its entry would be (c_call_rows.rb).
    generated.each { |src| names.merge(generated_lookups(CCallRows.blank_generated(src))) }
    names
  end

  # The names a generated unit may still look up by name: a by-name send's symbol, and any symbol reference outside
  # INERT_LINES (a presym or a symbol table entry; the proven-receiver helpers take a bare index, which is no reference).
  def generated_lookups(src)
    table = src[/bc2cpp_sym_names\[\d+\] = \{\n(.*?)^\};/m, 1].to_s.scan(/^\s*"((?:[^"\\]|\\.)*)",/).flatten
    lines = src.sub(SYM_TABLE, '').lines
    found = Set.new
    lines.each_with_index do |line, k|
      line.scan(INDEX_SEND) { |(i)| found << table.fetch(i.to_i) }
      refs = []
      line.scan(SYMREF) { |(i)| refs << table.fetch(i.to_i) }
      line.scan(PRESYM) { |kind, name| refs << name + SUFFIX.fetch(kind, '') }
      line.scan(OPSYM) { |(c)| refs << OPSYM_TO_RUBY.fetch(c, c) }
      next if refs.empty?
      next if INERT_LINES.any? { |re| line.match?(re) }
      next if line.match?(CONST_NAME) && lines[k + 1].to_s.include?('mrb_const_get(')

      found.merge(refs)
    end
    found
  end

  def strip_sym_table(src)
    src.sub(SYM_TABLE, '')
  end
end
