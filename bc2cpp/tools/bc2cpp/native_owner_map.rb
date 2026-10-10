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

  # Registration families. `name` and `owner` are argument indexes (the first is the mrb state);
  # `suffix` is how the owner is recorded: nil for the instance table, '.singleton' for the
  # class-object table, :both for a module_function (instance and class table).
  FAMILIES = {
    'define_method' => { name: 2, owner: 1, suffix: nil },
    'define_method_id' => { name: 2, owner: 1, suffix: nil },
    'define_method_raw' => { name: 2, owner: 1, suffix: nil },
    'define_private_method' => { name: 2, owner: 1, suffix: nil },
    'define_private_method_id' => { name: 2, owner: 1, suffix: nil },
    'define_class_method' => { name: 2, owner: 1, suffix: '.singleton' },
    'define_class_method_id' => { name: 2, owner: 1, suffix: '.singleton' },
    'define_singleton_method' => { name: 2, owner: 1, suffix: '.singleton' },
    'define_singleton_method_id' => { name: 2, owner: 1, suffix: '.singleton' },
    'define_module_function' => { name: 2, owner: 1, suffix: :both },
    'define_module_function_id' => { name: 2, owner: 1, suffix: :both },
    'define_alias' => { name: 2, owner: 1, suffix: nil },
    'define_alias_id' => { name: 2, owner: 1, suffix: nil },
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
  Result = Struct.new(:by_name, :computed, :computed_unknown, :core_dynamic_unknown, :refusals, :calls,
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
    return CORE_FIELD_OWNERS.fetch(Regexp.last_match(1), UNKNOWN) if arg.match(/\Amrb->(\w+)\z/)
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
  def block_scopes(text, vars)
    blank = text.gsub(/"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'/) { |tok| ' ' * tok.size }
    scopes = []
    depth = 0
    start = nil
    prev = 0
    blank.each_char.with_index do |c, i|
      if c == '{'
        start = i if depth.zero?
        depth += 1
      elsif c == '}' && depth.positive?
        depth -= 1
        next unless depth.zero?

        signature = text[prev...start]
        scopes << [start, i, vars.merge(block_owners(text[start..i], signature, vars))]
        prev = i + 1
      end
    end
    scopes
  end

  # The owners of the `RClass *` variables a function body declares and assigns, plus its `RClass *`
  # parameters (which keep the file's owner for them). A declared variable whose assignments disagree,
  # or one of whose right-hand sides is not a known class, is UNKNOWN. `a = B = C` gives `a` B's value.
  def block_owners(body, signature, vars)
    params = signature.scan(/RClass\s*\*\s*(\w+)\s*[,)]/).flatten
    declared = body.scan(/RClass\s*\*\s*(\w+)/).flatten.to_set
    rhs = Hash.new { |h, k| h[k] = [] }
    body.scan(/(?<![\w>.])(\w+)\s*=(?!=)([^;]*);/) do
      scan = Regexp.last_match
      next unless declared.include?(scan[1])

      first = scan[2].split(/(?<![=!<>])=(?!=)/).first.to_s.strip
      rhs[scan[1]] << owner_of(first, vars)
    end
    out = {}
    params.each { |var| out[var] = vars[var] || UNKNOWN }
    declared.each do |var|
      owners = rhs[var]
      out[var] = owners.empty? || owners.uniq.size != 1 ? UNKNOWN : owners.first
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
    result = Result.new(by_name: Hash.new { |h, k| h[k] = Set.new }, computed: Set.new,
                        computed_unknown: false, core_dynamic_unknown: 0, refusals: Hash.new(0), calls: 0)
    Array(paths).each do |path|
      text = NativeDirect.strip_comments(File.binread(path).force_encoding('UTF-8'))
      # `struct RClass *x` is the same variable as `RClass *x` for the owner table.
      typed = text.gsub(/struct\s+RClass\s*\*/, 'RClass *')
      file_vars = NativeDirect.class_variables(typed, NativeDirect.sibling_param_owners(path))
      scopes = block_scopes(typed, file_vars)
      vars_at = ->(pos) { scopes.find { |from, to, _| pos.between?(from, to) }&.last || file_vars }
      text.scan(CALL_RE) do
        match = Regexp.last_match
        family = match[1]
        args, close = call_args(text, match.end(0) - 1)
        next if args.nil? || definition?(text, match.begin(0), close)

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
        owners = if spec[:suffix] == :both
                   [owner, owner == UNKNOWN ? UNKNOWN : "#{owner}.singleton"]
                 elsif spec[:suffix] && owner != UNKNOWN
                   ["#{owner}#{spec[:suffix]}"]
                 else
                   [owner]
                 end
        name = name_of(args.fetch(spec[:name], ''))
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
      scan_rom_tables(text, vars_at, result)
    end
    result
  end

  # ROM method tables (MRB_MT_ENTRY in a `mrb_mt_entry NAME[] = { ... }` block) take the owner of the
  # MRB_MT_INIT_ROM / mrb_mt_init_rom call that installs NAME in the same file. Any entry outside such
  # a block, or whose table has no installer in this file, is UNKNOWN.
  def scan_rom_tables(text, vars_at, result)
    installers = Hash.new { |h, k| h[k] = Set.new }
    text.scan(/\b(?:MRB_MT_INIT_ROM|mrb_mt_init_rom)\s*\(/) do
      match = Regexp.last_match
      args, = call_args(text, match.end(0) - 1)
      installers[args[2]] << owner_of(args[1].to_s, vars_at.call(match.begin(0))) if args && args.size >= 3
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
