# frozen_string_literal: true

require 'digest'
require 'stringio'
require_relative 'shard_output'

# IMPLICIT_STATE: for a build that has one mrb_state at a time (the Wio firmware), bc2cpp's own functions read it
# from one global instead of taking it as their first parameter: no call between them moves M into r0.
#
# A text pass over the finished output (after the shard split): each namespace-level declaration and definition of a
# converted function loses its `mrb_state* M` parameter, and a definition naming M starts with BC2CPP_IMPLICIT_M (a
# local read of the global). Call sites stay: before the first declaration of a converted function in a translation
# unit stands an always-inline overload that takes the state and the declared parameter types and calls it, so each
# `f(M, ...)` converts its arguments as before. Kept: a name used other than as a call (a method-table entry, a protect
# body, a callback: a fixed C ABI), a name with an overload without the state, extern "C", templates, function-pointer
# or defaulted parameters, and the entry header's names (hosts declare those themselves).
#
# SINGLE_STATE: sound while one mrb_state is open at a time. The global is stored where M first enters generated code
# (bc2cpp_gem_init, the core's class units, an extern "C" definition); every kept definition and every forwarder
# compares its incoming M with it under BC2CPP_IMPLICIT_STATE_CHECK. A build opts in by defining BC2CPP_IMPLICIT_STATE
# (compiled_gems.rb then sets the env for the generation); BC2CPP_IMPLICIT_STATE=0 turns it off.
module ImplicitState
  ENV_KEY = 'BC2CPP_IMPLICIT_STATE'
  STORE_NAMES = %w[bc2cpp_gem_init bc2cpp_core_class_units].freeze
  IDENT = /[A-Za-z_$][\w$]*/
  # The parameter text after `NAME(`: the state parameter, then `,` or `)`.
  STATE_PARAM = /\A\s*mrb_state\s*\*\s*(M\b)?\s*(?=,|\z)/
  ANY_HEAD = /\A(?<pre>[^(){};=]*?)(?<name>[A-Za-z_$][\w$]*)\(/
  HEAD = /\A(?<pre>[^(){};=]*?)(?<name>[A-Za-z_$][\w$]*)\(\s*mrb_state\s*\*\s*(?:M\b)?\s*[,)]/
  PRELUDE = <<~'CPP'
    // IMPLICIT_STATE (implicit_state.rb): generated for a build with one mrb_state, which these functions read here.
    #ifndef BC2CPP_IMPLICIT_STATE_PRELUDE
    #define BC2CPP_IMPLICIT_STATE_PRELUDE
    #if !defined(BC2CPP_IMPLICIT_STATE) || !BC2CPP_IMPLICIT_STATE
    #error "generated with BC2CPP_IMPLICIT_STATE=1 (implicit_state.rb): compile with -DBC2CPP_IMPLICIT_STATE=1"
    #endif
    #include <stdio.h>
    #include <stdlib.h>
    struct mrb_state;
    // SINGLE_STATE (implicit_state.rb): the one open mrb_state.
    inline struct mrb_state* bc2cpp_implicit_state = nullptr;
    #define BC2CPP_IMPLICIT_M [[maybe_unused]] mrb_state* const M = bc2cpp_implicit_state;
    #if defined(BC2CPP_IMPLICIT_STATE_CHECK) && BC2CPP_IMPLICIT_STATE_CHECK
    [[noreturn, gnu::cold]] inline void bc2cpp_implicit_state_abort() {
      fputs("[bc2cpp] IMPLICIT_STATE: generated code for one mrb_state reached by another\n", stderr);
      abort();
    }
    #define BC2CPP_STATE_CHECK(m) ((m) == bc2cpp_implicit_state ? (void)0 : bc2cpp_implicit_state_abort())
    #else
    #define BC2CPP_STATE_CHECK(m) ((void)(m))
    #endif
    #endif
  CPP

  module_function

  def enabled?(env = ENV)
    env[ENV_KEY] == '1'
  end

  # Registered before ShardOutput (at_exit runs last-in first-out), so this reads the main text it prints and the
  # shard files it wrote, and rewrites them with the gem's declarations header.
  def capture_stdout(out_dir, symbol, shards)
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    at_exit do
      $stdout = original
      next if $!

      paths = (1...shards).map { |k| ShardOutput.shard_path(out_dir, symbol, k) }.select { |p| File.file?(p) }
      decls = File.join(out_dir, "#{symbol}_decls.h")
      paths << decls if File.file?(decls)
      entry = File.join(out_dir, "#{symbol}_entry.h")
      keep = File.file?(entry) ? File.read(entry).scan(IDENT).to_set : Set.new
      main, *rest = rewrite([buffer.string, *paths.map { |p| File.read(p) }], keep: keep)
      paths.zip(rest).each { |path, text| File.write(path, text) }
      original.write(main)
    end
  end

  # The texts (one program's translation units and headers) with the converted functions' state parameter dropped.
  def rewrite(texts, keep: Set.new)
    infos = texts.map { |t| scan(t) }
    names = converted(texts, infos, keep)
    texts.zip(infos).map { |text, info| apply(text, info, names) }
  end

  # Namespace-level function heads whose first parameter is the state.
  def scan(text)
    lines = text.lines
    scan = ShardOutput.scan_lines(lines)
    stack = []
    heads = []
    others = Set.new
    lines.each_index do |i|
      info = scan[i]
      code = info[:code].to_s
      depth = info[:depth]
      stack = stack.first(depth) + Array.new([depth - stack.size, 0].max) { :other }
      at_ns = stack.none? { |k| k == :other }
      if at_ns && !info[:pp] && (m = HEAD.match(code))
        head = parse_head(lines, scan, i, m)
        heads << head.merge(ns: stack.join('_')) if head
      elsif at_ns && !info[:pp] && (m = ANY_HEAD.match(code))
        others << m[:name]
      end
      next if info[:pp]

      next_depth = i + 1 < lines.size ? scan[i + 1][:depth] : depth
      next unless next_depth > depth

      opener = code[/\A\s*(?:inline\s+)?namespace\s+([\w@$:]*)\s*\{\s*\z/, 1]
      opener = opener.tr('@:', '__') if opener
      opener ||= 'extern_c' if code.match?(/\A\s*extern\s+\{\s*\z/)
      kind = at_ns && opener ? "ns_#{opener}" : :other
      (next_depth - depth).times { |k| stack << (k.zero? ? kind : :other) }
    end
    { lines: lines, scan: scan, heads: heads, others: others }
  end

  # The head that `m` starts on line i: the parameter text after the state up to its `)`, and what follows it.
  def parse_head(lines, scan, i, m)
    name_at = m.begin(:name)
    col = name_at + m[:name].size + 1
    depth = 1
    j = i
    params = String.new
    loop do
      code = scan[j][:code].to_s
      while col < code.size
        c = code[col]
        depth += 1 if c == '('
        depth -= 1 if c == ')'
        break if depth.zero?

        params << c
        col += 1
      end
      break if depth.zero?

      params << ' '
      j += 1
      col = 0
      return nil if j >= lines.size || scan[j][:pp]
    end
    after = scan[j][:code].to_s[(col + 1)..].to_s
    kind = { '{' => :def, ';' => :decl }[after.lstrip[0]]
    if after.strip.empty? && j + 1 < lines.size && scan[j + 1][:code].to_s.lstrip.start_with?('{')
      kind = :def
      open = [j + 1, scan[j + 1][:code].index('{')]
    elsif kind == :def
      open = [j, col + 1 + after.index('{')]
    end
    state = params.match(STATE_PARAM)
    { line: i, name: m[:name], name_at: name_at, pre: m[:pre], params: params[state[0].size..].sub(/\A\s*,\s*/, '').strip,
      named: !state[1].nil?, kind: kind, close: [j, col], open: open }
  end

  def top_level_args(params)
    return [] if params.strip.empty? || params.strip == 'void'

    args = [String.new]
    depth = 0
    params.each_char do |c|
      depth += 1 if '(<['.include?(c)
      depth -= 1 if ')>]'.include?(c)
      c == ',' && depth.zero? ? args << String.new : args.last << c
    end
    args.map(&:strip)
  end

  # Names to convert: defined here, every declaration convertible, no overload without the state, and never named
  # but as a call.
  def converted(texts, infos, keep)
    by_name = infos.flat_map { |info| info[:heads].map { |h| [h, info] } }.group_by { |h, _| h[:name] }
    others = infos.map { |info| info[:others] }.reduce(Set.new, :|)
    non_call = Set.new
    texts.each do |text|
      ShardOutput.code_text(text.lines).scan(/(?<![\w$])(#{IDENT})(\s*\()?/o) { non_call << Regexp.last_match(1) unless Regexp.last_match(2) }
    end
    by_name.select do |name, list|
      next false if keep.include?(name) || non_call.include?(name) || others.include?(name) || STORE_NAMES.include?(name)

      list.any? { |h, _| h[:kind] == :def } && list.all? { |h, info| h[:kind] && convertible?(h, info) }
    end.keys.to_set
  end

  def convertible?(head, info)
    return false if head[:pre].match?(/\b(?:template|extern|typedef|using|friend|constexpr|operator)\b|always_inline|BC2CPP_HOT_INLINE/)

    prev = (head[:line] - 1).downto(0).lazy.map { |k| info[:scan][k][:code].to_s.strip }.find { |c| !c.empty? }
    return false if prev&.match?(/\Atemplate\b/) && !prev.end_with?(';', '}')

    args = top_level_args(head[:params])
    args.none? { |a| a.match?(/[(=]/) } && args[0...-1].none? { |a| a == '...' }
  end

  BUILTIN = %w[int bool char void long short unsigned signed float double].to_set
  QUALIFIERS = %w[const volatile struct class enum union].to_set

  # [type, name or nil] of one parameter's text (no function-pointer or defaulted parameter reaches here).
  def split_param(arg)
    tokens = arg.scan(/<[^<>]*>|[A-Za-z_$][\w$]*|::|[*&]+|\[[^\]]*\]/)
    last = tokens.last
    named = last&.match?(/\A[A-Za-z_$]/) && !BUILTIN.include?(last) &&
            tokens[0...-1].any? { |t| !QUALIFIERS.include?(t) && t != '::' }
    return [arg.strip, nil] unless named

    [arg.sub(/(?<![\w$])#{Regexp.escape(last)}\s*\z/, '').strip, last]
  end

  def apply(text, info, names)
    lines = info[:lines].map(&:dup)
    inserts = Hash.new { |h, k| h[k] = String.new }
    info[:heads].each do |head|
      if names.include?(head[:name])
        inserts[head[:line]] << forwarder(head, info)
        insert_after_open!(lines, head, 'BC2CPP_IMPLICIT_M') if head[:kind] == :def && head[:named]
        drop_state!(lines, head)
      elsif head[:kind] == :def && head[:named]
        store = STORE_NAMES.include?(head[:name]) || head[:pre].match?(/\bextern\b/)
        insert_after_open!(lines, head, store ? 'bc2cpp_implicit_state = M;' : 'BC2CPP_STATE_CHECK(M);')
      end
    end
    out = String.new
    # After a leading `#pragma once`, so the header stays guarded.
    out << lines.shift if lines.first&.start_with?('#pragma once')
    out << PRELUDE
    offset = info[:lines].size - lines.size
    lines.each_with_index do |line, k|
      i = k + offset
      out << inserts[i] if inserts.key?(i)
      out << line
    end
    out
  end

  # The converted declaration, then the overload that takes the state and passes the rest on: each parameter of the
  # declared type, so the call converts its arguments exactly as a direct one does.
  def forwarder(head, info)
    args = top_level_args(head[:params])
    variadic = args.last == '...'
    args.pop if variadic
    types = args.map { |a| split_param(a).first }
    key = Digest::SHA256.hexdigest("#{head[:ns]}\n#{head[:name]}\n#{types.map { |t| t.sub(/\Astruct\s+/, '').gsub(/\s+/, '') }.join(',')}\n#{variadic}")[0, 16]
    params = ['mrb_state* bc2cpp_m', *types.each_with_index.map { |t, k| "#{t} bc2cpp_a#{k}" }]
    names = types.each_index.map { |k| "bc2cpp_a#{k}" }
    if variadic
      params << 'R... bc2cpp_r'
      names << 'bc2cpp_r...'
    end
    template = variadic ? 'template <class... R> ' : ''
    decl = "#{info[:lines][head[:line]][0, head[:name_at]]}#{head[:name]}(#{head[:params]})".lstrip
    "#ifndef BC2CPP_IMPLICIT_FWD_#{key}\n#define BC2CPP_IMPLICIT_FWD_#{key}\n#{decl};\n" \
      "#{template}[[gnu::always_inline]] static inline decltype(auto) #{head[:name]}(#{params.join(', ')}) " \
      "{ BC2CPP_STATE_CHECK(bc2cpp_m); return #{head[:name]}(#{names.join(', ')}); }\n#endif\n"
  end

  # Before drop_state!: the body brace's column is the scanned one.
  def insert_after_open!(lines, head, stmt)
    j, col = head[:open]
    raise "IMPLICIT_STATE: no body brace for #{head[:name]}" unless col && lines[j][col] == '{'

    lines[j] = "#{lines[j][0..col]} #{stmt}#{lines[j][(col + 1)..]}"
  end

  def drop_state!(lines, head)
    line = lines[head[:line]]
    at = head[:name_at] + head[:name].size + 1
    m = line[at..].match(/\A\s*mrb_state\s*\*\s*(?:M\b)?\s*(,\s*)?/)
    lines[head[:line]] = line[0...at] + line[(at + m[0].size)..]
  end
end
