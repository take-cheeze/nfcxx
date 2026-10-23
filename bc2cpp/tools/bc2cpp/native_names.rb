# frozen_string_literal: true

require 'prism'
require_relative 'source_text'
require_relative 'scan_cache'
require_relative 'ruby_parse_cache'

# Step 5b: method names defined or called outside the compiled bytecode.

# ---------------------------------------------------------------------------
# Step 5b: native method names. mrb_define_method-family call sites in C
# sources are invisible to mrbc, so a name defined once in bytecode would look
# MONO even when a C class defines the same name (Game::Shop#name vs
# Class#name/Symbol#name). Only the flat set of names is extracted: that is
# all MONO/POLY soundness needs, and calling a native function directly would
# skip the ci frame mrb_funcall sets up for mrb_get_args.
# ---------------------------------------------------------------------------
# MRB_OPSYM(cmp) is how C source spells `<=>`. Inverted from mruby's own presym
# table so the spellings track the vendored mruby; a missing submodule fails
# here rather than falling back to a copied table (ruby-checks checks it out).
PRESYM_RB = File.expand_path('../../3rd/mruby/lib/mruby/presym.rb', __dir__)
raise "bc2cpp: #{PRESYM_RB} is missing; run `git submodule update --init 3rd/mruby`" unless File.file?(PRESYM_RB)

require PRESYM_RB
OPSYM_TO_RUBY = MRuby::Presym::OPERATORS.to_h { |ruby, sym| [sym, ruby] }.freeze
# A duplicate symbol value would make the inversion silently drop an operator.
raise 'bc2cpp: mruby presym OPERATORS values are not unique' unless OPSYM_TO_RUBY.size == MRuby::Presym::OPERATORS.size

# mruby core registers most methods through ROM tables rather than literal
# string names (src/symbol.c):
#   static const mrb_mt_entry symbol_rom_entries[] = {
#     MRB_MT_ENTRY(sym_name, MRB_SYM(name), MRB_ARGS_NONE()),
#     MRB_MT_ENTRY(sym_cmp,  MRB_OPSYM(cmp), MRB_ARGS_REQ(1)),   // <=>
#   };
#   MRB_MT_INIT_ROM(mrb, sym, symbol_rom_entries);
# and some gems call mrb_define_method_id(mrb, klass, MRB_SYM(name), ...).
# Both use this token. One MRB_SYM/SYM_Q/SYM_B/SYM_E/OPSYM token, shared by
# extract_native_method_names and extract_native_call_names so the resolution
# logic lives in one place.
MRB_SYM_TOKEN_RE = /MRB_(SYM_Q|SYM_B|SYM_E|SYM|OPSYM)\((\w+)\)/

def resolve_mrb_sym_token(macro, name)
  case macro
  when 'SYM_Q' then "#{name}?"
  when 'SYM_B' then "#{name}!"
  when 'SYM_E' then "#{name}="
  when 'OPSYM' then OPSYM_TO_RUBY[name] || name
  else name # bare MRB_SYM(name)
  end
end

# ---------------------------------------------------------------------------
# FIXNUM_RETURN_PROOF's out-of-closed-world poison source, the method twin of
# IntegerConstants.foreign_const_names. A method defined in 3rd/mruby/mrblib
# (same VM, invisible to build_registry) can make a name look MONO. A wrong
# return-type proof emits an unchecked mrb_fixnum() (undefined behavior, not a
# wrong answer), so FIXNUM_RETURN_PROOF refuses any name defined here at all
# (e.g. enumerator.rb's `size`, enum.rb's `max`/`min`, mruby-complex's `abs`).
#
# Textual and over-broad on purpose. Fully dynamic definitions (`alias_method
# :"string_#{v}", v`) cannot be enumerated, which is why this is only a poison
# source, never positive evidence.
# ---------------------------------------------------------------------------
# One method-name token, same charset as the SEND-name extraction (so `def
# <=>` / `def []=` are seen).
FOREIGN_METHOD_NAME_RE = %r{[\w+\-*/<>=!?\[\]&|^~%@]+}

# Every name the syntax tree defines, in any position (`private def x`, after `;`,
# `def self.x`, `alias`, `attr_*`, `alias_method :x`, `define_method(:x)`): a line-start
# regex misses all the modifier and one-line forms.
class ForeignDefNames < Prism::Visitor
  INSTALLERS = %w[alias_method define_method attr attr_reader attr_writer attr_accessor].freeze

  attr_reader :names

  def initialize
    super
    @names = Set.new
  end

  def visit_def_node(node)
    @names << node.name.to_s
    super
  end

  def visit_alias_method_node(node)
    literal(node.new_name)
    super
  end

  def visit_call_node(node)
    if INSTALLERS.include?(node.name.to_s)
      accessor = node.name.to_s.start_with?('attr')
      (node.arguments&.arguments || []).each { |arg| literal(arg, accessor) }
    end
    super
  end

  private

  def literal(node, accessor = false)
    return unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

    @names << node.unescaped
    @names << "#{node.unescaped}=" if accessor
  end
