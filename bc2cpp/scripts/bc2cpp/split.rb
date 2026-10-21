#!/usr/bin/env ruby
# frozen_string_literal: true

# Splits the monolithic tools/bc2cpp/bc2cpp.rb into part files along its
# top-level and CodeGen member seams, as a purely mechanical move, and proves
# the result defines the same code.
#
# Usage:
#   ruby scripts/bc2cpp/split.rb              split the working tree's monolithic
#                                             bc2cpp.rb, then verify
#   ruby scripts/bc2cpp/split.rb --verify REF  check the working tree's parts are
#                                             exactly what splitting REF's
#                                             monolithic bc2cpp.rb produces
#
# A unit is one top-level statement, or one CodeGen body member, plus every
# line between it and the previous one (its leading comments). CUTS below name
# the unit each segment starts at, so a unit added on a newer base lands in the
# segment it sits in; a missing cut name aborts. Verification:
#   - the units, in original order, concatenate back to the original bytes;
#   - the definitions (every def with its owner, every constant, every other
#     class-body and top-level statement) have identical Prism ASTs, comments
#     and locations stripped, apart from the added require_relative lines;
#   - every load-time reference (a constant or receiverless call outside a def
#     body) sees the same earlier definitions in the new load order;
#   - no def or constant is defined twice.

require 'open3'
require 'prism'
require 'set'

ROOT = File.expand_path('../..', __dir__)
DIR = 'tools/bc2cpp'
MAIN = 'bc2cpp.rb'
CODEGEN = 'CodeGen'
MAIN_GUARD = 'if $PROGRAM_NAME == __FILE__'

# [first unit of the segment, target file]. nil keeps the segment in bc2cpp.rb;
# :codegen is the CodeGen class, split by CODEGEN_CUTS. The names are units of the
# pre-split monolith (34f728ae^), so they need not exist in the current sources.
TOP_CUTS = [
  [:first, nil],
  ['MRBC', 'irep.rb'],
  ['detect_struct_new_members', 'registry.rb'],
  ['OPSYM_TO_RUBY', 'native_names.rb'],
  ["require_relative 'native_expression_devirt'", nil],
  ['IntegerConstants', 'integer_constants.rb'],
  ['FOREIGN_METHOD_NAME_RE', 'native_names.rb'],
  ['NativeConstructSchema', 'native_construct_schema.rb'],
  ['READ_ONLY_OPCODE_SKIP', 'ivar_layout.rb'],
  ['ArgTypes', 'annotations.rb'],
  ['BLOCK_RESULT_NAMES', 'class_layout.rb'],
  ['ARRAY_ELEMENT_PRESERVING', 'element_layouts.rb'],
  ['opaque_argument_position', 'diagnostics.rb'],
  ['NATIVE_CONSTRUCT_TARGETS', 'dispatch_targets.rb'],
  ['pure_mandatory_arity?', 'irep_arity.rb'],
  ['report_annotation_candidates', 'diagnostics.rb'],
  [CODEGEN, :codegen],
  [MAIN_GUARD, nil],
].freeze

CODEGEN_CUTS = [
  [:first, 'codegen.rb'],
  ['POLY_SMALL_N_MAX', 'codegen_ivar_poly.rb'],
  ['eqq_literal_devirt_safe?', 'codegen_native_send.rb'],
  ['annotated_array_return', 'codegen_receiver_facts.rb'],
  ['compiles_clean?', 'codegen_emit.rb'],
  ['compile_method', 'codegen_method.rb'],
  ['jmpuw_is_plain_jump?', 'codegen_rescue.rb'],
  ['recognize_times_regions', 'codegen_loop_regions.rb'],
  ['FIXNUM_PROOF_STEP_OVER_OPS', 'codegen_fixnum_proof.rb'],
  ['compute_fixnum_return_names', 'codegen_return_analysis.rb'],
  ['COLLECT_BLOCK_METHODS', 'codegen_loop_regions.rb'],
  ['InlineNested', 'codegen_loop_inline.rb'],
  ['block_fallback_region_has_return_blk?', 'codegen_block_fallback.rb'],
  ['recognize_lambda_fallback_regions', 'codegen_runtime_def.rb'],
  ['compile_insn', 'codegen_insn.rb'],
  ['literal_symbol_write', 'codegen_keyword_send.rb'],
  ['compile_send', 'codegen_send.rb'],
].freeze

