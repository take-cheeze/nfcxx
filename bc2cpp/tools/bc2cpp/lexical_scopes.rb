# frozen_string_literal: true

# Lexical constant lookup candidates, shared frozen strings: the receiver trace asks the same owner and name
# questions once per walk step (docs/bc2cpp-trace-loader-allocations.md).
module LexicalScopes
  PREFIXES = {}
  QUALIFIED = Hash.new { |table, prefix| table[prefix] = {} }

  # The scopes enclosing +owner+'s body, innermost first: `A::B` (or `A::B.singleton`) -> [`A::B`, `A`].
  def self.prefixes(owner)
    key = owner.to_s
    PREFIXES[key] ||= begin
      nesting = key.sub(/\.singleton\z/, '').split('::')
      nesting.length.downto(1).map { |n| nesting.first(n).join('::').freeze }.freeze
    end
  end

  # `prefix::name`.
  def self.qualify(prefix, name)
    QUALIFIED[prefix][name] ||= "#{prefix}::#{name}".freeze
  end
end
