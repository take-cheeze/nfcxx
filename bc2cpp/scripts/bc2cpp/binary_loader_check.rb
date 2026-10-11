#!/usr/bin/env ruby
# frozen_string_literal: true

# The RITE-binary loader (RiteBinary + InsnDecoder + load_ireps) must agree
# with two independent readings of the same sources: the `mrbc -v` text (each
# irep's header counts, file, catch handlers and every instruction: addr, op,
# typed operands, args, raw, line) and the `mrbc -B -S` C dump (labels, reps
# tree, nlocals/nregs, pool entries, exact symbol and local names). Both
# references are parsed here only; the compiler itself reads the binary.
# Checked for the real closed-world gems and a synthetic source covering EXT
# widening, catch tables, pool literals and odd symbol names. Usage:
# MRBC=path/to/mrbc ruby scripts/bc2cpp/binary_loader_check.rb
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/compiled_gems'

ROOT = File.expand_path('../..', __dir__)

# 200 locals and 300 distinct symbols/strings push operands past one byte, so
# mrbc emits EXT1/EXT2/EXT3 prefixes.
def synthetic_source
  locals = (0...200).map { |i| "v#{i} = #{i}" }.join("\n")
  calls = (0...300).map { |i| "self.m#{i}(#{i % 200 == 0 ? (0...120).map { |k| "v#{k}" }.join(",") : "v#{i % 200}"}, \"s#{i}\", :y#{i}, #{i}.5)" }.join("\n")
  <<~RUBY
    class Wide
      def wide
        #{locals}
        #{calls}
        v199 + v0
      end

      def flow(a, b = 2, *r, k: 1, **o, &blk)
        begin
          yield a
        rescue ArgumentError, TypeError => e
          p e
        ensure
          a = "multi
    line ; string"
        end
        [:"a-b", :+, :[]=, :foo?, :bar!, :baz=, :@iv, :$gv, :"\\u3042"].each { |s| s.to_s }
        x = -1; y = 70000; z = 3_000_000_000; w = -3_000_000_000; f = 1.5e300
        @a, @@c, $g = x, y, z
        [*r, 1].map { |i| i * 2 }
        {a: 1, **o}
        a.b&.c
        case a when 1..2 then 1 else 2 end
        ObjectSpace.each_object { |q| q }
        return a unless b
        super
      end

      def self.cls; class << self; self; end; end
      alias_method :old_flow, :flow
      alias other wide
      undef_method :other
    end
    Wide.new.wide
  RUBY
end

TextIrep = Struct.new(:nregs, :nlocals, :pools, :syms, :reps, :file, :catches, :insns)

# One-shot parse of `mrbc -v`: the disassembly blocks in DFS pre-order.
def parse_text_reference(srcs, dir, label)
  text = IO.popen([MRBC, '-v', '-o', File.join(dir, "#{label}_text.mrb"), *srcs], external_encoding: 'UTF-8', &:read)
  raise 'mrbc -v failed' unless $?.success?

  blocks = []
  ext_addr = nil
  text.each_line do |line|
    if line =~ /^irep 0x\h+ nregs=(\d+) nlocals=(\d+) pools=(\d+) syms=(\d+) reps=(\d+)/
      blocks << TextIrep.new(*Regexp.last_match.captures.map(&:to_i), nil, [], [])
    elsif blocks.empty?
      next
    elsif line =~ /^file: (.+)$/
      blocks.last.file = Regexp.last_match(1)
    elsif line =~ /^catch type: (\w+)\s+begin: (\d+)\s+end: (\d+)\s+target: (\d+)/
      type, b, e, t = Regexp.last_match.captures
      blocks.last.catches << CatchHandler.new(type: type.to_sym, begin_addr: b.to_i, end_addr: e.to_i, target: t.to_i)
    elsif line =~ /^\s*(\d+)\s+(\d+)\s+([A-Z][A-Z0-9_]*)\s*(.*)$/
      lineno, addr, op, rest = Regexp.last_match.captures
      if InsnDecoder::EXT_WIDTH.key?(op) && InsnDecoder.fold_ext_prefix?
        ext_addr = addr
        next
      end
      raw = line.rstrip
      # The decoder folds a prefix into the instruction it widens, which then starts at the prefix byte.
      if ext_addr
        addr = ext_addr
        raw = raw.sub(/\A(\s*\d+\s+)\d+/) { "#{Regexp.last_match(1)}#{format('%03d', ext_addr.to_i)}" }
        ext_addr = nil
      end
      blocks.last.insns << Insn.new(lineno: lineno.to_i, addr: addr.to_i, op: op, args: rest.strip, raw: raw)
    end
  end
  blocks
end

# src/cdump.c operator_table: MRB_OPSYM(name) -> symbol text.
OPSYM_NAMES = {
  'not' => '!', 'mod' => '%', 'and' => '&', 'mul' => '*', 'add' => '+', 'sub' => '-', 'div' => '/', 'lt' => '<',
  'gt' => '>', 'xor' => '^', 'tick' => '`', 'or' => '|', 'neg' => '~', 'neq' => '!=', 'nmatch' => '!~',
  'andand' => '&&', 'pow' => '**', 'plus' => '+@', 'minus' => '-@', 'lshift' => '<<', 'le' => '<=', 'eq' => '==',
  'match' => '=~', 'ge' => '>=', 'rshift' => '>>', 'aref' => '[]', 'oror' => '||', 'cmp' => '<=>', 'eqq' => '===',
  'aset' => '[]='
}.freeze

def c_symbol_name(kind, word)
  case kind
  when 'SYM' then word
  when 'SYM_Q' then "#{word}?"
  when 'SYM_B' then "#{word}!"
  when 'SYM_E' then "#{word}="
  when 'IVSYM' then "@#{word}"
  when 'CVSYM' then "@@#{word}"
  when 'OPSYM' then OPSYM_NAMES.fetch(word)
  else raise "unknown symbol form MRB_#{kind}"
  end
end

# The C source of an mrb_str_dump'ed string (`\n`, `\xNN`, `\"`, ...).
def unescape_c_dump(text)
  simple = { 'n' => "\n", 't' => "\t", 'r' => "\r", 'e' => "\e", 'a' => "\a", 'b' => "\b", 'f' => "\f", 'v' => "\v" }
  text.b.gsub(/\\(x\h\h|.)/m) do
    esc = Regexp.last_match(1)
    esc.length == 3 ? [esc[1, 2]].pack('H2') : simple.fetch(esc, esc)
  end.force_encoding(Encoding::UTF_8)
end

CReference = Struct.new(:nlocals, :nregs, :reps, :pool, :syms, :lv)

# label => CReference, read off the `mrbc -B -S` C source. A `0` entry of a
# symbol array is either a null symbol or one interned at load time; the
# `<var>[i] = mrb_intern_lit(...)` lines tell them apart.
def parse_c_reference(c_src, symbol)
  sym = Regexp.escape(symbol)
  init = {}
  c_src.scan(/^  (#{sym}_(?:syms|lv)_\d+)\[(\d+)\] = mrb_intern_lit\(mrb, "((?:[^"\\]|\\.)*)"\);$/) do |var, idx, str|
    init[[var, idx.to_i]] = unescape_c_dump(str)
  end
  decode = lambda do |var, body|
    out = []
    body.scan(/MRB_(\w+?)\((\w+)\)|0/) do
      kind = Regexp.last_match(1)
      out << (kind ? c_symbol_name(kind, Regexp.last_match(2)) : init[[var, out.length]])
    end
    out
  end
  pools = {}
  c_src.scan(/static const mrb_irep_pool #{sym}_pool_(\d+)\[\d+\] = \{(.*?)\n\};/m) do |label, body|
    pools[label] = body.scan(/\{IREP_TT_(\w+)(?:\|[^,]+)?,\s*\{(.*?)\}\},/m).map do |tag, val|
      if %w[SSTR STR].include?(tag)
        [:str, val[/"((?:[^"\\]|\\.)*)"/, 1].to_s.gsub(/\\x(\h\h)/) { [Regexp.last_match(1)].pack('H2') }.b]
      else
        [tag.downcase.to_sym, val.strip]
      end
    end
  end
  syms = {}
  lvs = {}
  c_src.scan(/mrb_DEFINE_SYMS_VAR\((#{sym}_(syms|lv)_(\d+)), \d+, \((.*?)\), (?:const)?\);/m) do |var, key, label, body|
    (key == 'syms' ? syms : lvs)[label] = decode.call(var, body)
  end
  reps = {}
  c_src.scan(/static const mrb_irep \*(?:const )?#{sym}_reps_(\d+)\[\d+\] = \{(.*?)\n\};/m) do |label, body|
    reps[label] = body.scan(/&#{sym}_irep_(\d+)/).flatten
  end
  refs = {}
  c_src.scan(/static const mrb_irep #{sym}_irep_(\d+) = \{\s*\n\s*(\d+),(\d+),/) do |label, nlocals, nregs|
    refs[label] = CReference.new(nlocals.to_i, nregs.to_i, reps[label] || [], pools[label] || [], syms[label] || [],
                                 lvs[label] || [])
  end
  refs
end

def compare_metadata(label, ireps, root, refs, failures)
  failures << "#{label}: labels differ from the C dump's" unless ireps.keys.sort == refs.keys.sort
  failures << "#{label}: root #{root} is not irep_0" unless root == '0'
  ireps.each do |l, irep|
    ref = refs[l] or next
    got = [irep.nlocals, irep.nregs, irep.reps, irep.syms, irep.lv.first(ref.lv.length)]
    want = [ref.nlocals, ref.nregs, ref.reps, ref.syms, ref.lv]
    failures << "#{label} irep #{l}: nlocals/nregs/reps/syms/lv #{got.inspect} != #{want.inspect}" unless got == want
    pool = irep.pool.map { |e| e.is_a?(String) ? [:str, e.b] : [e[:type], e[:raw]] }
    failures << "#{label} irep #{l}: pool #{pool.inspect} != #{ref.pool.inspect}" unless pool == ref.pool
  end
end

def compare_instructions(order, ireps, text, failures)
  order.zip(text).each_with_index do |(l, want), index|
    break if want.nil? || failures.length > 20

    irep = ireps.fetch(l)
    got_header = [irep.nregs, irep.nlocals, irep.pool.length, irep.syms.length, irep.reps.length]
    want_header = [want.nregs, want.nlocals, want.pools, want.syms, want.reps]
    failures << "irep #{index}: header #{got_header} != #{want_header}" unless got_header == want_header
    failures << "irep #{index}: file #{irep.file.inspect} != #{want.file.inspect}" unless irep.file == want.file
    failures << "irep #{index}: catch handlers differ" unless irep.catch_handlers == want.catches
    unless irep.instructions.length == want.insns.length
      failures << "irep #{index}: #{irep.instructions.length} insns != #{want.insns.length}"
      next
    end
    irep.instructions.zip(want.insns).each do |g, w|
      fields = { addr: [g.addr, w.addr], op: [g.op, w.op], lineno: [g.lineno, w.lineno], args: [g.args, w.args],
                 raw: [g.raw, w.raw], typed: [g.typed, w.typed] }
      # codedump.c prints both ALIAS names with two mrb_sym_dump calls in one fprintf, and a short
      # (inline) symbol is decoded into a shared buffer, so `alias succ next` reads `:succ succ` in
      # the text. The bytes decide (vm.c OP_ALIAS: Syms[a] is the new name, Syms[b] the old one), so
      # only the first name of such a line is a usable reference.
      names = ->(args) { args.split("\t").map { |n| n.delete_prefix(':') } }
      if w.op == 'ALIAS' && names.call(w.args).uniq.size == 1 && names.call(g.args).uniq.size == 2
        fields.delete(:raw)
        fields[:args] = [g.args.split("\t").first, w.args.split("\t").first]
        fields[:typed] = [g.typed.first, g.typed.first]
      end
      fields.each do |field, (gv, wv)|
        failures << "irep #{index} @#{w.addr} #{w.op} #{field}: #{gv.inspect} != #{wv.inspect}" unless gv == wv
      end
      break if failures.length > 20
    end
  end
end

def compare(label, dir, srcs)
  text = parse_text_reference(srcs, dir, label)
  c_dump = File.join(dir, "#{label}_ref.c")
  system(MRBC, '-B', "#{label}_ref", '-S', '-o', c_dump, *srcs, exception: true)
  refs = parse_c_reference(File.read(c_dump, encoding: 'UTF-8'), "#{label}_ref")
  ireps, root = compile_ireps(srcs, "#{label}_bin", dir)
  order = dfs_order(ireps, root)

  failures = []
  compare_metadata(label, ireps, root, refs, failures)
  failures << "irep count #{order.length} != #{text.length}" unless order.length == text.length
  compare_instructions(order, ireps, text, failures)
  abort "bc2cpp binary loader check: FAIL #{label}\n  #{failures.first(20).join("\n  ")}" unless failures.empty?
  [text.length, text.sum { |t| t.insns.length }]
end

# InsnDecoder::FORMATS must match mruby/ops.h opcode-for-opcode.
def check_formats
  core = ENV['BC2CPP_MRUBY_CORE'] || File.join(ROOT, '3rd/mruby')
  header = File.join(core, 'include/mruby/ops.h')
  return puts('bc2cpp binary loader check: ops.h not found, opcode table unchecked') unless File.exist?(header)

  want = File.read(header).scan(/^OPCODE\((\w+),\s*(\w+)\)/).map { |name, fmt| [name, fmt] }
  abort 'bc2cpp binary loader check: FAIL InsnDecoder::FORMATS differs from ops.h' unless want == InsnDecoder::FORMATS
  # The extension-prefix opcodes are decoded by name, so their numbers matter.
  puts "bc2cpp binary loader check: #{want.length} opcode formats match ops.h"
end

check_formats
results = Dir.mktmpdir do |dir|
  synthetic = File.join(dir, 'synthetic.rb')
  File.write(synthetic, synthetic_source)
  { 'synthetic' => compare('synthetic', dir, [synthetic]),
    'closed world' => compare('closed_world', dir, closed_world_mrblib_srcs(ROOT)) }
end
results.each { |label, (ireps, insns)| puts "bc2cpp binary loader check: #{label} PASS (#{ireps} ireps, #{insns} instructions)" }