DESCRIPTIONS = {
  'irep.rb' => 'Steps 1-5: run mrbc, parse its C and -v dumps into Ireps, and merge them.',
  'registry.rb' => 'Step 6: the whole-program class/method registry.',
  'native_names.rb' => 'Step 5b: method names defined or called outside the compiled bytecode.',
  'integer_constants.rb' => 'INTEGER_CONSTANT_PROOF: constant names that only ever hold an Integer.',
  'native_construct_schema.rb' => 'NATIVE_CONSTRUCT_SCHEMA_AUDIT (audit only, never read by codegen).',
  'ivar_layout.rb' => 'Step 6b: which ivars embed into typed C struct fields.',
  'annotations.rb' => 'Steps 6c-6f-ter: call-site argument types and `# bc2cpp:` annotations.',
  'class_layout.rb' => 'Steps 6f-bis and 6g: proven fresh Arrays and ivar classes.',
  'element_layouts.rb' => 'Step 6g-bis: element classes of Array and Hash ivars.',
  'diagnostics.rb' => 'Steps 6e and 6h: annotation candidates and static call targets (diagnostic only).',
  'dispatch_targets.rb' => 'Construct, native-argument and super devirtualization targets.',
  'irep_arity.rb' => 'Argument shapes and block/lambda/def fallback safety of an irep.',
  'codegen.rb' => 'CodeGen: construction, embedding and the monomorphic-target queries.',
  'codegen_ivar_poly.rb' => 'CodeGen: POLY_SMALL_N chains, ivar access and outlined index helpers.',
  'codegen_native_send.rb' => 'CodeGen: sends devirtualized to native primitives.',
  'codegen_receiver_facts.rb' => 'CodeGen: receiver, owner and super-target facts.',
  'codegen_emit.rb' => 'CodeGen: per-method compile state and file-level emission.',
  'codegen_method.rb' => 'CodeGen: compile_method and jump targets.',
  'codegen_rescue.rb' => 'CodeGen: ensure and rescue regions.',
  'codegen_loop_regions.rb' => 'CodeGen: recognizers of inlinable block-loop regions.',
  'codegen_fixnum_proof.rb' => 'CodeGen: FIXNUM_OPERAND_PROOF and entry-argument facts.',
  'codegen_return_analysis.rb' => 'CodeGen: Fixnum, Array and class return proofs.',
  'codegen_loop_inline.rb' => 'CodeGen: emitters of inlined block loops.',
  'codegen_block_fallback.rb' => 'CodeGen: blocks that stay procs, and fiber safety.',
  'codegen_runtime_def.rb' => 'CodeGen: lambda, runtime def and exec fallbacks.',
  'codegen_insn.rb' => 'CodeGen: compile_insn and comparisons.',
  'codegen_keyword_send.rb' => 'CodeGen: keyword and splat sends.',
  'codegen_send.rb' => 'CodeGen: compile_send and const/owner caches.',
}.freeze

LOAD_ORDER_NOTE = "# Parts split out by scripts/bc2cpp/split.rb, loaded in original definition order.\n"

Unit = Struct.new(:node, :name, :text, :start_line, :last_line, keyword_init: true)

# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------

def last_line_of(node, source)
  last = source.line(node.location.end_offset - 1)
  stack = [node]
  until stack.empty?
    n = stack.pop
    if n.respond_to?(:closing_loc) && n.closing_loc
      last = [last, source.line(n.closing_loc.end_offset - 1)].max
    end
    stack.concat(n.compact_child_nodes)
  end
  last
end

def unit_name(node)
  case node
  when Prism::DefNode then node.receiver ? "#{node.receiver.slice}.#{node.name}" : node.name.to_s
  when Prism::ConstantWriteNode then node.name.to_s
  when Prism::ClassNode, Prism::ModuleNode then node.constant_path.slice
  when Prism::SingletonClassNode then 'class << self'
  else node.slice.lines.first.chomp
  end
end

# Each node plus the lines since the previous one; `from` is the first line.
def units_of(nodes, lines, source, from)
  nodes.map do |node|
    start = node.location.start_line
    raise "#{unit_name(node)} shares line #{start} with the unit before it" if start < from

    last = last_line_of(node, source)
    unit = Unit.new(node: node, name: unit_name(node), text: lines[(from - 1)...last].join,
                    start_line: from, last_line: last)
    from = last + 1
    unit
  end
end

# [[target, [unit, ...]], ...] in source order.
def segments(units, cuts, where)
  starts = cuts.map do |name, target|
    next [0, target] if name == :first

    idx = units.each_index.select { |i| units[i].name == name }
    raise "#{where}: cut #{name.inspect} matches #{idx.size} units" unless idx.size == 1

    [idx.first, target]
  end
  starts.each_cons(2) { |(a, _), (b, _)| raise "#{where}: cuts out of order at unit #{b}" unless a < b }
  starts.each_with_index.map do |(from, target), i|
    to = i + 1 < starts.size ? starts[i + 1][0] : units.size
    [target, units[from...to]]
  end
