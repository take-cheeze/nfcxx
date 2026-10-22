# frozen_string_literal: true

require 'set'
require_relative 'native_names'
require_relative 'native_direct'
require_relative 'irep'

# NATIVE_OWNER_MAP (docs/adr/0397): for each method name, the classes some native C registration
# defines it on, with the class expression each call names. A poly chain that calls a Ruby body
# directly for each candidate class is sound only when no native registration of the name lands on
# one of those classes (a native def on the same class is the live method). `verdict` answers that
# per name and arm set.
#
# Conservative by construction: a class expression that is not a literal class or a known core field
# records UNKNOWN; a registration whose name is computed records its owner in `computed`, which
# defeats every name that owner could reach; a ROM method-table entry (MRB_MT_ENTRY) is not
# attributed to a class and so makes its name UNKNOWN. Function definitions and prototypes are not
# registrations and are skipped.
module NativeOwnerMap
  UNKNOWN = :unknown

  # mrb_state's class fields (3rd/mruby/include/mruby.h) and the class each one holds.
  CORE_FIELD_OWNERS = {
    'object_class' => 'Object', 'class_class' => 'Class', 'module_class' => 'Module',
    'proc_class' => 'Proc', 'string_class' => 'String', 'array_class' => 'Array',
    'hash_class' => 'Hash', 'range_class' => 'Range', 'float_class' => 'Float',
    'integer_class' => 'Integer', 'true_class' => 'TrueClass', 'false_class' => 'FalseClass',
    'nil_class' => 'NilClass', 'symbol_class' => 'Symbol', 'kernel_module' => 'Kernel'
  }.freeze

  # mrb_state fields that hold an instance rather than a class. The singleton of `mrb->top_self` is the main object's
  # only: it is attributed to the instance's class, Object, with no singleton suffix. That is conservative: an exact
  # Object arm then sees a native definition and is refused, which an exact arm needs for the main object anyway.
  INSTANCE_FIELD_OWNERS = { 'top_self' => 'Object' }.freeze

  # Registration families. `name`, `owner` and `fn` (the C function, where the family takes one) are argument indexes
  # (the first is the mrb state); `suffix` is how the owner is recorded: nil for the instance table, '.singleton' for
  # the class-object table, :both for a module_function (instance and class table).
  FAMILIES = {
    'define_method' => { name: 2, owner: 1, suffix: nil, fn: 3 },
    'define_method_id' => { name: 2, owner: 1, suffix: nil, fn: 3 },
    'define_method_raw' => { name: 2, owner: 1, suffix: nil },
    'define_private_method' => { name: 2, owner: 1, suffix: nil, fn: 3 },
    'define_private_method_id' => { name: 2, owner: 1, suffix: nil, fn: 3 },
    'define_class_method' => { name: 2, owner: 1, suffix: '.singleton', fn: 3 },
    'define_class_method_id' => { name: 2, owner: 1, suffix: '.singleton', fn: 3 },
    'define_singleton_method' => { name: 2, owner: 1, suffix: '.singleton', fn: 3 },
    'define_singleton_method_id' => { name: 2, owner: 1, suffix: '.singleton', fn: 3 },
    'define_module_function' => { name: 2, owner: 1, suffix: :both, fn: 3 },
    'define_module_function_id' => { name: 2, owner: 1, suffix: :both, fn: 3 },
    'define_alias' => { name: 2, owner: 1, suffix: nil, alias_of: 3 },
    'define_alias_id' => { name: 2, owner: 1, suffix: nil, alias_of: 3 },
    'alias_method' => { name: 2, owner: 1, suffix: nil },
    'undef_method' => { name: 2, owner: 1, suffix: nil },
    'undef_method_id' => { name: 2, owner: 1, suffix: nil },
    'undef_class_method' => { name: 2, owner: 1, suffix: '.singleton' },
    'undef_class_method_id' => { name: 2, owner: 1, suffix: '.singleton' }
  }.freeze

  # Calls that look like a definer the table above does not parse: counted as a refusal, not ignored.
  DEFINER_LIKE = /\A(define_(method|class_method|module_function|private_method|singleton_method|alias)\w*|
                    undef_(method|class_method)\w*|alias_method)\z/x
  CALL_RE = /\bmrb_(define_\w+|undef_\w+|alias_method|prepend_module|include_module)\s*\(/
  STRING_LIT_RE = /\A"((?:[^"\\]|\\.)*)"\z/
  SYM_RE = /\A#{MRB_SYM_TOKEN_RE}\z/
  CLASS_GET_RE = /\Amrb_(?:class|module)_get\(\s*\w+\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)\z/
  DEFINE_CLASS_RE = /\Amrb_define_(?:class|module)\(\s*\w+\s*,\s*"((?:[^"\\]|\\.)*)"/
  DEFINE_CLASS_ID_RE = /\Amrb_define_(?:class|module)_id\(\s*\w+\s*,\s*MRB_SYM\((\w+)\)/
  UNDER_RE = /\Amrb_(?:define_(?:class|module)|(?:class|module)_get)_under\(\s*\w+\s*,\s*(\w+)\s*,\s*"((?:[^"\\]|\\.)*)"/
  CLASS_GET_ID_RE = /\Amrb_(?:class|module)_get_id\(\s*\w+\s*,\s*MRB_SYM\((\w+)\)\s*\)\z/
  ROM_TABLE_RE = /\bmrb_mt_entry\s+(\w+)\s*\[\s*\]\s*=\s*\{/
  ROM_ENTRY_RE = /MRB_MT_ENTRY\s*\(\s*\w+\s*,\s*#{MRB_SYM_TOKEN_RE}/

  # by_name: literal name => Set of owners (class strings, '.singleton' suffixed, or UNKNOWN).
  # computed: owners of registrations whose name is not a literal (any name may be defined there);
  # computed_unknown: one of those owners is UNKNOWN. refusals: global facts that defeat every proof.
  # core_dynamic_unknown counts computed-name registrations in mruby's own sources (3rd/mruby) whose
  # owner is not a known class: the core's API forwarders and reflection primitives install a name the
  # Ruby program or a caller supplies, which the Ruby side's closed world already treats as a dynamic
  # install (unknown_defs). `verdict` refuses them unless the caller trusts that (core_dynamic_trusted:).
  Result = Struct.new(:by_name, :computed, :computed_unknown, :core_dynamic_unknown, :refusals, :calls, :registrations, :aliases,
                      keyword_init: true)

  module_function

  # The top-level comma split of the balanced argument list whose '(' is at index `open`, and the
  # index of its ')'. nil when unbalanced.
  def call_args(text, open)
    depth = 0
    args = []
    cur = +''
    i = open
    while i < text.length
      c = text[i]
      if c == '"' || c == "'"
        j = i + 1
        j += (text[j] == '\\' ? 2 : 1) while j < text.length && text[j] != c
        cur << text[i..j]
        i = j + 1
        next
      end
      if c == '('
        cur << c unless depth.zero?
        depth += 1
      elsif c == ')'
        depth -= 1
        return [args << cur.strip, i] if depth.zero?

        cur << c
      elsif c == ',' && depth == 1
        args << cur.strip
        cur = +''
      elsif depth >= 1
        cur << c
      end
      i += 1
    end
    nil
  end

  # A function definition or prototype: its body or `;` follows the closing paren and a return type
  # precedes the name on its line. Such a text is not a registration.
  def definition?(text, start, close)
    after = text[(close + 1)..] || ''
    return true if after.match?(/\A\s*\{/)

    line_start = (text.rindex("\n", start - 1) || -1) + 1
    prefix = text[line_start...start]
    prefix.match?(/\A\s*[A-Za-z_][\w\s*]*\z/) && after.match?(/\A\s*;/)
  end

  def name_of(arg)
    if (m = STRING_LIT_RE.match(arg)) then unescape_c_string(m[1])
    elsif (m = SYM_RE.match(arg)) then resolve_mrb_sym_token(m[1], m[2])
    end
  end

  # The owner a class expression names: a literal class, a core field, or a class variable the file
  # defines; anything else is UNKNOWN.
  def owner_of(arg, vars)
    return vars[arg] || UNKNOWN if arg.match?(/\A\w+\z/)
    return CORE_FIELD_OWNERS.fetch(Regexp.last_match(1)) { INSTANCE_FIELD_OWNERS.fetch(Regexp.last_match(1), UNKNOWN) } if arg.match(/\Amrb->(\w+)\z/)
    return unescape_c_string(Regexp.last_match(1)) if arg.match(CLASS_GET_RE)
    return Regexp.last_match(1) if arg.match(CLASS_GET_ID_RE)
    return unescape_c_string(Regexp.last_match(1)) if arg.match(DEFINE_CLASS_RE)
    return Regexp.last_match(1) if arg.match(DEFINE_CLASS_ID_RE)
    if (m = arg.match(UNDER_RE))
      parent = owner_of(m[1], vars)
      return parent == UNKNOWN ? UNKNOWN : "#{parent}::#{unescape_c_string(m[2])}"
    end

    UNKNOWN
  end

  # The top-level brace blocks of `text` (function bodies), each as [from, to, scope], where scope is
  # `vars` overlaid with what that block's own `RClass *` variables hold. Braces inside string or char
  # literals are blanked first so they cannot unbalance the count.
  TRANSPARENT_BLOCK_RE = /(?:\bnamespace(?:\s+[\w:]+)?|\bextern\s*"C")\s*\z/

  def block_scopes(text, vars)
    blank = text.gsub(/"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'/) { |tok| ' ' * tok.size }
    scopes = []
    depth = 0
    start = nil
    prev = 0
    cursor = 0
    while (brace = /[{}]/.match(blank, cursor))
      i = brace.begin(0)
      cursor = brace.end(0)
      c = brace[0]
      if c == '{'
        start = i if depth.zero?
        depth += 1
      elsif c == '}' && depth.positive?
        depth -= 1
        next unless depth.zero?

        signature = text[prev...start]
        if signature.match?(TRANSPARENT_BLOCK_RE)
          # OUTSIDE_OWNER_CALL (ADR 0468): a C++ namespace or `extern "C"` block holds functions, not a body.
          inner = start + 1
          scopes.concat(block_scopes(text[inner...i], vars).map { |from, to, scope| [from + inner, to + inner, scope] })
        else
          scopes << [start, i, vars.merge(block_owners(text[start..i], signature, vars))]
        end
        prev = i + 1
      end
    end
    scopes
  end

  # The owners of the `RClass *` variables a function body declares and assigns, plus its `RClass *`
  # parameters (which keep the file's owner for them). A declared variable whose assignments disagree,
  # or one of whose right-hand sides is not a known class, is UNKNOWN. `a = B = C` gives `a` B's value.
  # OUTSIDE_OWNER_CALL (ADR 0468): a right-hand side may name another variable of the same body
  # (`RClass* m = mrb_define_module(M, "RGSS"); RClass* color = mrb_define_class_under(M, m, "Color", ...)`),
  # so the owners are settled to a fixed point over the body's own variables; and a variable assigned once
  # from an expression this map cannot read is the class a core field names when the body stores it there
  # (`mod = boot_defclass(...); mrb->module_class = mod;`) or the class mruby names after it
  # (`mrb_class_name_class(mrb, NULL, bob, MRB_SYM(BasicObject))`).
  def block_owners(body, signature, vars)
    params = signature.scan(/RClass\s*\*\s*(\w+)\s*[,)]/).flatten
    declared = body.scan(/RClass\s*\*\s*(\w+)/).flatten.to_set
    rhs = Hash.new { |h, k| h[k] = [] }
    # Matched on the body with its string and char literals blanked (a `"color="` registration is not an
    # assignment to `color`); the right-hand side is read back from the body itself.
    blank = body.gsub(/"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'/) { |tok| ' ' * tok.size }
    blank.scan(/(?<![\w>.])(\w+)\s*=(?!=)([^;]*);/) do
      scan = Regexp.last_match
      next unless declared.include?(scan[1])

      rhs[scan[1]] << body[scan.begin(2)...scan.end(2)].split(/(?<![=!<>])=(?!=)/).first.to_s.strip
    end
    named = Hash.new { |h, k| h[k] = Set.new }
    body.scan(/(?<![\w.])mrb->(\w+)\s*=(?!=)\s*(\w+)\s*;/) do |field, var|
      named[var] << CORE_FIELD_OWNERS[field] if CORE_FIELD_OWNERS.key?(field)
    end
    body.scan(/\bmrb_class_name_class\(\s*\w+\s*,\s*NULL\s*,\s*(\w+)\s*,\s*MRB_SYM\((\w+)\)\s*\)/) do |var, const|
      named[var] << const
    end
    out = {}
    params.each { |var| out[var] = vars[var] || UNKNOWN }
    4.times do
      scope = vars.merge(out.reject { |_, owner| owner == UNKNOWN })
      settled = declared.to_h do |var|
        owners = rhs[var].map { |text| owner_of(text, scope.reject { |k, _| k == var }) }.uniq
        owner = owners.size == 1 ? owners.first : UNKNOWN
        owner = named[var].first if owner == UNKNOWN && rhs[var].size == 1 && named[var].size == 1
        [var, owner || UNKNOWN]
      end
      break if settled.all? { |var, owner| out[var] == owner }

      out.merge!(settled)
    end
    out
  end

  # The body of the brace block whose '{' is at index `open`, or nil when unbalanced.
  def brace_body(text, open)
    depth = 0
    (open...text.length).each do |i|
      depth += 1 if text[i] == '{'
      depth -= 1 if text[i] == '}'
      return text[(open + 1)...i] if depth.zero?
    end
    nil
  end

  def build(paths)
    result = Result.new(by_name: Hash.new { |h, k| h[k] = Set.new }, computed: Set.new, registrations: [], aliases: [],
                        computed_unknown: false, core_dynamic_unknown: 0, refusals: Hash.new(0), calls: 0)
    Array(paths).each do |path|
      text = NativeDirect.strip_comments(File.binread(path).force_encoding('UTF-8'))
      # `struct RClass *x` is the same variable as `RClass *x` for the owner table.
      typed = text.gsub(/struct\s+RClass\s*\*/, 'RClass *')
      file_vars = NativeDirect.class_variables(typed, NativeDirect.sibling_param_owners(path))
      scopes = block_scopes(typed, file_vars)
      vars_at = ->(pos) { scopes.find { |from, to, _| pos.between?(from, to) }&.last || file_vars }
      # Calls are read from `typed`, the text the scopes were built on, so a position names the same block
      # in both (`struct RClass *` -> `RClass *` shortens the text; ADR 0468).
      typed.scan(CALL_RE) do
        match = Regexp.last_match
        family = match[1]
        args, close = call_args(typed, match.end(0) - 1)
        next if args.nil? || definition?(typed, match.begin(0), close)

        if family == 'prepend_module'
          result.refusals[path.include?('/3rd/mruby/') ? :core_prepend : :native_prepend] += 1
          next
        end
        spec = FAMILIES[family]
        unless spec
          result.refusals[:native_unparsed_form] += 1 if family.match?(DEFINER_LIKE)
          next
        end
        result.calls += 1
        owner = owner_of(args.fetch(spec[:owner], ''), vars_at.call(match.begin(0)))
        instance = args.fetch(spec[:owner], '').strip == 'mrb->top_self'
        owners = if instance
                   [owner]
                 elsif spec[:suffix] == :both
                   [owner, owner == UNKNOWN ? UNKNOWN : "#{owner}.singleton"]
                 elsif spec[:suffix] && owner != UNKNOWN
                   ["#{owner}#{spec[:suffix]}"]
                 else
                   [owner]
                 end
        name = name_of(args.fetch(spec[:name], ''))
        if spec[:alias_of] && name && !owners.include?(UNKNOWN)
          original = name_of(args.fetch(spec[:alias_of], ''))
          owners.each { |registered| result.aliases << [registered, name, original] } if original
        end
        if spec[:fn] && name && !owners.include?(UNKNOWN)
          # `&f` is the address of the function `f`: the same body as `f` (mrb_define_method(..., &match_data_to_s, ...)).
          fn = args.fetch(spec[:fn], '').strip.delete_prefix('&').strip
          owners.each { |registered| result.registrations << [registered, name, fn.match?(/\A\w+\z/) ? fn : nil] }
        end
        if name.nil?
          result.computed.merge(owners)
          if owners.include?(UNKNOWN)
            if path.include?('/3rd/mruby/') then result.core_dynamic_unknown += 1
            else result.computed_unknown = true
            end
          end
        else
          result.by_name[name].merge(owners)
        end
      end
      scan_rom_tables(typed, vars_at, result)
    end
    result
  end

  # ROM method tables (MRB_MT_ENTRY in a `mrb_mt_entry NAME[] = { ... }` block) take the owner of the
  # MRB_MT_INIT_ROM / mrb_mt_init_rom call that installs NAME in the same file. Any entry outside such
  # a block, or whose table has no installer in this file, is UNKNOWN.
  # The class a MRB_MT_INIT_ROM installs its table on: NativeRomOwners reads the variable's binding in the same function
  # (define_class, a core field, a naming call), which covers the chained `mrb->x_class = x = mrb_define_class...` form.
  def rom_installer_owner(text, pos, arg)
    NativeRomOwners.owner_of(text, pos, arg.strip)
  end

  def scan_rom_tables(text, vars_at, result)
    installers = Hash.new { |h, k| h[k] = Set.new }
    text.scan(/\b(?:MRB_MT_INIT_ROM|mrb_mt_init_rom)\s*\(/) do
      match = Regexp.last_match
      args, = call_args(text, match.end(0) - 1)
      installers[args[2]] << rom_installer_owner(text, match.begin(0), args[1].to_s) if args && args.size >= 3
    end
    attributed = []
    text.scan(ROM_TABLE_RE) do
      match = Regexp.last_match
      body = brace_body(text, match.end(0) - 1)
      next unless body

      owners = installers.fetch(match[1], Set[UNKNOWN])
      body.scan(ROM_ENTRY_RE) do |macro, tok|
        name = resolve_mrb_sym_token(macro, tok)
        result.by_name[name].merge(owners)
      end
      attributed << [match.begin(0), match.end(0) + body.size]
    end
    text.scan(ROM_ENTRY_RE) do |macro, tok|
      pos = Regexp.last_match.begin(0)
      next if attributed.any? { |from, to| pos >= from && pos < to }

      result.by_name[resolve_mrb_sym_token(macro, tok)] << UNKNOWN
    end
  end

  # Is `name` provably free of native definitions on any class in `arm_owners`? `arm_owners` is the
  # set of classes a chain arm calls a Ruby body for: its candidate owners and their inherited
  # subclasses. Returns [:proven] or [:refused, reason].
  def verdict(map, name, arm_owners, core_dynamic_trusted: false)
    return [:refused, :native_owner_unknown] if map.computed_unknown
    return [:refused, :native_owner_unknown_core] if map.core_dynamic_unknown.positive? && !core_dynamic_trusted
    return [:refused, :native_prepend] if map.refusals[:native_prepend].positive?
    return [:refused, :native_prepend_core] if map.refusals[:core_prepend].positive? && !core_dynamic_trusted

    owners = map.by_name.fetch(name, Set.new)
    return [:refused, :native_owner_unknown] if owners.include?(UNKNOWN)

    overlap = (owners | map.computed) & arm_owners.to_set
    return [:refused, :native_owner_overlap] unless overlap.empty?

    [:proven]
  end
end

# Loaded last: NativeRomOwners reads NativeOwnerMap's constants when it loads.
require_relative 'native_rom_owners'
