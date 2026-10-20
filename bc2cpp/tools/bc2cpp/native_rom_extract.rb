# frozen_string_literal: true

require 'json'

# Native method registrations from the clang AST (the JSON of `clang -fsyntax-only -Xclang -ast-dump=json`).
#
#   clang -fsyntax-only -Xclang -ast-dump=json <flags> SOURCE | ruby native_rom_extract.rb
#
# mruby 3 registers most core methods in a static ROM table, `static const mrb_mt_entry NAME_rom_entries[] = {
# MRB_MT_ENTRY(fn, SYM, ARGS), ... }`, installed by MRB_MT_INIT_ROM. Each entry names one C function. The function is
# a direct-call candidate when this translation unit defines it (its FunctionDecl has a body): a call site may then
# call it by name without dispatch. A function defined elsewhere (or a macro that expands to no plain function) is
# reported as not defined here.
#
# Output: one JSON object per table: { "table" => name, "entries" => [{ "function" => fn, "defined" => bool }] }.
module NativeRomExtract
  module_function

  def tables(ast)
    found = []
    stack = [ast]
    until stack.empty?
      node = stack.pop
      case node
      when Hash
        found << node if node['kind'] == 'VarDecl' && node['name'].to_s.end_with?('_rom_entries') && node['inner']
        node.each_value { |v| stack << v if v.is_a?(Hash) || v.is_a?(Array) }
      when Array
        node.each { |v| stack << v if v.is_a?(Hash) || v.is_a?(Array) }
      end
    end
    found
  end

  # Every function defined (has a body) in the translation unit, by name.
  def defined_functions(ast)
    names = Set.new
    stack = [ast]
    until stack.empty?
      node = stack.pop
      case node
      when Hash
        if node['kind'] == 'FunctionDecl' && node['name'] && node['inner']&.any? { |c| c['kind'] == 'CompoundStmt' }
          names << node['name']
        end
        node.each_value { |v| stack << v if v.is_a?(Hash) || v.is_a?(Array) }
      when Array
        node.each { |v| stack << v if v.is_a?(Hash) || v.is_a?(Array) }
      end
    end
    names
  end

  # The function an MRB_MT_ENTRY names: the first DeclRefExpr to a FunctionDecl in the entry.
  def entry_function(entry)
    stack = [entry]
    until stack.empty?
      node = stack.pop
      case node
      when Hash
        ref = node['referencedDecl']
        return ref['name'] if ref && ref['kind'] == 'FunctionDecl' && ref['name']

        node.each_value { |v| stack << v if v.is_a?(Hash) || v.is_a?(Array) }
      when Array
        node.each { |v| stack << v if v.is_a?(Hash) || v.is_a?(Array) }
      end
    end
    nil
  end

  # The presym constant an MRB_SYM / MRB_OPSYM argument expands to (`MRB_SYM_clear`, `MRB_OPSYM__aref`), or nil.
  def entry_symbol(entry)
    stack = [entry]
    until stack.empty?
      node = stack.pop
      case node
      when Hash
        ref = node['referencedDecl']
        return ref['name'] if ref && ref['name'].to_s.match?(/\AMRB_(?:OP)?SYM_/)

        node.each_value { |v| stack << v if v.is_a?(Hash) || v.is_a?(Array) }
      when Array
        node.each { |v| stack << v if v.is_a?(Hash) || v.is_a?(Array) }
      end
    end
    nil
  end

  def extract(ast)
    defined = defined_functions(ast)
    tables(ast).map do |table|
      init = table['inner'].find { |c| c['kind'] == 'InitListExpr' }
      entries = (init ? init['inner'] : []).map do |entry|
        fn = entry_function(entry)
        { 'function' => fn, 'symbol' => entry_symbol(entry), 'defined' => !fn.nil? && defined.include?(fn) }
      end
      { 'table' => table['name'], 'entries' => entries }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require 'set'
  puts JSON.pretty_generate(NativeRomExtract.extract(JSON.parse($stdin.read)))
end
