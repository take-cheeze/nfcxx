# frozen_string_literal: true

# Method names that several bc2cpp analyses read the same way. One list per meaning, so the analyses cannot
# drift apart: closed_world.rb, alias_sites.rb and computed_send_names.rb all require it.
module SendNames
  # Sends that change a method's visibility by name. A visibility send given an alias's answer hides it from
  # the registry, so both the closed world and ALIAS_SITES refuse to trust it.
  VISIBILITY_SENDS = %w[private public protected private_class_method public_class_method module_function].freeze
  # Sends that rebind a constant by name. `autoload` binds one lazily, so it rebinds like the others.
  CONST_REBINDERS = %w[const_set remove_const autoload].freeze
  # Sends that forward a call to the method named by their first argument (`obj.send(:name, ...)`). A name
  # they forward is only known from that argument, so an analysis reads it as a call to that method by name.
  FORWARDING_SENDS = %w[send __send__ public_send].freeze
end