end

# ---------------------------------------------------------------------------
# Split
# ---------------------------------------------------------------------------

def magic_line(src)
  line = src.lines.find { |l| l.start_with?('# frozen_string_literal:') }
  raise 'bc2cpp.rb has no frozen_string_literal magic comment' unless line

  line
end

def strip_leading_blank(text)
  text.sub(/\A(?:[ \t]*\n)+/, '')
end

def part_header(src, file)
  "#{magic_line(src)}\n# #{DESCRIPTIONS.fetch(file)}\n\n"
end

# Returns [files ({name => text}), pieces (the original units in order, for
# the round-trip check), load order].
def split(src)
  result = Prism.parse(src)
  raise "bc2cpp.rb does not parse: #{result.errors.map(&:message).join('; ')}" unless result.errors.empty?

  lines = src.lines
  source = result.source
  top = units_of(result.value.statements.body, lines, source, 1)
  tail = lines[top.last.last_line..].join
  raise 'bc2cpp.rb has code after the main guard' unless tail.strip.empty?

  top.last.text += tail

  top_segments = segments(top, TOP_CUTS, 'top level')
  cg_unit = top.find { |u| u.name == CODEGEN }
  raise 'no CodeGen class (already split?)' unless cg_unit&.node.is_a?(Prism::ClassNode)
  raise 'the main guard is not the last statement' unless top.last.name == MAIN_GUARD

  cg = cg_unit.node
  # The class line ends the header; the members' chunks start after it.
  class_line = (cg.superclass || cg.constant_path).location.end_line
  members = units_of(cg.body.body, lines, source, class_line + 1)

  cg_header = lines[(cg_unit.start_line - 1)...class_line].join
  cg_tail = lines[members.last.last_line...(cg_unit.last_line - 1)].join
  cg_end = lines[cg_unit.last_line - 1]
  raise "CodeGen does not end with a bare `end`: #{cg_end.inspect}" unless cg_end == "end\n"

  cg_segments = segments(members, CODEGEN_CUTS, CODEGEN)
  pieces = []
  files = Hash.new { |h, k| h[k] = +'' }
  order = []
  main = +''
  pending = []
  flush = lambda do
    next if pending.empty?

    main << "\n" << (order.size == pending.size ? LOAD_ORDER_NOTE : '')
    pending.each { |f| main << "require_relative '#{File.basename(f, '.rb')}'\n" }
    pending.clear
  end
  add = lambda do |file|
    unless order.include?(file)
      order << file
      pending << file
      files[file] << part_header(src, file)
    end
  end

  top_segments.each do |target, units|
    if target.nil?
      flush.call
      units.each do |u|
        main << u.text
        pieces << u.text
      end
    elsif target == :codegen
      first = true
      cg_segments.each do |file, mems|
        fresh = !order.include?(file)
        add.call(file)
        if first
          files[file] << strip_leading_blank(cg_header)
          pieces << cg_header
        elsif fresh
          files[file] << "class #{CODEGEN}\n"
        end
        mems.each_with_index do |m, i|
          files[file] << (i.zero? && fresh && !first ? strip_leading_blank(m.text) : m.text)
          pieces << m.text
        end
        first = false
      end
      cg_segments.map(&:first).uniq.each_with_index do |file, i|
        files[file] << cg_tail if i == cg_segments.map(&:first).uniq.size - 1
        files[file] << "end\n"
      end
      pieces << cg_tail << cg_end
    else
      fresh = !order.include?(target)
      add.call(target)
      units.each_with_index do |u, i|
        files[target] << (i.zero? && fresh ? strip_leading_blank(u.text) : u.text)
        pieces << u.text
      end
    end
  end
  flush.call
  files[MAIN] = main
  [files, pieces, order]
end

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

# Node types, literal values and token text; locations and comments ignored
# (the same normalization as scripts/bc2cpp/comment_only_check.rb).
def fingerprint(node, out = +'')
  out << node.class.name.split('::').last << '('
  node.deconstruct_keys(nil).each do |key, value|
    # node_id is a per-parse counter (Prism 1.x exposes it), so it never compares equal across parses.
    next if key == :location || key == :node_id

    out << key.to_s << ':'
    fp_value(value, out)
  end
  out << ')'
end

