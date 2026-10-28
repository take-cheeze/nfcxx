# frozen_string_literal: true

# LOAD_COMPILE: the closed build's class and module bodies, evaluated by generated C++ instead of mruby bytecode.
#
# A body runs once, while mrblib loads, and ClassBodyScan found that what runs is declarative: nested bodies,
# include/extend/attr_*, constants built from literals and other constants, and `def`s. This file splits each engine
# gem's mrblib into two parts that together do what the whole did:
#
#   residual   the mrblib the gem still loads as bytecode: every statement the compiler does not take, in the source
#              order and on the original lines, so a backtrace still names the right line. It runs first.
#   compiled   a generated function that the compiled gem's gem_init runs next, before it installs its compiled
#              methods. It opens each body, in source order, and runs the statements the residual left out.
#
# Moving a statement from before a residual statement to after it is sound when the residual one cannot observe it,
# so a residual statement that reads a constant makes that constant's statement residual too (promotion), and so does
# a class header that the residual needs (a superclass, an outer scope). What is left is not observable by a load:
# a `def` the compiled gem replaces never runs as bytecode (MrblibStubs.stubbable), and the other statements only
# define names that nothing residual reads.
#
# A body that cannot be compiled keeps its text and its bytecode, statement by statement: nothing here is
# all-or-nothing. A def stays when the stub proof keeps it (alias source, module_function copy, guard, loaded copy),
# or when a compiled statement names it (`private :x`, `alias_method`), because that statement runs before the
# compiled gem has installed anything.
require 'json'
require 'prism'
require 'set'
require_relative 'class_body_scan'

