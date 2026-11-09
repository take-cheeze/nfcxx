# frozen_string_literal: true

require_relative 'native_owner_map'

# NativeRomOwners: the class each MRB_MT_ENTRY method table belongs to. mruby registers a core class's methods in a
# static table, `static const mrb_mt_entry NAME_rom_entries[] = { MRB_MT_ENTRY(fn, MRB_SYM(name), ...), ... }`, and an
# init function installs it with `MRB_MT_INIT_ROM(mrb, VAR, NAME_rom_entries)`. VAR is the class, so the owner is
# read from VAR's last assignment before the install in the same function body:
#
#   VAR = mrb_define_class_id(mrb, MRB_SYM(Name), ...)   -> Name
#   VAR = mrb_define_class(mrb, "Name", ...)             -> Name
#   VAR = mrb_class_get_id(mrb, MRB_SYM(Name))           -> Name
#   VAR = mrb-><core field>                              -> the field's class (NativeOwnerMap::CORE_FIELD_OWNERS)
#   VAR = mrb_define_class_under_id(mrb, OUTER, MRB_SYM(Name), ...) -> OUTER's owner::Name (Name under Object)
#   VAR = OTHER                                          -> OTHER's owner, up to MAX_COPY_HOPS copies
#
# Anything else (an outer class it cannot resolve, a computed name, an install outside its function) is UNKNOWN.
# Unknown is recorded rather than guessed: the caller treats those entries as unattributed, as NativeOwnerMap does today.
#
#   ruby tools/bc2cpp/native_rom_owners.rb FILE...        # per table: owner, entry count
module NativeRomOwners
  UNKNOWN = NativeOwnerMap::UNKNOWN
  # How many `VAR = OTHER` copies the resolver follows before it gives up.
  MAX_COPY_HOPS = 2

  INSTALL = /MRB_MT_INIT_ROM\s*\(\s*mrb\s*,\s*(.+?)\s*,\s*(\w+)\s*\)/
  TABLE = /static\s+const\s+mrb_mt_entry\s+(\w+)\s*\[\]\s*=\s*\{(.*?)\}\s*;/m
  ENTRY = /MRB_MT_ENTRY\s*\(\s*(\w+)\s*,\s*MRB_\w*SYM\w*\s*\(\s*(\w+)\s*\)/
  DEFINE = /\Amrb_define_(?:class|module)(?:_id)?\s*\(\s*mrb\s*,\s*(?:MRB_SYM\s*\(\s*(\w+)\s*\)|"(\w+)")/
  UNDER = /\Amrb_(?:define_(?:class|module)|(?:class|module)_get)_under(?:_id)?\s*\(\s*mrb\s*,\s*((?:mrb->)?\w+)\s*,\s*
             (?:MRB_SYM\s*\(\s*(\w+)\s*\)|"(\w+)")/x
  CLASS_GET = /\Amrb_class_get(?:_id)?\s*\(\s*mrb\s*,\s*(?:MRB_SYM\s*\(\s*(\w+)\s*\)|"(\w+)")\s*\)\z/
  FIELD = /\Amrb->(\w+)\z/
  IDENT = /\A(\w+)\z/

  module_function

  # One source file: { tables: { name => { owner:, entries: [[fn, method]] } }, installs: [[table, owner]] }.
  def analyze_file(path)
    analyze(File.binread(path).force_encoding(Encoding::UTF_8).scrub)
  end

  def analyze(text)
    tables = {}
    text.scan(TABLE) do |name, body|
      tables[name] = { owner: nil, entries: body.scan(ENTRY) }
    end
    installs = []
    text.scan(INSTALL) do
      match = Regexp.last_match
      owner = owner_of(text, match.begin(0), match[1].strip)
      tables[match[2]] ||= { owner: nil, entries: [] }
      tables[match[2]][:owner] = owner
      installs << [match[2], owner]
    end
    { tables: tables, installs: installs }
  end

  # The owner of the expression +arg+ used at +pos+ in +text+.
  def owner_of(text, pos, arg, depth = 0)
    return UNKNOWN if depth > MAX_COPY_HOPS

    if (m = CLASS_GET.match(arg))
      m[1] || m[2]
    elsif (m = FIELD.match(arg))
      NativeOwnerMap::CORE_FIELD_OWNERS.fetch(m[1], UNKNOWN)
    elsif (m = IDENT.match(arg))
      rhs = last_assignment(text, pos, m[1])
      owner = rhs ? owner_of(text, pos, rhs, depth + 1) : UNKNOWN
      owner == UNKNOWN ? named_class(text, pos, m[1]) : owner
    elsif (m = DEFINE.match(arg))
      m[1] || m[2]
    elsif (m = UNDER.match(arg))
      # The outer class is resolved as part of this step, not as another copy.
      outer = owner_of(text, pos, m[1], depth)
      name = m[2] || m[3]
      if outer == UNKNOWN then UNKNOWN
      elsif outer == 'Object' then name
      else "#{outer}::#{name}"
      end
    else
      UNKNOWN
    end
  end

  # The class a `mrb_class_name_class(mrb, NULL, VAR, MRB_SYM(Name))` call names before +pos+, or UNKNOWN. It is the
  # call that sets the class's name, so it is authoritative for a VAR that boots from a helper (boot_defclass).
  def named_class(text, pos, var)
    body_start = text.rindex("\n{\n", pos) || 0
    window = text[body_start...pos]
    name = UNKNOWN
    window.scan(/mrb_class_name_class\s*\(\s*mrb\s*,\s*NULL\s*,\s*#{Regexp.escape(var)}\s*,\s*MRB_SYM\s*\(\s*(\w+)\s*\)/) do
      name = Regexp.last_match(1)
    end
    name
  end

  # The right-hand side of the last `VAR = ...;` before +pos+ in the same function body, or nil.
  def last_assignment(text, pos, var)
    body_start = text.rindex("\n{\n", pos) || 0
    window = text[body_start...pos]
    rhs = nil
    window.scan(/(?<![\w>.])#{Regexp.escape(var)}\s*=(?!=)\s*([^;]+);/) { rhs = Regexp.last_match(1).strip }
    # `mrb->eException_class = mrb_define_class_id(...)`: the value is the right-most part of a chained assignment.
    rhs&.sub(/\A(?:(?:mrb->)?\w+\s*=(?!=)\s*)+/, '')
  end
end

if $PROGRAM_NAME == __FILE__
  totals = Hash.new(0)
  ARGV.each do |path|
    result = NativeRomOwners.analyze_file(path)
    result[:tables].each do |name, info|
      known = info[:owner] != NativeRomOwners::UNKNOWN
      totals[known ? :resolved : :unknown] += 1
      totals[:entries] += info[:entries].size
      puts format('%-40s %-28s %-16s %d entries', path, name, info[:owner] || '(not installed here)', info[:entries].size)
    end
  end
  puts format('tables: %d resolved, %d unknown; %d entries', totals[:resolved], totals[:unknown], totals[:entries])
end
