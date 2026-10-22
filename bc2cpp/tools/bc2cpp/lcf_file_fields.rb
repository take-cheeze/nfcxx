# frozen_string_literal: true

require_relative 'lcf_schema_oracle'

# LCF_FILE_FIELDS: the class of a top-level field read from an LCF file object, `unit[:lower_layer]` on an exact
# LCF::MapUnit (or Database, MapTree, SaveData), from the schema alone.
#
# LcfSchemaOracle gives every field's classes; a root field's schema path is `<ROOT>/<name>` (MAP_UNIT/lower_layer).
# LcfRowFlow already proves a receiver is exactly one of these files, and `[]` on it is LCF::File#[] -> @root[key],
# whose class is the field's class (LCF.to_rb by `type`). A class-layout store that takes its value from such a read
# can be typed without running the reader: the value is what the schema says, or nil for an absent chunk.
#
# A field is an Array read only when every non-nil class its schema can give is Array. nil is allowed on purpose: an
# absent chunk reads nil, which class-layout facts already tolerate (every consumer re-checks the class at runtime),
# and a store like `x = unit[:k] || []` never keeps the nil.
module LcfFileFields
  module_function

  # True when `unit[key]` on an exact +file_class+ object is an Array or nil, by the schema.
  def array_field?(file_class, key, mrblib_dir = LcfSchemaOracle::LCF_SCHEMA_MRBLIB)
    root = roots(mrblib_dir)[file_class] or return false
    fact = facts(mrblib_dir)["#{root}/#{key}"] or return false

    non_nil = fact.classes.to_a - ['NilClass']
    non_nil == ['Array']
  end

  # Schema field facts keyed by "<ROOT>/<name>", read once per process.
  def facts(mrblib_dir)
    @facts ||= {}
    @facts[mrblib_dir] ||= LcfSchemaOracle.facts(mrblib_dir).to_h { |f| [f.path, f] }
  end

  # File class name => schema constant, read once per process.
  def roots(mrblib_dir)
    @roots ||= {}
    @roots[mrblib_dir] ||= LcfSchemaOracle.roots(mrblib_dir)
  end
end