def fp_value(value, out)
  case value
  when Prism::Node then fingerprint(value, out)
  when Prism::Location
    slice = value.slice
    out << (slice.include?("\n") ? 'loc=<multi-line>' : "loc=#{slice.inspect}")
  when Array
    out << '['
    value.each { |v| fp_value(v, out) }
    out << ']'
  else out << value.inspect
  end
end

def parse!(path, src)
  result = Prism.parse(src)
  raise "#{path} does not parse: #{result.errors.map(&:message).join('; ')}" unless result.errors.empty?
  raise "#{path} contains __LINE__" if src.include?('__LINE__')

  result.value.statements.body
end

def require_target(node)
  return nil unless node.is_a?(Prism::CallNode) && node.name == :require_relative && node.receiver.nil?

  arg = node.arguments&.arguments&.first
  arg.is_a?(Prism::StringNode) ? "#{arg.unescaped}.rb" : nil
end

# Definition entries of a body: [key, fingerprint], in order.
def definitions(stmts, owner, out)
  stmts.each do |n|
    case n
    when Prism::DefNode
      sep = n.receiver ? ".#{n.receiver.slice}." : '#'
      out << ["def #{owner}#{sep}#{n.name}", fingerprint(n)]
    when Prism::ConstantWriteNode
      out << ["const #{owner}::#{n.name}", fingerprint(n.value)]
    when Prism::ClassNode, Prism::ModuleNode
      path = owner.empty? ? n.constant_path.slice : "#{owner}::#{n.constant_path.slice}"
      key = "#{n.is_a?(Prism::ClassNode) ? 'class' : 'module'} #{path}"
      out << [key, ''] unless out.include?([key, ''])
      out << ["#{key} <", fingerprint(n.superclass)] if n.is_a?(Prism::ClassNode) && n.superclass
      definitions(n.body ? n.body.body : [], path, out)
    when Prism::SingletonClassNode
      definitions(n.body ? n.body.body : [], "#{owner}.singleton", out)
    else
      out << ["stmt #{owner.empty? ? '(top)' : owner}", fingerprint(n)]
    end
  end
  out
end

# The whole program as the loader sees it: generated parts are expanded in
# place of their require_relative; `generated` maps file name => source.
def expand(stmts, generated, seq = [])
  stmts.each do |n|
    target = require_target(n)
    if target && generated.key?(target)
      expand(parse!(target, generated.fetch(target)), generated, seq)
    else
      seq << n
    end
  end
  seq
end

# Load-time units in execution order, CodeGen (and any class opened more than
# once) broken into members: [[id, node], ...].
def load_units(stmts)
  stmts.flat_map do |n|
    if n.is_a?(Prism::ClassNode) && n.constant_path.slice == CODEGEN
      n.body.body.map { |m| ["#{CODEGEN}/#{unit_id(m)}", m] }
    else
      [[unit_id(n), n]]
    end
  end
end

def unit_id(node)
  "#{unit_name(node)}@#{fingerprint(node).hash}"
end

# Constants and methods a unit makes available, by bare name.
def provides(node, dir, seen = Set.new)
  names = Set.new
  target = require_target(node)
  if target && File.exist?(File.join(dir, target))
    # A require cycle (bytecode_ir <-> bytecode_ir_classes) would recurse forever; the names
    # from its first visit are already in the caller's set.
    return names unless seen.add?(target)

    parse!(target, File.read(File.join(dir, target))).each { |n| names.merge(provides(n, dir, seen)) }
    return names
  end
  stack = [node]
  until stack.empty?
    n = stack.pop
    case n
    when Prism::DefNode then names << "m:#{n.name}"
                             next
    when Prism::ConstantWriteNode then names << "c:#{n.name}"
    when Prism::ClassNode, Prism::ModuleNode then names << "c:#{n.constant_path.slice.split('::').last}"
    end
    stack.concat(n.compact_child_nodes)
  end
  names
end

# What a unit reads while it loads (outside def bodies).
def load_refs(node)
  refs = Set.new
  stack = [node]
  until stack.empty?
    n = stack.pop
    next if n.is_a?(Prism::DefNode)

    case n
    when Prism::ConstantReadNode then refs << "c:#{n.name}"
    when Prism::ConstantPathNode then refs << "c:#{n.child.name}" if n.child.respond_to?(:name)
    when Prism::CallNode then refs << "m:#{n.name}" if n.receiver.nil?
    end
    stack.concat(n.compact_child_nodes)
  end
  refs
end

# For each unit and each name it reads at load time: the units providing that
# name that loaded before it (or are it).
def visible_providers(units, dir)
  raise 'load units are not unique' unless units.map(&:first).uniq.size == units.size

  prov = units.to_h { |id, n| [id, provides(n, dir)] }
  seen = Hash.new { |h, k| h[k] = Set.new }
  units.each_with_object({}) do |(id, n), acc|
    prov[id].each { |name| seen[name] << id }
    acc[id] = load_refs(n).to_h { |name| [name, seen[name].dup] }
  end