end

def foreign_method_names(paths)
  ScanCache.fetch('native_names.foreign_method_names', Array(paths), cache_absent: false) do
    names = Set.new
    Array(paths).each do |path|
      src = SourceText.read(path, 'foreign_method_names') or next
    parsed = RubyParseCache.parse(src, path)
    # The tree still recovers around an error and the regexes below cover the rest, but a
    # file that does not parse must not go unnoticed.
    warn "[bc2cpp] foreign_method_names: #{path} does not parse: #{parsed.errors.first.message}" unless parsed.errors.empty?
    collector = ForeignDefNames.new
    parsed.value.accept(collector)
    names.merge(collector.names)
    # `def name`, `def self.name`, `def obj.name`.
    src.scan(/^\s*def\s+(?:[A-Za-z_][A-Za-z_0-9]*\.)?(#{FOREIGN_METHOD_NAME_RE})/o) do
      names << Regexp.last_match(1)
    end
    # All three accessor spellings are collected for all three macros:
    # over-collection on purpose.
    src.scan(/^\s*attr_(?:reader|writer|accessor)\s+(.+)$/) do
      Regexp.last_match(1).scan(/:(\w+)/) do
        n = Regexp.last_match(1)
        names << n
        names << "#{n}="
      end
    end
    # A second body installed under a name with no `def` of its own.
    src.scan(/^\s*alias\s+:?(#{FOREIGN_METHOD_NAME_RE})/o) { names << Regexp.last_match(1) }
    src.scan(/alias_method\s*\(?\s*:"?(#{FOREIGN_METHOD_NAME_RE})/o) { names << Regexp.last_match(1) }
    src.scan(/define_method\s*\(?\s*:"?(#{FOREIGN_METHOD_NAME_RE})/o) { names << Regexp.last_match(1) }
  end
  names
  end
end

# ---------------------------------------------------------------------------
# ESCAPE_ANALYSIS's owner-aware view of the foreign Ruby definitions above. A
# name defined only by plain `def`s in lexical class bodies (or at top level)
# is relevant to a receiver only when one of those classes is in its ancestry,
# so `initialize` no longer hides from every class. Everything the scan cannot
# attribute keeps the name-level refusal of foreign_method_names:
#   - a def whose owner is a module (a hidden `include` can put it anywhere), a
#     singleton class, a block or another def's body; a `def self.x`;
#   - an alias, an attr or a literal define_method (name-level, as before).
# Refused for every name (`global`): a computed-name definer outside a plain
# class body or top level (a block, a module, a singleton class, an explicit
# receiver), a string or block-less eval, a send of a definer name, a mixin
# whose argument is not a constant (outside a forwarding `def include`), and a
# file the parser refuses. A computed-name definer in a plain class body is a
# wild owner: it may define any name on that class. `include`/`prepend`/`extend`
# in hidden Ruby record the module's simple name; see World#mixin_defines?.
# ---------------------------------------------------------------------------
HiddenRubyOwners = Struct.new(:names, :owners, :wild, :mixins, :global)

class HiddenRubyOwnerScan < Prism::Visitor
  DEFINER_CALLS = %w[define_method define_singleton_method alias_method attr attr_reader attr_writer attr_accessor].freeze
  EVAL_CALLS = %w[class_eval module_eval instance_eval class_exec module_exec instance_exec eval].freeze
  MIXIN_CALLS = %w[include prepend extend].freeze
  SEND_CALLS = %w[send __send__ public_send].freeze
  DEFINING_CALLS = (DEFINER_CALLS + EVAL_CALLS + MIXIN_CALLS + %w[alias undef]).freeze

  attr_reader :owners, :unowned, :wild, :mixins, :global

  def initialize
    super
    # Innermost last: [:class, full_name], [:module, full_name] or [:unknown]. Empty at top level.
    @stack = []
    @owners = Hash.new { |hash, key| hash[key] = Set.new }
    @unowned = Set.new
    @wild = Set.new
    @mixins = Set.new
    @global = false
    @forwarding = 0
  end

  def visit_class_node(node)
    enter_body(node, :class) { visit_child_nodes(node) }
  end

  def visit_module_node(node)
    enter_body(node, :module) { visit_child_nodes(node) }
  end

  def visit_singleton_class_node(node)
    push([:unknown]) { visit_child_nodes(node) }
  end

  def visit_block_node(node)
    push([:unknown]) { visit_child_nodes(node) }
  end

  def visit_lambda_node(node)
    push([:unknown]) { visit_child_nodes(node) }
  end

  def visit_def_node(node)
    name = node.name.to_s
    if node.receiver
      @unowned << name
    else
      record_def(name)
    end
    # A def inside a def body defines on whatever class runs it.
    forwarding = node.receiver.nil? && MIXIN_CALLS.include?(name)
    @forwarding += 1 if forwarding
    push([:unknown]) { visit_child_nodes(node) }
  ensure
    @forwarding -= 1 if forwarding
  end

  def visit_alias_method_node(node)
    name = literal_name(node.new_name)
    name ? @unowned << name : @global = true
    visit_child_nodes(node)
  end

  def visit_call_node(node)
    name = node.name.to_s
    args = node.arguments&.arguments || []
    if DEFINER_CALLS.include?(name)
      definer_call(name, node, args)
    elsif EVAL_CALLS.include?(name)
      # A string or non-block body is opaque; a block's own defs are scoped by visit_block_node.
      @global = true unless node.block.is_a?(Prism::BlockNode)
    elsif MIXIN_CALLS.include?(name)
      mixin_call(args)
    elsif SEND_CALLS.include?(name) && args.first && DEFINING_CALLS.include?(literal_name(args.first))
      @global = true
    end
    visit_child_nodes(node)
  end

  private

  def literal_name(node)
    case node
    when Prism::SymbolNode, Prism::StringNode then node.unescaped
    end
  end

  def enter_body(node, kind, &block)
    path = node.constant_path
    parent = @stack.last
    scope = if path.is_a?(Prism::ConstantReadNode) && (parent.nil? || parent[0] != :unknown)
              prefix = parent ? "#{parent[1]}::" : ''
              [kind, "#{prefix}#{path.name}"]
            else
              [:unknown]
            end
    push(scope, &block)
  end

  def push(scope)
    @stack.push(scope)
    yield
  ensure
    @stack.pop
  end

  def record_def(name)
    scope = @stack.last
    case scope&.first
    when nil then @owners[name] << 'Object' # a top-level def is a private method on Object
    when :class then @owners[name] << scope[1]
    else @unowned << name
    end
  end

  # define_method(name), alias_method(new, old), attr_*(names). Literal names are name-level.
  def definer_call(name, node, args)
    name_args = case name
                when 'define_method', 'define_singleton_method' then args.first(1)
                when 'alias_method' then args.first(2)
                else args
                end
    accessor = %w[attr_writer attr_accessor].include?(name)
    name_args.each do |arg|
      literal = literal_name(arg)
      if literal
        @unowned << literal
        @unowned << "#{literal}=" if accessor
      else
        computed_definer(name, node, arg)
      end
    end
  end

  # A computed name could be any name, so it is wild on the plain class body that makes it, and global anywhere
  # else: a block, a module, a singleton class, an explicit receiver (the owner is not attributable there).
  def computed_definer(name, node, arg)
    prefix = computed_prefix(arg)
    @unowned << prefix if prefix
    scope = @stack.last
    if node.receiver.nil? && name != 'define_singleton_method' && scope.nil?
      @wild << 'Object'
    elsif node.receiver.nil? && name != 'define_singleton_method' && scope&.first == :class
      @wild << scope[1]
    else
      @global = true
    end
  end

  def computed_prefix(node)
    return nil unless node.respond_to?(:parts)

    first = node.parts.first
    prefix = first.unescaped if first.is_a?(Prism::StringNode)
    prefix unless prefix.nil? || prefix.empty?
  end

  # `def include(*modules); Object.include(*modules); end` (mruby's toplevel-ext) forwards its callers' values.
  # Every call of include is scanned in turn (a constant is a mixin, anything else is global), so a parameter
  # forwarded here is no new source.
  def mixin_call(args)
    args.each do |arg|
      next if arg.is_a?(Prism::SelfNode) # `extend self` in a module: its defs are already name-level

      if arg.is_a?(Prism::ConstantReadNode) || arg.is_a?(Prism::ConstantPathNode)
        @mixins << arg.slice.split('::').last
      elsif @forwarding.positive? && forwarded_parameter?(arg)
        next
      else
        @global = true
      end
    end
  end

  def forwarded_parameter?(arg)
    expression = arg.is_a?(Prism::SplatNode) ? arg.expression : arg
    expression.is_a?(Prism::LocalVariableReadNode)
  end
end

# The owner-aware scan of the foreign Ruby defs. A file the parser refuses makes everything global.
def foreign_method_owners(paths)
  names = foreign_method_names(paths)
  scan = HiddenRubyOwnerScan.new
  global = false
  Array(paths).each do |path|
    src = SourceText.read(path, 'foreign_method_owners') or next
    parsed = RubyParseCache.parse(src, path)
    if parsed.errors.empty?
      parsed.value.accept(scan)
    else
      global = true
    end
  end
  owners = {}
  scan.owners.each { |name, set| owners[name] = set unless scan.unowned.include?(name) }
  HiddenRubyOwners.new(names, owners, scan.wild, scan.mixins, global || scan.global)
end

# ---------------------------------------------------------------------------
# ENTRY_ARG_CALLSITE_PROOF's out-of-closed-world poison source: can anything
# outside the closed world CALL this name? A `mrb_funcall(M, obj,
# "tile_color", ...)` in C++ or a call in 3rd/mruby/mrblib is a site whose
# argument cannot be proven, and one unseen site makes the proof wrong.
#
# Deliberately blunt: a name is poisoned if it appears as any identifier token
# in those files at all (call, definition, comment, ...). Over-collecting costs
# a proof; under-collecting emits an unchecked mrb_fixnum(). It needs no model
# of C++ or of mruby's dispatch surface. Operator names are refused by the
# mechanism itself (its `\A[A-Za-z_]` gate).
#
# Read as bytes: some mruby C sources are not valid UTF-8, and String#scan on
# an invalid string raises. The pattern is ASCII, so the matches are the same.
# ---------------------------------------------------------------------------
OUTSIDE_TOKEN_RE = /[A-Za-z_][A-Za-z_0-9]*[?!=]?/.freeze

# A missing file is reported by SourceText, so a scan with one is not memoized.
def outside_world_tokens(paths)
  ScanCache.fetch('outside_world_tokens', Array(paths), cache_absent: false) do
    names = Set.new
    Array(paths).each do |path|
      src = SourceText.read(path, 'outside_world_tokens', binary: true) or next
      src.scan(OUTSIDE_TOKEN_RE) { |t| names << t }
    end
    names
  end
end

# ---------------------------------------------------------------------------
# NUMERIC_OPERAND_PROOF out-of-closed-world poison sources.
#
# nil_class_operator_names: every operator a native source that touches
# `nil_class` mentions (spelled MRB_OPSYM(x) or as a quoted operator). A file
# that never names nil_class cannot define a NilClass method; one that does is
# read blunt-ly, so over-collection costs a proof, never soundness.
#
# outside_ivar_names: every `@name` a native or foreign-Ruby source spells, plus
# MRB_IVSYM(name). Those sources can write an ivar the closed-world bytecode
# scan never sees, so the ivar is not provable.
# ---------------------------------------------------------------------------
def nil_class_operator_names(paths)
  ScanCache.fetch('native_names.nil_class_operator_names', Array(paths), cache_absent: false) do
    names = Set.new
    Array(paths).each do |path|
      src = SourceText.read(path, 'nil_class_operator_names', binary: true) or next
      next unless src.include?('nil_class')

      src.scan(/MRB_OPSYM\((\w+)\)/) { |(n)| names << (OPSYM_TO_RUBY[n] || n) }
      src.scan(/"([+\-*\/%<>=!&|^~\[\]]+@?)"/) { |(n)| names << n }
    end
    names
  end
end

def outside_ivar_names(paths)
  ScanCache.fetch('native_names.outside_ivar_names', Array(paths), cache_absent: false) do
    names = Set.new
    Array(paths).each do |path|
      src = SourceText.read(path, 'outside_ivar_names', binary: true) or next
      src.scan(/@([A-Za-z_][A-Za-z_0-9]*)/) { |(n)| names << n }
      src.scan(/MRB_IVSYM\(\s*([A-Za-z_][A-Za-z_0-9]*)\s*\)/) { |(n)| names << n }
    end
    names
  end
end

# Owner argument: a local or an mrb_state class field (`mrb->array_class`), resolved as in NativeOwnerMap
# (CORE_FIELD_OWNERS). Bare-identifier-only matching left mruby-pack's `pack` unregistered. The private and
# singleton families take the same argument: Kernel's private `exit` and top_self's singleton `to_s` were unseen.
NATIVE_OWNER_ARG_RE = /(?:mrb->)?\w+/

def extract_native_method_names(src_paths)
  ScanCache.fetch('native_names.extract_native_method_names', Array(src_paths), cache_absent: false) do
    names = Set.new
    # MRB_SYM(name) is the bare name, MRB_OPSYM(op) an operator (OPSYM_TO_RUBY).
  # presym.h also defines MRB_SYM_Q -> "name?", MRB_SYM_B -> "name!" and
  # MRB_SYM_E -> "name=", which core uses constantly (Array#empty?, Kernel#nil?,
  # ...). Missing them made names like :empty? look MONO (Game::MoveRoute#empty?
  # devirtualized `@commands.empty?` into itself). The longer SYM_Q/SYM_B/SYM_E
  # alternatives must come before bare SYM in the regex, or SYM matches first
  # and "_Q(empty)" is left unconsumed.
  Array(src_paths).each do |path|
    src = SourceText.read(path, 'extract_native_method_names') or next
    # Multi-line call shapes match too; the regex ignores newlines between args.
    src.scan(/mrb_define_(?:method|class_method|module_function|private_method|singleton_method)\s*\(\s*\w+\s*,\s*#{NATIVE_OWNER_ARG_RE}\s*,\s*"((?:[^"\\]|\\.)*)"/m) do |name|
      names << unescape_c_string(name.first)
    end

    # MRB_MT_ENTRY(fn, MRB_SYM(name), flags) / MRB_MT_ENTRY(fn, MRB_OPSYM(op), flags)
    # -- mruby core's own ROM method-table idiom.
    src.scan(/MRB_MT_ENTRY\s*\(\s*\w+\s*,\s*#{MRB_SYM_TOKEN_RE}/) { |tok| names << resolve_mrb_sym_token(tok[0], tok[1]) }

    # mrb_define_method_id(mrb, klass, MRB_SYM(name)/MRB_OPSYM(op), func, aspec)
    # (and the _class_method_id/_module_function_id siblings) -- the direct-call
    # form some core mrbgems (mruby-task, ...) use instead of a ROM table.
    src.scan(/mrb_define_(?:method|class_method|module_function|private_method|singleton_method)_id\s*\(\s*\w+\s*,\s*#{NATIVE_OWNER_ARG_RE}\s*,\s*#{MRB_SYM_TOKEN_RE}/) do |tok|
      names << resolve_mrb_sym_token(tok[0], tok[1])
    end

    # mrb_define_method_raw(mrb, klass, MRB_SYM/MRB_OPSYM, m) (src/class.c
    # bob_init) installs a prebuilt mrb_method_t, sometimes a hand-written RProc.
    # Without it `!=` would have no definition at all, and native_only_mono? (which
    # needs a `<native>` entry) could never fire for it. Only the literal-token
    # calls (Class#new, BasicObject#!=, Proc#call/[]) are matchable; the rest pass
    # runtime values.
    src.scan(/mrb_define_method_raw\s*\(\s*\w+\s*,\s*#{NATIVE_OWNER_ARG_RE}\s*,\s*#{MRB_SYM_TOKEN_RE}/) do |tok|
      names << resolve_mrb_sym_token(tok[0], tok[1])
    end
  end
  names
  end
end

# ZSUPER_NATIVE_SUPPORT: like extract_native_method_names, but keeps which
# source file contributed each name. The registry wants the flat set, but
# ZSUPER_NATIVE_TARGETS must know whether the `<native>` definition of a name is
# the one mruby-core function being reproduced or some other gem's. Each path
# is still read once; the driver derives the flat set from this map.
def extract_native_method_sources(src_paths)
  sources = Hash.new { |h, k| h[k] = [] }
  Array(src_paths).each do |path|
    extract_native_method_names([path]).each { |name| sources[name] << path }
  end
  sources
end

# Method names native C/C++ *calls* by literal name (mrb_funcall family, a
# string or MRB_SYM-family token). Feeds only the "never called" diagnostic,
# never codegen.
# Uses a bounded non-greedy lookahead instead of an argument split, because
# the receiver argument is often itself a call with commas. A false match only
# adds a name to the "reachable" set, which is safe here.
def extract_native_call_names(src_paths)
  ScanCache.fetch('native_names.extract_native_call_names', Array(src_paths), cache_absent: false) do
    names = Set.new
    Array(src_paths).each do |path|
      src = SourceText.read(path, 'extract_native_call_names') or next
    src.scan(/mrb_funcall(?:_id|_argv|_with_block)?\s*\(.{0,200}?(?:"((?:[^"\\]|\\.)*)"|#{MRB_SYM_TOKEN_RE})/m) do |str, macro, sym|
      names << (str ? unescape_c_string(str) : resolve_mrb_sym_token(macro, sym))
    end
  end
  names
  end
end