module LoadCompile
  module_function

  Item = Struct.new(:stmt, :role, :orig_role, :child, :def_key, :def_name, :dropped, :promoted, :ordered, keyword_init: true)
  UBody = Struct.new(:body, :items, :parent, :header_simple, :forced, :skeleton, :name, :id, keyword_init: true)
  Result = Struct.new(:code, :ranges, :last_file, :marker, :stats, :bodies, :dropped, keyword_init: true)

  MODES = ClassBodyScan::MODES
  BARE_MODE = { 'private' => :private, 'public' => :public, 'protected' => :protected, 'module_function' => :modfunc }.freeze
  # The sends a compiled load makes as written. `include` &c. are made by the VM with self as receiver, so the
  # same method runs; the arguments are constants and symbols.
  MARKER_PREFIX = '$__bc2cpp_residual_'

  # [UBody] for one file, in source order.
  def build_root(path, statements: true)
    root = ClassBodyScan.scan([path])
    ubody(root, nil, statements)
  end

  # `statements`: false leaves every statement but the defs to the residual (only the compiled gem's defs go), so
  # the compiled load has nothing to run.
  def ubody(body, parent, statements = true)
    ub = UBody.new(body: body, items: [], parent: parent, forced: false, skeleton: false, name: body.name)
    ub.header_simple = header_simple?(body)
    mode = :public
    body.statements.each do |stmt|
      role, mode = role_of(stmt, mode)
      # A header whose class cannot be named (`class foo::Bar`) cannot be reopened by the compiled load: it and
      # everything in it stays as written.
      role = :residual if role == :nested && !openable?(stmt.child)
      orig_role = role
      role = :residual if !statements && %i[send alias const ivar].include?(role)
      item = Item.new(stmt: stmt, role: role, orig_role: orig_role)
      item.child = ubody(stmt.child, ub, statements) if role == :nested
      annotate_def(item, ub)
      ub.items << item
    end
    ub
  end

  def openable?(body)
    node = body.node
    case node
    when Prism::ClassNode, Prism::ModuleNode then path_ok?(node.constant_path)
    else true
    end
  end

  # [role, next mode]. Roles: :nested :def :mode :send :alias :const :ivar :residual.
  def role_of(stmt, mode)
    node = stmt.node
    case stmt.category
    when :def then [:def, mode]
    when :const_literal, :const_pure then [:const, mode]
    when :class_ivar then [:ivar, mode]
    when :declarative
      return [:nested, mode] if stmt.child
      return [:alias, mode] if node.is_a?(Prism::AliasMethodNode)

      name = node.name.to_s
      args = node.arguments&.arguments || []
      return [:mode, BARE_MODE.fetch(name)] if args.empty? && BARE_MODE.key?(name)
      # A definition made under a mode other than public takes that mode from the frame the VM runs the body in;
      # a compiled load has no such frame, so it stays where the mode statement stays.
      return [:residual, mode] if ClassBodyScan::ATTRS.include?(name) && mode != :public

      [:send, mode]
    else [:residual, mode]
    end
  end

  def header_simple?(body)
    node = body.node
    case node
    when nil then true
    when Prism::ClassNode
      path_ok?(node.constant_path) && (node.superclass.nil? || ClassBodyScan.const_path?(node.superclass))
    when Prism::ModuleNode then path_ok?(node.constant_path)
    when Prism::SingletonClassNode then node.expression.is_a?(Prism::SelfNode)
    else false
    end
  end

  def path_ok?(path) = path.is_a?(Prism::ConstantReadNode) || (path.is_a?(Prism::ConstantPathNode) && (path.parent.nil? || ClassBodyScan.const_path?(path.parent)))

  # Owner#name of a def statement, spelled as the registry spells it (MrblibStubs::DefFinder).
  def annotate_def(item, ub)
    return unless item.role == :def

    node = item.stmt.node
    node = node.arguments.arguments.first if node.is_a?(Prism::CallNode)
    item.def_name = node.name.to_s
    owner = ub.body.path.empty? ? 'Object' : ub.body.path
    if node.receiver
      return unless node.receiver.is_a?(Prism::SelfNode)

      owner = "#{owner}.singleton"
    end
    # `module_function def x` copies the method: never dropped.
    wrapper = item.stmt.node.is_a?(Prism::CallNode) ? item.stmt.node.name.to_s : nil
    item.def_key = "#{owner}##{item.def_name}" unless wrapper == 'module_function'
  end

  def each_ubody(ub, &block)
    block.call(ub)
    ub.items.each { |item| each_ubody(item.child, &block) if item.child }
  end

  # ---- promotion ---------------------------------------------------------------------------------------------

  # The names a node reads as constants when it is evaluated, not those inside a def or lambda body (run later).
  def reads(node, into = Set.new)
    case node
    when Prism::ConstantReadNode then into << node.name.to_s
    when Prism::ConstantPathNode
      into << node.name.to_s
      reads(node.parent, into) if node.parent
    when Prism::DefNode, Prism::LambdaNode then nil
    else node.compact_child_nodes.each { |child| reads(child, into) } if node
    end
    into
  end

  def header_reads(ub)
    node = ub.body.node
    return Set.new unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

    # The outer scope and the superclass; the body's own name is what it defines.
    path = node.constant_path
    set = path.is_a?(Prism::ConstantPathNode) && path.parent ? reads(path.parent) : Set.new
    set.merge(reads(node.superclass)) if node.respond_to?(:superclass) && node.superclass
    set
  end

  def defined_name(item)
    case item.role
    when :nested
      node = item.stmt.node
      node.respond_to?(:constant_path) ? node.constant_path.slice.split('::').last : nil
    when :const then item.stmt.node.name.to_s
    end
  end

  # The method names a compiled send or alias defines or reads when it runs: `attr_writer :a` defines `a=`,
  # `alias_method :b, :a` defines b and reads a. Visibility sends only read.
  def taken_names(node)
    return [node.new_name.unescaped, node.old_name.unescaped] if node.is_a?(Prism::AliasMethodNode)

    given = (node.arguments&.arguments || []).filter_map { |a| a.unescaped if a.is_a?(Prism::SymbolNode) || a.is_a?(Prism::StringNode) }
    case node.name.to_s
    when 'attr', 'attr_reader' then given
    when 'attr_writer' then given.map { |n| "#{n}=" }
    when 'attr_accessor' then given.flat_map { |n| [n, "#{n}="] }
    else given
    end
  end

  # ORDER: the compiled load runs after every residual statement and the compiled gem installs the dropped defs after
  # the load, so a compiled send or alias keeps the source order only against the defs that come before it and that it
  # does not define over. A def of the same owner and name that comes later in the source (`alias_method :old, :sort!`
  # above a redefined `def sort!`: the alias must hold the method that existed then) keeps the statement residual, in
  # its place among the residual defs. A def that comes earlier, with a statement that defines the same name
  # (`def a; end` then `attr_reader :a`), is kept too (`order_pins`), or the compiled gem would install it over the
  # statement's. Sources are walked in the world's order: gems in order, files in order, statements in order.
  def order!(roots)
    seq = 0
    defs = Hash.new { |h, k| h[k] = [] }
    sends = []
    roots.each do |root|
      each_ubody(root) do |ub|
        owner = ub.body.path.empty? ? 'Object' : ub.body.path
        ub.items.each do |item|
          seq += 1
          defs[item.def_key] << seq if item.role == :def && item.def_key
          sends << [owner, item, seq] if %i[send alias].include?(item.role)
        end
      end
    end
    sends.each do |owner, item, at|
      keys = taken_names(item.stmt.node).map { |n| "#{owner}##{n}" }
      next unless keys.any? { |k| defs[k].any? { |d| d > at } }

      item.role = :residual
      item.ordered = true
    end
    @order_pins = Set.new
    sends.each do |owner, item, at|
      next if item.ordered || !%w[attr attr_reader attr_writer attr_accessor alias_method].include?(item.stmt.node.is_a?(Prism::AliasMethodNode) ? 'alias_method' : item.stmt.node.name.to_s)

      taken_names(item.stmt.node).each do |n|
        key = "#{owner}##{n}"
        @order_pins << key if defs[key].any? { |d| d < at }
      end
    end
  end

  def order_pins = @order_pins || Set.new

  # Fix the roles that must stay residual, over every root of the world (all gems), until nothing changes.
  def promote!(roots)
    order!(roots)
    needed = Set.new
    seed = lambda do |ub|
      # The header of a body whose text may stay (it has a def, a residual statement or a header the compiler cannot
      # run) runs in the residual phase.
      stays = !ub.header_simple || ub.forced || ub.items.any? { |i| %i[def residual].include?(i.role) }
      needed.merge(header_reads(ub)) if stays
    end
    all = []
    roots.each { |root| each_ubody(root) { |ub| all << ub } }
    all.each { |ub| seed.call(ub) }
    all.each { |ub| ub.items.each { |i| needed.merge(reads(i.stmt.node)) if i.role == :residual } }
    loop do
      changed = false
      all.each do |ub|
        ub.items.each do |item|
          name = defined_name(item)
          next unless name && needed.include?(name)

          case item.role
          when :const
            item.role = :residual
            item.promoted = true
            needed.merge(reads(item.stmt.node))
            changed = true
          when :nested
            next if item.child.forced

            item.child.forced = true
            needed.merge(header_reads(item.child))
            changed = true
          end
        end
      end
      break unless changed
    end
  end

  # ---- decisions with the stub proof ------------------------------------------------------------------------

  # The sends that act on a method that must already exist: a name they take cannot be a def the compiled gem
  # installs later. attr_*, include and the like define or extend; they need nothing in place.
  NEEDS_EXISTING = %w[private public protected module_function private_class_method public_class_method alias_method].freeze

  # Symbols a compiled statement names as methods, by name only: they must exist when it runs.
  def pinned_names(roots)
    names = Set.new
    roots.each do |root|
      each_ubody(root) do |ub|
        ub.items.each do |item|
          # By the statement's own form, not by who runs it: a residual `private :x` needs x as much as a compiled one.
          next unless %i[send alias].include?(item.orig_role)

          node = item.stmt.node
          if node.is_a?(Prism::AliasMethodNode)
            names << node.new_name.unescaped << node.old_name.unescaped
          elsif NEEDS_EXISTING.include?(node.name.to_s)
            (node.arguments&.arguments || []).each do |arg|
              names << arg.unescaped if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
            end
          end
        end
      end
    end
    names
  end

  def decide!(roots, drop_keys, pinned, stay: false)
    roots.each do |root|
      each_ubody(root) do |ub|
        ub.items.each do |item|
          next unless item.role == :def

          item.dropped = !item.def_key.nil? && drop_keys.include?(item.def_key) && !pinned.include?(item.def_name) &&
                         !order_pins.include?(item.def_key)
        end
      end
    end
    roots.each { |root| skeleton!(root, root: true, stay: stay) }
  end

  # A body keeps its header and `end` when anything of it stays: a def, a residual statement, a header the compiler
  # cannot run, a residual need of the class, or a nested body that stays.
  # `stay`: defs only, no compiled load to open a deleted body, so every body keeps its header.
  def skeleton!(ub, root: false, stay: false)
    nested = ub.items.select { |i| i.child }.map { |i| skeleton!(i.child, stay: stay) }
    return true if root

    ub.skeleton = stay || ub.forced || !ub.header_simple || nested.any? ||
                  ub.items.any? { |i| (i.role == :def && !i.dropped) || i.role == :residual }
  end

  # ---- residual text -----------------------------------------------------------------------------------------

  # Byte ranges of the statements the compiled load takes.
  def ranges_for(ub, out = [])
    ub.items.each do |item|
      loc = item.stmt.node.location
      range = [loc.start_offset, loc.end_offset]
      case item.role
      when :nested
        if item.child.skeleton then ranges_for(item.child, out) else out << range end
      when :def then out << range if item.dropped
      when :send, :alias, :const, :ivar then out << range
      end
    end
    out
  end

  # `text` with the byte `ranges` blanked, newlines kept, so every kept line number is unchanged.
  def blank(text, ranges)
    out = text.b
    ranges.sort.each do |s, e|
      out[s...e] = out.byteslice(s...e).gsub(/[^\n]/n, ' '.b)
    end
    out
  end

  def apply(text, ranges, marker: nil)
    out = blank(text, ranges)
    out << "\n#{marker} = true\n".b if marker
    out.force_encoding(text.encoding)
  end

  # ---- C++ ---------------------------------------------------------------------------------------------------

  def cstr(str)
    bytes = str.b.bytes.map do |b|
      case b
      when 0x22 then '\\"'
      when 0x5c then '\\\\'
      when 0x20..0x7e then b.chr
      else format('\\%03o', b)
      end
    end
    "\"#{bytes.join}\""
  end

  # A symbol of a name that outlives the VM (a literal in the binary): interned without a copy.
  def sym(name)
    name = name.to_s
    "mrb_intern_static(M, #{cstr(name)}, #{name.bytesize})"
  end

  # DATA_BLOB: a literal table (Array/Hash of numbers, strings, symbols, constants, ranges) is bytes in .rodata and
  # one decoder, not a call per element. The tags are the decoder's (PRELUDE).
  class Blob
    NIL = 0
    TRUE = 1
    FALSE = 2
    INT = 3
    FLOAT = 4
    SYM = 5
    STR = 6
    FSTR = 7
    ARRAY = 8
    HASH = 9
    RANGE = 10
    CONST = 11
    FREEZE = 12
    SPLAT = 13
    PATH = 14
    TOP = 15
    MIN_NODES = 4

    def initialize(strings)
      @strings = strings
    end

    def data?(node)
      case node
      # The decoder reads an Integer as a 32-bit zigzag varint.
      when Prism::IntegerNode then ClassBodyScan::Pure::INT_RANGE.cover?(node.value)
      when Prism::FloatNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SymbolNode,
           Prism::ConstantReadNode then true
      when Prism::StringNode then !ClassBodyScan::Pure.heredoc?(node)
      when Prism::ConstantPathNode then node.parent.nil? || data?(node.parent)
      when Prism::ParenthesesNode then node.body.is_a?(Prism::StatementsNode) && node.body.body.size == 1 && data?(node.body.body.first)
      when Prism::ArrayNode then node.elements.all? { |e| e.is_a?(Prism::SplatNode) ? e.expression && data?(e.expression) : data?(e) }
      when Prism::HashNode then node.elements.all? { |e| e.is_a?(Prism::AssocNode) && data?(e.key) && data?(e.value) }
      when Prism::RangeNode then (node.left.nil? || data?(node.left)) && (node.right.nil? || data?(node.right))
      when Prism::CallNode then node.name == :freeze && node.arguments.nil? && node.block.nil? && node.receiver && data?(node.receiver)
      else false
      end
    end

    # Worth a blob: a container (or a frozen one) of at least MIN_NODES nodes.
    def blob_root?(node)
      return false unless node.is_a?(Prism::ArrayNode) || node.is_a?(Prism::HashNode) || node.is_a?(Prism::CallNode) || node.is_a?(Prism::RangeNode)

      data?(node) && count(node) >= MIN_NODES
    end

    def count(node)
      1 + node.compact_child_nodes.sum { |c| count(c) }
    end

    # The bytes of `node`.
    def encode(node, out = [])
      case node
      when Prism::NilNode then out << NIL
      when Prism::TrueNode then out << TRUE
      when Prism::FalseNode then out << FALSE
      when Prism::IntegerNode then out << INT
                                   varint(zigzag(node.value), out)
      when Prism::FloatNode then out << FLOAT
                                 out.concat([node.value].pack('E').bytes)
      when Prism::SymbolNode then out << SYM
                                  varint(index(node.unescaped), out)
      when Prism::StringNode then out << (node.frozen? ? FSTR : STR)
                                  varint(index(node.unescaped), out)
      when Prism::ConstantReadNode then out << CONST
                                        varint(index(node.name.to_s), out)
      when Prism::ConstantPathNode
        if node.parent
          out << PATH
          encode(node.parent, out)
        else
          out << TOP
        end
        varint(index(node.name.to_s), out)
      when Prism::ParenthesesNode then encode(node.body.body.first, out)
      when Prism::ArrayNode
        out << ARRAY
        varint(node.elements.size, out)
        node.elements.each do |e|
          if e.is_a?(Prism::SplatNode)
            out << SPLAT
            encode(e.expression, out)
          else
            encode(e, out)
          end
        end
      when Prism::HashNode
        out << HASH
        varint(node.elements.size, out)
        node.elements.each { |e| encode(e.key, out) && encode(e.value, out) }
      when Prism::RangeNode
        out << RANGE << (node.exclude_end? ? 1 : 0)
        node.left ? encode(node.left, out) : out << NIL
        node.right ? encode(node.right, out) : out << NIL
      when Prism::CallNode
        out << FREEZE
        encode(node.receiver, out)
      else raise "LoadCompile: no blob encoding for #{node.class}"
      end
      out
    end

    def index(str)
      @strings[str.b] ||= @strings.size
    end

    def zigzag(n) = n >= 0 ? n << 1 : ((-n) << 1) - 1

    def varint(n, out)
      loop do
        byte = n & 0x7f
        n >>= 7
        out << (n.zero? ? byte : byte | 0x80)
        break if n.zero?
      end
    end
  end

  # The pure-expression emitter. Appends C++ statements to `lines` and returns the C++ name of the value.
  class Expr
    def initialize(lines, counter, scope, blob = nil)
      @lines = lines
      @counter = counter
      @scope = scope
      @blob = blob
    end

    # The C++ expression of a node that is one call or immediate (no statements), or nil.
    def simple(node)
      case node
      when Prism::IntegerNode
        node.value.abs < 2**30 ? "mrb_fixnum_value(#{node.value})" : "mrb_int_value(M, (mrb_int)(#{node.value}L))"
      when Prism::FloatNode then "mrb_float_value(M, #{format('%.17g', node.value)})"
      when Prism::NilNode then 'mrb_nil_value()'
      when Prism::TrueNode then 'mrb_true_value()'
      when Prism::FalseNode then 'mrb_false_value()'
      when Prism::SymbolNode then "mrb_symbol_value(#{LoadCompile.sym(node.unescaped)})"
      when Prism::StringNode
        "bc2cpp_ld_str(M, #{LoadCompile.cstr(node.unescaped)}, #{node.unescaped.bytesize}, #{node.frozen? ? 'true' : 'false'})"
      when Prism::ConstantReadNode then "bc2cpp_ld_const(M, &#{@scope}, #{LoadCompile.sym(node.name)})"
      end
    end

    def emit(node)
      if (expr = simple(node))
        return expr.start_with?('mrb_nil', 'mrb_true', 'mrb_false', 'mrb_fixnum', 'mrb_symbol_value') ? expr : temp(expr)
      end
      return blob(node) if @blob&.blob_root?(node)

      case node
      when Prism::ConstantPathNode
        base = node.parent ? emit(node.parent) : 'mrb_obj_value(M->object_class)'
        temp("mrb_const_get(M, #{base}, #{LoadCompile.sym(node.name)})")
      when Prism::ParenthesesNode then emit(node.body.body.first)
      when Prism::ArrayNode then array(node)
      when Prism::HashNode then hash(node)
      when Prism::RangeNode
        a = node.left ? emit(node.left) : 'mrb_nil_value()'
        b = node.right ? emit(node.right) : 'mrb_nil_value()'
        temp("mrb_range_new(M, #{a}, #{b}, #{node.exclude_end? ? 'TRUE' : 'FALSE'})")
      when Prism::CallNode then call(node)
      else raise "LoadCompile: no emitter for #{node.class}"
      end
    end

    def blob(node)
      bytes = @blob.encode(node)
      name = "t#{@counter[0] += 1}"
      @lines << "mrb_value #{name};"
      @lines << "{ static const unsigned char blob[] = {#{bytes.join(',')}}; const unsigned char* p = blob; #{name} = bc2cpp_ld_decode(M, &#{@scope}, &p); }"
      name
    end

    def temp(expr)
      name = "t#{@counter[0] += 1}"
      @lines << "mrb_value #{name} = #{expr};"
      name
    end

    def array(node)
      arr = temp("mrb_ary_new_capa(M, #{node.elements.size})")
      @lines << "{ const int ai = mrb_gc_arena_save(M);"
      node.elements.each do |el|
        if el.is_a?(Prism::SplatNode)
          @lines << "mrb_ary_concat(M, #{arr}, mrb_ary_splat(M, #{emit(el.expression)}));"
        else
          @lines << "mrb_ary_push(M, #{arr}, #{emit(el)});"
        end
        @lines << 'mrb_gc_arena_restore(M, ai);'
      end
      @lines << '}'
      arr
    end

    def hash(node)
      h = temp("mrb_hash_new_capa(M, #{node.elements.size})")
      @lines << "{ const int ai = mrb_gc_arena_save(M);"
      node.elements.each do |el|
        k = emit(el.key)
        v = emit(el.value)
        @lines << "mrb_hash_set(M, #{h}, #{k}, #{v});"
        @lines << 'mrb_gc_arena_restore(M, ai);'
      end
      @lines << '}'
      h
    end

    def call(node)
      recv = emit(node.receiver)
      args = (node.arguments&.arguments || []).map { |a| emit(a) }
      temp("mrb_funcall_argv(M, #{recv}, #{LoadCompile.sym(node.name)}, #{args.size}, #{argv(args)})")
    end

    # A named array: a compound literal is not C++.
    def argv(args)
      return 'nullptr' if args.empty?

      name = "av#{@counter[0] += 1}"
      @lines << "mrb_value #{name}[] = {#{args.join(', ')}};"
      name
    end
  end

  # C++ of one body: a function that runs its compiled statements with `c` as the class. Returns the function name.
  def emit_body(ub, ctx)
    fn = "bc2cpp_ld_#{ctx[:count] += 1}"
    lines = []
    counter = [0]
    lines << "static void #{fn}(mrb_state* M, const bc2cpp_ld_scope* up, struct RClass* c) {"
    lines << '  [[maybe_unused]] const bc2cpp_ld_scope here = {c, up};'
    lines << '  [[maybe_unused]] const int ai = mrb_gc_arena_save(M);'
    blob = Blob.new(ctx[:strings])
    # CONST_TABLE: a run of constants whose values are data is one table and one decoder call, not a call per
    # constant (the engine's opcode and id tables are some 900 of these: a call costs ten times what a name and a
    # tag cost). Only adjacent statements join, so the order of everything else is unchanged.
    run = []
    flush = lambda do
      next if run.empty?

      bytes = run.flat_map do |it|
        [].tap do |out|
          blob.varint(blob.index(it.stmt.node.name.to_s), out)
          blob.encode(it.stmt.node.value, out)
        end
      end
      first = run.first.stmt
      lines << "  { // #{File.basename(first.file)}:#{first.line} (#{run.size} constants)"
      lines << "    static const unsigned char tab[] = {#{bytes.join(',')}};"
      lines << "    bc2cpp_ld_consts(M, &here, c, tab, #{run.size});"
      lines << '  }'
      run.clear
    end
    ub.items.each do |item|
      stmt = item.stmt
      if item.role == :const && blob.data?(stmt.node.value)
        run << item
        next
      end
      # What emits nothing (a def, a mode, a residual statement) does not end the run.
      next if %i[def mode residual].include?(item.role)

      flush.call
      where = "#{File.basename(stmt.file)}:#{stmt.line}"
      body = []
      case item.role
      when :nested then emit_nested(item, ctx, body, counter)
      when :send then emit_send(item, body, counter, ctx)
      when :alias then emit_alias(item, body)
      when :const, :ivar
        before = body.size
        v = Expr.new(body, counter, 'here', Blob.new(ctx[:strings])).emit(stmt.node.value)
        allocated = body.size > before
        helper = item.role == :const ? 'bc2cpp_ld_const_set' : 'bc2cpp_ld_ivar_set'
        body << "#{helper}(M, c, #{cstr(stmt.node.name.to_s)}, #{v});"
        # An immediate allocates nothing, so there is nothing to give back.
        body << 'mrb_gc_arena_restore(M, ai);' if allocated
      else next
      end
      lines << "  { // #{where}"
      body.each { |l| lines << "    #{l}" }
      lines << '  }'
    end
    flush.call
    lines << '}'
    ctx[:fns] << lines.join("\n")
    fn
  end

  def emit_nested(item, ctx, body, counter)
    child = item.child
    node = item.stmt.node
    case node
    when Prism::SingletonClassNode
      body << 'struct RClass* c2 = mrb_class_ptr(mrb_singleton_class(M, mrb_obj_value(c)));'
    else
      path = node.constant_path
      ex = Expr.new(body, counter, 'here', Blob.new(ctx[:strings]))
      base = if path.is_a?(Prism::ConstantReadNode) then 'mrb_obj_value(c)'
             elsif path.parent then ex.emit(path.parent)
             else 'mrb_obj_value(M->object_class)'
             end
      name = sym(path.name)
      if node.is_a?(Prism::ClassNode)
        # A header the compiler cannot run (a call as superclass) ran in the residual phase: reopen without a check.
        sup = child.header_simple && node.superclass ? ex.emit(node.superclass) : 'mrb_nil_value()'
        body << "struct RClass* c2 = mrb_vm_define_class(M, #{base}, #{sup}, #{name});"
      else
        body << "struct RClass* c2 = mrb_vm_define_module(M, #{base}, #{name});"
      end
    end
    fn = emit_body(child, ctx)
    body << "#{fn}(M, &here, c2);"
    body << 'mrb_gc_arena_restore(M, ai);'
  end

  def emit_send(item, body, counter, ctx)
    node = item.stmt.node
    given = node.arguments&.arguments || []
    if !given.empty? && given.size <= 16 && given.all? { |a| a.is_a?(Prism::SymbolNode) }
      # attr_*, private :a, alias_method :a, :b ...: the names are data, one call runs them.
      names = given.map { |a| cstr(a.unescaped) }.join(', ')
      body << "static const char* const names[] = {#{names}};"
      body << "bc2cpp_ld_send_names(M, c, #{cstr(node.name.to_s)}, names, #{given.size});"
      body << 'mrb_gc_arena_restore(M, ai);'
      return
    end
    ex = Expr.new(body, counter, 'here', Blob.new(ctx[:strings]))
    args = (node.arguments&.arguments || []).map do |a|
      case a
      when Prism::SymbolNode then ex.temp("mrb_symbol_value(#{sym(a.unescaped)})")
      when Prism::StringNode then ex.temp("mrb_str_new(M, #{cstr(a.unescaped)}, #{a.unescaped.bytesize})")
      else ex.emit(a)
      end
    end
    body << "mrb_funcall_argv(M, mrb_obj_value(c), #{sym(node.name)}, #{args.size}, #{ex.argv(args)});"
    body << 'mrb_gc_arena_restore(M, ai);'
  end

  def emit_alias(item, body)
    node = item.stmt.node
    body << "mrb_value av[] = {mrb_symbol_value(#{sym(node.new_name.unescaped)}), mrb_symbol_value(#{sym(node.old_name.unescaped)})};"
    body << "mrb_funcall_argv(M, mrb_obj_value(c), #{sym('alias_method')}, 2, av);"
    body << 'mrb_gc_arena_restore(M, ai);'
  end

  PRELUDE = <<~'CPP'
    // LOAD_COMPILE (tools/bc2cpp/load_compile.rb): the statements of this gem's class bodies that its residual mrblib
    // leaves out, run in source order.
    #include <mruby.h>
    #include <mruby/array.h>
    #include <mruby/class.h>
    #include <mruby/hash.h>
    #include <mruby/range.h>
    #include <mruby/string.h>
    #include <mruby/variable.h>
    extern "C" struct RClass* mrb_vm_define_class(mrb_state*, mrb_value, mrb_value, mrb_sym);
    extern "C" struct RClass* mrb_vm_define_module(mrb_state*, mrb_value, mrb_sym);
    struct bc2cpp_ld_scope {
      struct RClass* klass;
      const bc2cpp_ld_scope* up;
    };
    // The order of mrb_vm_const_get (3rd/mruby/src/variable.c): the own table of each lexical scope, innermost first,
    // then the ancestors of the innermost scope; a miss runs const_missing on it, as the VM does.
    static inline bool bc2cpp_ld_own(mrb_state* M, mrb_value scope, mrb_sym name, mrb_value* out) {
      if (!(mrb_class_p(scope) || mrb_module_p(scope) || mrb_sclass_p(scope)) || !mrb_iv_defined(M, scope, name)) return false;
      *out = mrb_iv_get(M, scope, name);
      return true;
    }
    static void bc2cpp_ld_const_set(mrb_state* M, struct RClass* c, const char* name, mrb_value v) {
      mrb_const_set(M, mrb_obj_value(c), mrb_intern_static(M, name, strlen(name)), v);
    }
    static void bc2cpp_ld_ivar_set(mrb_state* M, struct RClass* c, const char* name, mrb_value v) {
      mrb_iv_set(M, mrb_obj_value(c), mrb_intern_static(M, name, strlen(name)), v);
    }
    static mrb_value bc2cpp_ld_str(mrb_state* M, const char* s, size_t n, bool frozen) {
      mrb_value v = mrb_str_new(M, s, n);
      if (frozen) mrb_obj_freeze(M, v);
      return v;
    }
    // `obj.<verb>(:a, :b, ...)` with Symbol arguments, as an SSEND with self as the receiver: attr_*, private :a, ...
    static void bc2cpp_ld_send_names(mrb_state* M, struct RClass* c, const char* verb, const char* const* names, int n) {
      mrb_value av[16];
      for (int i = 0; i < n; ++i) av[i] = mrb_symbol_value(mrb_intern_static(M, names[i], strlen(names[i])));
      mrb_funcall_argv(M, mrb_obj_value(c), mrb_intern_static(M, verb, strlen(verb)), n, av);
    }
    static mrb_value bc2cpp_ld_const(mrb_state* M, const bc2cpp_ld_scope* scope, mrb_sym name) {
      mrb_value v;
      for (const bc2cpp_ld_scope* s = scope; s; s = s->up) {
        if (bc2cpp_ld_own(M, mrb_obj_value(s->klass), name, &v)) return v;
      }
      if (bc2cpp_ld_own(M, mrb_obj_value(M->object_class), name, &v)) return v;
      struct RClass* base = scope->klass;
      for (bool retried = false;; retried = true) {
        for (struct RClass* c = retried ? M->object_class : base->super; c; c = c->super) {
          if (MRB_FLAG_TEST(c, MRB_FL_CLASS_IS_PREPENDED)) continue;
          if (bc2cpp_ld_own(M, mrb_obj_value(c->tt == MRB_TT_ICLASS ? c->c : c), name, &v)) return v;
        }
        if (retried || base->tt != MRB_TT_MODULE) break;
      }
      return mrb_const_get(M, mrb_obj_value(base), name);
    }
  CPP

  DECODER = <<~'CPP'
    static mrb_sym bc2cpp_ld_sym(mrb_state* M, unsigned i) {
      return mrb_intern_static(M, bc2cpp_ld_pool + bc2cpp_ld_off[i], bc2cpp_ld_off[i + 1] - bc2cpp_ld_off[i] - 1);
    }
    static unsigned bc2cpp_ld_varint(const unsigned char** p) {
      unsigned v = 0;
      for (int shift = 0;; shift += 7) {
        unsigned char b = *(*p)++;
        v |= (unsigned)(b & 0x7f) << shift;
        if (!(b & 0x80)) return v;
      }
    }
    // DATA_BLOB (tools/bc2cpp/load_compile.rb, Blob): the value a literal table's bytes spell, built as the VM's
    // OP_ARRAY, OP_HASH and OP_RANGE would, in the same order.
    static mrb_value bc2cpp_ld_decode(mrb_state* M, const bc2cpp_ld_scope* scope, const unsigned char** p) {
      const unsigned char tag = *(*p)++;
      switch (tag) {
      case 0: return mrb_nil_value();
      case 1: return mrb_true_value();
      case 2: return mrb_false_value();
      case 3: {
        // 64 bits: the zigzag of -2**31 is 2**32 - 1, and z + 1 wraps in an unsigned.
        const unsigned long long z = bc2cpp_ld_varint(p);
        return mrb_int_value(M, (z & 1) ? -(mrb_int)((z + 1) >> 1) : (mrb_int)(z >> 1));
      }
      case 4: {
        double d;
        memcpy(&d, *p, sizeof d);
        *p += sizeof d;
        return mrb_float_value(M, d);
      }
      case 5: return mrb_symbol_value(bc2cpp_ld_sym(M, bc2cpp_ld_varint(p)));
      case 6: case 7: {
        unsigned i = bc2cpp_ld_varint(p);
        return bc2cpp_ld_str(M, bc2cpp_ld_pool + bc2cpp_ld_off[i], bc2cpp_ld_off[i + 1] - bc2cpp_ld_off[i] - 1, tag == 7);
      }
      case 8: {
        unsigned n = bc2cpp_ld_varint(p);
        mrb_value a = mrb_ary_new_capa(M, n);
        const int ai = mrb_gc_arena_save(M);
        for (unsigned i = 0; i < n; ++i) {
          if (**p == 13) {
            ++*p;
            mrb_ary_concat(M, a, mrb_ary_splat(M, bc2cpp_ld_decode(M, scope, p)));
          } else {
            mrb_ary_push(M, a, bc2cpp_ld_decode(M, scope, p));
          }
          mrb_gc_arena_restore(M, ai);
        }
        return a;
      }
      case 9: {
        unsigned n = bc2cpp_ld_varint(p);
        mrb_value h = mrb_hash_new_capa(M, n);
        const int ai = mrb_gc_arena_save(M);
        for (unsigned i = 0; i < n; ++i) {
          mrb_value k = bc2cpp_ld_decode(M, scope, p);
          mrb_hash_set(M, h, k, bc2cpp_ld_decode(M, scope, p));
          mrb_gc_arena_restore(M, ai);
        }
        return h;
      }
      case 10: {
        const bool exclusive = *(*p)++;
        mrb_value a = bc2cpp_ld_decode(M, scope, p);
        mrb_value b = bc2cpp_ld_decode(M, scope, p);
        return mrb_range_new(M, a, b, exclusive);
      }
      case 11: return bc2cpp_ld_const(M, scope, bc2cpp_ld_sym(M, bc2cpp_ld_varint(p)));
      case 12: {
        mrb_value v = bc2cpp_ld_decode(M, scope, p);
        mrb_obj_freeze(M, v);
        return v;
      }
      case 14: {
        mrb_value base = bc2cpp_ld_decode(M, scope, p);
        return mrb_const_get(M, base, bc2cpp_ld_sym(M, bc2cpp_ld_varint(p)));
      }
      default: return mrb_const_get(M, mrb_obj_value(M->object_class), bc2cpp_ld_sym(M, bc2cpp_ld_varint(p)));
      }
    }
    // CONST_TABLE: `n` constants of the scope `c`, each a name (pool index) and a value, set in order as the VM's
    // SETCONST would, with the arena given back after each.
    static void bc2cpp_ld_consts(mrb_state* M, const bc2cpp_ld_scope* scope, struct RClass* c, const unsigned char* p, unsigned n) {
      const int ai = mrb_gc_arena_save(M);
      for (unsigned i = 0; i < n; ++i) {
        const mrb_sym name = bc2cpp_ld_sym(M, bc2cpp_ld_varint(&p));
        mrb_const_set(M, mrb_obj_value(c), name, bc2cpp_ld_decode(M, scope, &p));
        mrb_gc_arena_restore(M, ai);
      }
    }
  CPP

  # The plan for one gem of the world.
  #   world:     { gem name => [source files in load order] }, every engine gem of the build
  #   gem:       the gem whose output this is
  #   drop_keys: Owner#name keys of this gem's defs the stub proof lets go (MrblibStubs.stubbable)
  #   symbol:    the compiled gem's out_symbol (names the function and the marker)
  def plan(world, gem:, drop_keys:, symbol:, statements: true)
    roots = world.transform_values { |files| files.map { |f| build_root(f, statements: statements) } }
    all = roots.values.flatten
    promote!(all)
    pinned = pinned_names(all)
    decide!(roots.fetch(gem), drop_keys, pinned, stay: !statements)
    mine = roots.fetch(gem)
    files = world.fetch(gem)
    ranges = files.zip(mine).to_h { |file, root| [file, ranges_for(root)] }
    ctx = { count: 0, fns: [], strings: {} }
    entries = mine.map { |root| emit_body(root, ctx) }
    marker = "#{MARKER_PREFIX}#{symbol}"
    code = String.new(PRELUDE)
    code << string_pool(ctx[:strings])
    code << DECODER
    code << ctx[:fns].join("\n\n") << "\n\n"
    code << "static void bc2cpp_load_#{symbol}(mrb_state* M) {\n"
    code << "  // Only when the residual mrblib is what loaded: the full mrblib has done all of this.\n"
    code << "  if (!mrb_test(mrb_gv_get(M, #{sym(marker)}))) return;\n"
    code << "  const bc2cpp_ld_scope top = {M->object_class, nullptr};\n"
    entries.each { |fn| code << "  #{fn}(M, &top, M->object_class);\n" }
    code << "}\n"
    # Defs only: nothing for the load to do, so no function and no marker.
    return Result.new(code: '', ranges: ranges, last_file: files.last, marker: nil, stats: stats(mine), bodies: mine,
                      dropped: dropped_defs(mine)) unless statements

    Result.new(code: code, ranges: ranges, last_file: files.last, marker: marker, stats: stats(mine), bodies: mine,
               dropped: dropped_defs(mine))
  end

  # [{owner:, key:, source:}] of the defs the residual no longer has: what the compiled gem's registration supplies.
  def dropped_defs(roots)
    roots.flat_map do |root|
      out = []
      each_ubody(root) do |ub|
        ub.items.each do |i|
          out << { owner: ub.body.path, key: i.def_key, source: i.stmt.node.slice, kind: ub.body.kind } if i.dropped
        end
      end
      out
    end
  end

  # The strings the blobs name: one pool of NUL-terminated strings and the offset of each (plus the end).
  def string_pool(strings)
    ordered = strings.keys
    offsets = [0]
    ordered.each { |str| offsets << offsets.last + str.bytesize + 1 }
    pool = ordered.empty? ? '""' : ordered.map { |str| "#{cstr(str)[0...-1]}\\000\"" }.join("\n  ")
    "static const char bc2cpp_ld_pool[] =\n  #{pool};\nstatic const unsigned bc2cpp_ld_off[] = {#{offsets.join(', ')}};\n"
  end

  def stats(roots)
    s = Hash.new(0)
    roots.each do |root|
      each_ubody(root) do |ub|
        s[:bodies] += 1
        s[ub.skeleton ? :skeleton_bodies : :deleted_bodies] += 1 unless ub.parent.nil?
        ub.items.each do |i|
          s[:"role_#{i.role}"] += 1
          s[:defs_dropped] += 1 if i.dropped
          s[:defs_kept] += 1 if i.role == :def && !i.dropped
          s[:promoted] += 1 if i.promoted
        end
      end
    end
    s
  end

  # ---- plan files (the manifest the build's rewrite reads) --------------------------------------------------

  def plan_path(out_dir, symbol) = File.join(out_dir, "#{symbol}_load.json")

  # BC2CPP_LOAD_COMPILE: `off` (no plan), `defs` (the residual drops the defs the stub proof lets go and nothing else:
  # no load code, no marker) or `all` (the default: statements compiled too). BC2CPP_LOAD_WORLD: {out_symbol => the gem's mrblib
  # files, as the build loads them}; one build's compiled gems analyse the same world. Nil when off or no world.
  def plan_for_env(env, symbol:, drop_keys:)
    mode = env.fetch('BC2CPP_LOAD_COMPILE', 'all')
    raise "BC2CPP_LOAD_COMPILE: #{mode.inspect} is not off, defs or all" unless %w[off defs all].include?(mode)
    return nil if mode == 'off' || !env['BC2CPP_LOAD_WORLD']

    world = JSON.parse(env['BC2CPP_LOAD_WORLD'])
    return nil unless world.key?(symbol)

    plan(world, gem: symbol, drop_keys: drop_keys, symbol: symbol, statements: mode == 'all')
  end

  def write_plan(path, result)
    return File.write(path, '{}') if result.nil?

    File.write(path, JSON.generate('marker' => result.marker, 'last' => result.last_file,
                                   'files' => result.ranges.transform_values { |r| r.sort }))
  end

  # { source path => [ranges, marker or nil] } of every plan in `paths`; a missing or empty file adds nothing.
  def read_plans(paths)
    paths.each_with_object({}) do |path, all|
      next unless File.exist?(path)

      data = JSON.parse(File.read(path))
      next if data.empty?

      data.fetch('files').each do |file, ranges|
        all[file] = [ranges, file == data['last'] ? data['marker'] : nil]
      end
    end
  end
end