end

def check(failures, what, ok, detail = nil)
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << "#{what}#{detail ? ": #{detail}" : ''}" unless ok
end

def verify(original, files, pieces, dir)
  failures = []
  check(failures, 'units concatenate back to the original bc2cpp.rb byte for byte', pieces.join == original)

  generated = files.reject { |k, _| k == MAIN }
  before_stmts = parse!(MAIN, original)
  after_stmts = expand(parse!(MAIN, files.fetch(MAIN)), generated)
  before = definitions(before_stmts, '', [])
  after = definitions(after_stmts, '', [])
  missing = (before - after).map(&:first)
  extra = (after - before).map(&:first)
  check(failures, "same definitions (#{before.count { |k, _| k.start_with?('def ') }} defs, " \
                  "#{before.count { |k, _| k.start_with?('const ') }} constants, " \
                  "#{before.count { |k, _| k.start_with?('stmt ') }} other statements), same ASTs",
        before.sort == after.sort, "missing #{missing.first(5)}, extra #{extra.first(5)}")
  keys = after.map(&:first).grep(/\A(def|const) /)
  dups = keys.tally.select { |_, c| c > 1 }.keys
  check(failures, 'no def or constant defined twice', dups.empty?, dups.first(5).inspect)
  bc2cpp_rb_lines = files.fetch(MAIN).lines
  added = bc2cpp_rb_lines - original.lines
  only_requires = added.all? { |l| l == "\n" || l == LOAD_ORDER_NOTE || l.match?(/\Arequire_relative '\w+'\n\z/) }
  check(failures, 'bc2cpp.rb only gains require_relative lines', only_requires)

  # Pre-existing parts: their own definitions must not collide with moved ones.
  others = Dir.glob(File.join(dir, '*.rb')).map { |p| File.basename(p) } - files.keys
  other_defs = others.flat_map do |f|
    definitions(parse!(f, File.read(File.join(dir, f))), '', []).map(&:first).grep(/\A(def|const) /)
  end
  clash = keys & other_defs
  check(failures, 'no moved def or constant collides with one in another tools/bc2cpp file', clash.empty?,
        clash.first(5).inspect)

  old_vis = visible_providers(load_units(before_stmts), dir)
  new_vis = visible_providers(load_units(after_stmts), dir)
  changed = old_vis.keys.reject { |id| old_vis[id] == new_vis[id] }
  check(failures, "every load-time reference sees the same definitions (#{old_vis.values.sum(&:size)} refs)",
        old_vis.keys.sort == new_vis.keys.sort && changed.empty?, changed.first(5).inspect)
  magic = magic_line(original)
  check(failures, "every part carries #{magic.strip}", generated.values.all? { |t| t.start_with?(magic) })
  failures
end

def report(files, order)
  puts 'layout (load order):'
  [MAIN, *order].each { |f| puts format('  %6d  %s', files.fetch(f).lines.size, f) }
end

dir = File.join(ROOT, DIR)
if ARGV[0] == '--verify'
  ref = ARGV.fetch(1) { abort 'usage: bc2cpp_split.rb --verify REF' }
  original, err, status = Open3.capture3('git', '-C', ROOT, 'show', "#{ref}:#{DIR}/#{MAIN}")
  abort "git show failed: #{err}" unless status.success?
  files, pieces, order = split(original)
  puts "bc2cpp split check: #{ref} -> working tree"
  failures = []
  files.each do |name, text|
    path = File.join(dir, name)
    check(failures, "#{name} is exactly the generated split", File.exist?(path) && File.read(path) == text)
  end
else
  abort "usage: #{$PROGRAM_NAME} [--verify REF]" unless ARGV.empty?
  original = File.read(File.join(dir, MAIN))
  files, pieces, order = split(original)
  clobbered = files.keys.reject { |f| f == MAIN || !File.exist?(File.join(dir, f)) }
  abort "refusing to overwrite existing #{clobbered.join(', ')}" unless clobbered.empty?
  files.each { |name, text| File.write(File.join(dir, name), text) }
  puts 'bc2cpp split: wrote the parts'
  failures = []
end
report(files, order)
failures.concat(verify(original, files, pieces, dir))
if failures.empty?
  puts 'bc2cpp split: PASS'
else
  warn "bc2cpp split: #{failures.size} failure(s)"
  failures.each { |f| warn "  #{f}" }
  exit 1
end
