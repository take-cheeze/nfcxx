# frozen_string_literal: true

# Names that several bc2cpp analyses read the same way: method names, and the constants whose `.new` makes a class.
# One list per meaning, so the analyses cannot drift apart: closed_world.rb, alias_sites.rb and computed_send_names.rb
# all require it.
module SendNames
  # Sends that change a method's visibility by name. A visibility send given an alias's answer hides it from
  # the registry, so both the closed world and ALIAS_SITES refuse to trust it.
  VISIBILITY_SENDS = %w[private public protected module_function].freeze
  # Sends that rebind a constant by name.
  CONST_REBINDERS = %w[const_set remove_const].freeze
  # Constants whose `.new` makes a class (or members) the registry cannot see.
  CLASS_FACTORIES = %w[Class Module Struct Data].freeze
  # Sends that forward a call to the method named by their first argument (`obj.send(:name, ...)`). A name
  # they forward is only known from that argument, so an analysis reads it as a call to that method by name.
  FORWARDING_SENDS = %w[send __send__ public_send].freeze
end
