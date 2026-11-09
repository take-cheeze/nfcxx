# frozen_string_literal: true

# PRESYM_SPELLING: the presym macro that names a method (3rd/mruby/lib/mruby/presym.rb), or nil for a name it has none
# for. ROM_METHOD_TABLES (codegen_emit.rb) keys its const tables with it; scripts/bc2cpp/rom_method_tables_check.rb too.
module PresymSpelling
  OPERATORS = {
    '!' => 'not', '%' => 'mod', '&' => 'and', '*' => 'mul', '+' => 'add', '-' => 'sub', '/' => 'div', '<' => 'lt',
    '>' => 'gt', '^' => 'xor', '`' => 'tick', '|' => 'or', '~' => 'neg', '!=' => 'neq', '!~' => 'nmatch', '**' => 'pow',
    '+@' => 'plus', '-@' => 'minus', '<<' => 'lshift', '<=' => 'le', '==' => 'eq', '=~' => 'match', '>=' => 'ge',
    '>>' => 'rshift', '[]' => 'aref', '<=>' => 'cmp', '===' => 'eqq', '[]=' => 'aset'
  }.freeze
  SUFFIX_MACROS = { '' => 'MRB_SYM', '?' => 'MRB_SYM_Q', '!' => 'MRB_SYM_B', '=' => 'MRB_SYM_E' }.freeze

  module_function

  def key(name)
    return "MRB_OPSYM(#{OPERATORS[name]})" if OPERATORS.key?(name)

    match = /\A([A-Za-z_][A-Za-z0-9_]*)([?!=]?)\z/.match(name)
    match && "#{SUFFIX_MACROS.fetch(match[2])}(#{match[1]})"
  end
end
