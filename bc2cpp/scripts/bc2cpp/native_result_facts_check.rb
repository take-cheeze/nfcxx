#!/usr/bin/env ruby
# frozen_string_literal: true

# NATIVE_RESULT_FACTS and INSTANCE_RECEIVER (docs/adr/0302).
#
# 1. Host only: every fact in tools/bc2cpp/native_result_facts.rb against the RGSS native sources.
#    The registration of (owner, name) is the pinned callee text, it is the only one, and every
#    `return` along the delegation chain has the shape the fact's kind promises. A native that starts
#    returning nil, a Float or another class fails here, not in a deployed build.
# 2. Host only: the ClosedWorld questions the flows ask (a native class constant that something
#    rebinds, a name another source defines, the class list a send's receiver is proven to hold).
# 3. With MRBC: the generated code of closed-world fixtures that compile against the real RGSS native
#    sources. Positive cases (an ivar-held Bitmap's `width` as a division operand, `text_size(..).width`
#    through a Bitmap of unknown class, a nil-or-Window receiver whose `.singleton` definer no longer
#    blocks the proven-dead fallback) lose their by-name fallback; negative cases (a Ruby override, a
#    rebound Rect constant, a singleton maker, an unproven receiver, a method_missing class) keep it.
#
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/native_result_facts_check.rb

require 'fileutils'
require 'open3'
require 'set'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/native_direct'
require_relative '../../tools/bc2cpp/native_result_facts'
require_relative '../../tools/bc2cpp/closed_world'
require_relative '../../tools/bc2cpp/closed_world_env'
require_relative '../../tools/bc2cpp/codegen'
require_relative '../../tools/bc2cpp/codegen_native_results'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# -- 1. the facts against the native sources -------------------------------------------------

puts '-- facts against mruby-rgss/src'
rgss_srcs = Dir[File.join(root, 'mruby-rgss/src/*.cxx')].sort
real_texts = rgss_srcs.to_h { |path| [path, NativeDirect.strip_comments(File.binread(path).force_encoding('UTF-8'))] }

# The text from `open` (an opening bracket at +from+) to its match, brackets included.
balanced = lambda do |text, from|
  depth = 0
  index = from
  while index < text.size
    case text[index]
    when '(', '{', '[' then depth += 1
    when ')', '}', ']'
      depth -= 1
      return text[from..index] if depth.zero?
    end
    index += 1
  end
  nil
end

OPENERS = ['(', '{', '['].freeze
CLOSERS = [')', '}', ']'].freeze

# The callee argument of a registration: up to the first top-level comma (a `<..>` argument list
# opened right after a word character is one token).
callee_at = lambda do |text, from|
  depth = 0
  angle = 0
  index = from
  while index < text.size
    ch = text[index]
    if depth.zero? && angle.zero? && ch == ','
      return text[from...index]
    elsif OPENERS.include?(ch)
      depth += 1
    elsif CLOSERS.include?(ch)
      depth -= 1
    elsif depth.zero? && ch == '<' && text[index - 1].match?(/\w/)
      angle += 1
    elsif depth.zero? && ch == '>' && angle.positive?
      angle -= 1
    end
    index += 1
  end
  nil
end

squash = ->(text) { text.gsub(/\s+/, ' ').strip }
returns_of = ->(body) { body.scan(/\breturn\b\s*([^;]*);/m).flatten.map { |expr| squash.call(expr) } }

shape = lambda do |kind|
  case kind
  when :fixnum then /\Amrb_fixnum_value\s*\(/
  when :float then /\Amrb_float_value\s*\(/
  when String
    mod, klass = kind.split('::')
    /\Amrb_obj_new\(\s*M,\s*mrb_class_get_under\(\s*M,\s*mrb_module_get\(\s*M,\s*"#{mod}"\s*\),\s*"#{klass}"\s*\),/
  end
end

# [[label, holds]] for every fact over `texts` (path => comment-stripped source).
audit = lambda do |texts, facts|
  all_text = texts.values.join("\n")
  # [owner, name] => [callee text, ...] over every mrb_define_method registration.
  registrations = Hash.new { |h, k| h[k] = [] }
  texts.each do |path, text|
    owners = NativeDirect.class_variables(text, NativeDirect.sibling_param_owners(path))
    text.scan(/\bmrb_define_method\s*\(\s*M\s*,\s*(\w+)\s*,\s*"((?:[^"\\\n]|\\.)*)"\s*,\s*/m) do |var, name|
      callee = callee_at.call(text, Regexp.last_match.end(0))
      registrations[[owners[var], name]] << squash.call(callee) if callee
    end
  end
  # The one body of `function` in the sources, brackets included.
  body_of = lambda do |function|
    spots = all_text.enum_for(:scan, /\bmrb_value\s+#{Regexp.escape(function)}\s*\(/).map { Regexp.last_match.end(0) - 1 }
    bodies = spots.filter_map do |open|
      params = balanced.call(all_text, open)
      brace = params && all_text[open + params.size..].match(/\A\s*\{/)
      brace ? balanced.call(all_text, open + params.size + brace[0].size - 1) : nil
    end
    bodies.size == 1 ? bodies.first : nil
  end

  results = []
  facts.each do |owner, names|
    names.each do |name, fact|
      label = "#{owner}##{name} (#{NativeResultFacts.kind(name, owner).inspect})"
      results << ["#{label}: registered once, as the pinned callee", registrations[[owner, name]] == [squash.call(fact.callee)]]

      chain = fact.chain
      if fact.callee.start_with?('[')
        callee_returns = returns_of.call(fact.callee)
        delegate = /\A(?:rgss::)?#{Regexp.escape(chain.first)}\s*\(/
        results << ["#{label}: the lambda only returns what #{chain.first} returns",
                    !callee_returns.empty? && callee_returns.all? { |expr| expr.match?(delegate) }]
      elsif !fact.callee.start_with?(chain.first)
        results << ["#{label}: the callee names the chain's first function", false]
      end
      chain.each_cons(2) do |from, to|
        returns = returns_of.call(body_of.call(from) || '')
        results << ["#{label}: every return of #{from} is a call of #{to}",
                    !returns.empty? && returns.all? { |expr| expr.match?(/\A(?:rgss::)?#{Regexp.escape(to)}\s*\(/) }]
      end
      root_body = body_of.call(chain.last)
      root_returns = root_body ? returns_of.call(root_body) : []
      results << ["#{label}: #{chain.last} has one definition and every return has the kind's shape",
                  !root_returns.empty? && root_returns.all? { |expr| expr.match?(shape.call(NativeResultFacts.kind(name, owner))) }]
    end
  end
  results
end

audit.call(real_texts, NativeResultFacts::FACTS).each { |what, holds| check.call(what, holds) }
all_text = real_texts.values.join("\n")

# The audit must fail when a native changes shape: each mutant edits one return or registration.
mutate = lambda do |from, to|
  mutated = real_texts.transform_values { |text| text.sub(from, to) }
  raise "mutation target not found: #{from}" if mutated == real_texts

  mutated
end
mutants = {
  'Bitmap#width returning nil' => [/return mrb_fixnum_value\(bmp_self\(M, self\)\.width\);/, 'return mrb_nil_value();'],
  'Bitmap#width returning a Float' => [/return mrb_fixnum_value\(bmp_self\(M, self\)\.width\);/,
                                       'return mrb_float_value(M, bmp_self(M, self).width);'],
  'Rect#x delegating elsewhere' => ['return rgss::rect_x_direct(M, self);', 'return rgss::rect_y_direct(M, self);'],
  'Color#red bound to another function' => ['"red", component_get<Color, &Color::red>', '"red", color_red_other'],
  'component_get returning nil' => ['return mrb_float_value(M, DataType<T>::get(M, self).*Field);', 'return mrb_nil_value();'],
  'Bitmap#rect building another class' => ['mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Rect"), 4, args);',
                                           'mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Color"), 4, args);'],
  'a second Bitmap#width registration' => ['mrb_define_method(M, bmp, "width", bmp_width, MRB_ARGS_NONE());',
                                           'mrb_define_method(M, bmp, "width", bmp_width, MRB_ARGS_NONE()); ' \
                                           'mrb_define_method(M, bmp, "width", bmp_height, MRB_ARGS_NONE());']
}
mutants.each do |what, (from, to)|
  broken = audit.call(mutate.call(from, to), NativeResultFacts::FACTS).reject { |_label, holds| holds }
  check.call("the audit rejects a mutant: #{what}", !broken.empty?)
end

check.call('the Rect class a text_size/rect result names is defined once by the natives',
           all_text.scan(/mrb_define_class_under\(\s*M\s*,\s*\w+\s*,\s*"Rect"/).size == 1)
inert = NativeResultFacts::FACTS.flat_map do |owner, names|
  names.keys.reject { |name| NativeDirect.registration_count(name, owner, rgss_srcs) == 1 }.map { |name| "#{owner}##{name}" }
end
puts "  info #{inert.empty? ? 'every fact names a unique parsed registration' : "not a unique parsed registration (never consumed): #{inert.join(' ')}"}"

# -- 2. ClosedWorld ---------------------------------------------------------------------------

puts '-- ClosedWorld questions'
Dir.mktmpdir do |dir|
  rgss_dir = File.join(dir, 'mruby-rgss/src')
  FileUtils.mkdir_p(rgss_dir)
  native = File.join(rgss_dir, 'lib.cxx')
  File.write(native, <<~CXX)
    void init(mrb_state* M) {
      RClass* m = mrb_define_module(M, "RGSS");
      RClass* r = mrb_define_class_under(M, m, "Rect", M->object_class);
      mrb_define_method(M, r, "width", f, MRB_ARGS_NONE());
    }
  CXX
  make = lambda do |natives, ruby = [], decls = {}|
    ClosedWorld.new(ireps: {}, registry: {}, class_decls: decls, walked: Set.new, native_paths: natives, ruby_paths: ruby)
  end
  world = make.call([native])
  check.call('a class defined once by a native is a stable constant', world.native_class_constant_stable?('RGSS::Rect'))
  check.call('a name only the RGSS natives define is visible to them',
             world.name_visible_except_natives_in?('width', '/mruby-rgss/src/'))
  check.call('a name nothing defines is visible too', world.name_visible_except_natives_in?('height', '/mruby-rgss/src/'))

  other = File.join(dir, 'other.c')
  File.write(other, 'void g(mrb_state* M, RClass* k) { mrb_define_method(M, k, "width", f, MRB_ARGS_NONE()); }')
  world = make.call([native, other])
  check.call('a registration from another file makes the name invisible to the RGSS natives',
             !world.name_visible_except_natives_in?('width', '/mruby-rgss/src/'))

  File.write(File.join(dir, 'defs.rb'), "class Elsewhere\n  def width; 1; end\nend\n")
  world = make.call([native], [File.join(dir, 'defs.rb')])
  check.call('an outside Ruby definition makes it invisible too', !world.name_visible_except_natives_in?('width', '/mruby-rgss/src/'))

  File.write(File.join(dir, 'rebind.rb'), "RGSS::Rect = Object\n")
  world = make.call([native], [File.join(dir, 'rebind.rb')])
  check.call('an outside Ruby `Rect =` makes the native constant unstable', !world.native_class_constant_stable?('RGSS::Rect'))

  second = File.join(rgss_dir, 'second.cxx')
  File.write(second, 'void h(mrb_state* M, RClass* m) { mrb_const_set(M, mrb_obj_value(m), mrb_intern_lit(M, "Rect"), v); }')
  world = make.call([native, second])
  check.call('a native const_set of the name makes it unstable', !world.native_class_constant_stable?('RGSS::Rect'))

  File.write(second, 'void h(mrb_state* M, RClass* m) { mrb_define_class_under(M, m, "Rect", M->object_class); }')
  world = make.call([native, second])
  check.call('a second native definition makes it unstable', !world.native_class_constant_stable?('RGSS::Rect'))

  decl = { 'Win' => [{ super: :none, outer_nil: true }], 'Mod' => [{ super: 'Module', outer_nil: true }] }
  mm_registry = { 'method_missing' => [Struct.new(:owner, :irep, :name, :kind, :visibility).new('Ghost', 1, 'method_missing', :def, :public)] }
  world = ClosedWorld.new(ireps: {}, registry: {}, class_decls: decl, walked: Set.new, native_paths: [], ruby_paths: [])
  check.call('a declared class that is not a Module is an instance class', world.instance_class?('Win'))
  check.call('a class derived from Module is not', !world.instance_class?('Mod'))
  check.call('an undeclared class is not', !world.instance_class?('Nope'))
  check.call('a method_missing-free world is free for any class list', world.send(:method_missing_free?, nil, %w[Win]))
  world = ClosedWorld.new(ireps: {}, registry: mm_registry, class_decls: decl.merge('Ghost' => [{ super: :none, outer_nil: true }]),
                          walked: Set.new, native_paths: [], ruby_paths: [])
  check.call('a class list holding a method_missing class is not free', !world.send(:method_missing_free?, nil, %w[Win Ghost]))
  check.call('a class list without one is free even in a world that has one', world.send(:method_missing_free?, nil, %w[Win]))
  check.call('no class list and no self is not free', !world.send(:method_missing_free?, nil))
end

# -- Native result receiver snapshots ---------------------------------------------------------

puts '-- native result receiver snapshots'
probe_class = Class.new(CodeGen) do
  attr_reader :lookups

  def initialize(kinds = {}, nil_raises = false)
    @kinds = kinds
    @nil_raises = nil_raises
    @lookups = []
  end

  def native_result_kind(name, klass)
    @lookups << [name, klass]
    @kinds[[name, klass]]
  end

  def nil_unanswerable?(_name)
    @nil_raises
  end
end
probe = probe_class.new
check.call('a core-only snapshot is shared', probe.native_result_class_bits.equal?(probe.native_result_class_bits))
first_bit = probe.numeric_class_bit('First')
first = probe.native_result_class_bits
check.call('an unchanged class table reuses its snapshot', first.equal?(probe.native_result_class_bits))
probe.numeric_class_bit('Second')
second = probe.native_result_class_bits
check.call('growth replaces the snapshot without changing an active snapshot',
           !second.equal?(first) && first.first[0, 2] == ['First', first_bit] && !first.any? { |klass, _| klass == 'Second' })
check.call('snapshots and their entries are immutable', second.frozen? && second.all?(&:frozen?))
check.call('entry positions identify the single class bit', second.all? { |_, bit, position| bit == 1 << position })
replacement = probe.instance_variable_get(:@numeric_class_bits).transform_keys { |klass| klass == 'First' ? 'Replacement' : klass }
probe.instance_variable_set(:@numeric_class_bits, replacement)
check.call('a replacement table is read even with the same size as an old snapshot',
           probe.native_result_class_bits.first[0, 2] == ['Replacement', first_bit])
before_probe = probe.native_result_class_bits
probe.without_probe_side_effects do
  probe.numeric_class_bit('Transient')
  probe.native_result_class_bits
end
check.call('probe rollback restores class entries without retaining transient entries',
           probe.native_result_class_bits == before_probe && !probe.native_result_class_bits.any? { |klass, _| klass == 'Transient' })

# Receiver-member indexes must follow probe table identity as well as lazy growth.
member_probe = probe_class.new
member_bits = 10.times.map { |index| member_probe.numeric_class_bit("Member#{index}") }
member_pair = member_bits[0] | member_bits[1]
check.call('member masks decode in allocation order', member_probe.numeric_receiver_class_bits(member_pair) == member_bits.first(2))
check.call('member snapshots are reused and immutable', member_probe.numeric_receiver_class_bits(member_pair).equal?(member_probe.numeric_receiver_class_bits(member_pair)) && member_probe.numeric_receiver_class_bits(member_pair).frozen?)
check.call('zero, negative and noninteger member masks are refused', [0, -1, nil].all? { |mask| member_probe.numeric_receiver_class_bits(mask).nil? })
check.call('core and provenance bits never become user members', [NumericFlow::INT, NumericFlow::CHECKED, NumericFlow::OTHER].all? { |mask| member_probe.numeric_receiver_class_bits(member_pair | mask).nil? })
check.call('the original eight-member limit is retained', member_probe.numeric_receiver_class_bits(member_bits.first(8).reduce(0, :|)) == member_bits.first(8) && member_probe.numeric_receiver_class_bits(member_bits.first(9).reduce(0, :|)).nil?)
future_bit = member_bits.last << 1
check.call('an unregistered bit is refused', member_probe.numeric_receiver_class_bits(future_bit).nil?)
check.call('lazy registration withdraws a cached refusal', member_probe.numeric_class_bit('FutureMember') == future_bit && member_probe.numeric_receiver_class_bits(future_bit) == [future_bit])
member_table = member_probe.instance_variable_get(:@numeric_class_bits).transform_keys { |name| name == 'Member0' ? 'RenamedMember' : name }
member_probe.instance_variable_set(:@numeric_class_bits, member_table)
check.call('same-size replacement updates inverse names', member_probe.return_class_name_of_bit(member_bits.first) == 'RenamedMember')
member_probe.without_probe_side_effects do
  transient = member_probe.numeric_class_bit('TransientMember')
  member_probe.numeric_receiver_class_bits(transient)
  member_probe.return_class_name_of_bit(transient)
end
next_bit = future_bit << 1
check.call('probe rollback removes transient member and name entries', member_probe.numeric_receiver_class_bits(next_bit).nil? && member_probe.return_class_name_of_bit(next_bit).nil?)
check.call('a reused bit after rollback receives its new name', member_probe.numeric_class_bit('AfterRollback') == next_bit && member_probe.return_class_name_of_bit(next_bit) == 'AfterRollback')
member_rng = Random.new(52_23)
check.call('randomized member queries match the original full-table scan', 1000.times.all? do
  mask = (member_bits + [future_bit, NumericFlow::NIL, NumericFlow::CHECKED]).sample(member_rng.rand(14), random: member_rng).reduce(0, :|)
  table = member_probe.instance_variable_get(:@numeric_class_bits)
  expected = table.values.select { |bit| mask.anybits?(bit) }
  expected = nil unless mask.positive? && (1..8).cover?(expected.size) && expected.reduce(0, :|) == mask
  member_probe.numeric_receiver_class_bits(mask) == expected
end)
2500.times { |value| member_probe.numeric_receiver_class_bits((1 << 400) | (value << 20)) }
check.call('member decoding cache stays bounded', member_probe.numeric_class_member_index[3].size == CodeGen::CLASS_MEMBER_CACHE_LIMIT)
puts 'receiver member index growth, rollback, ordering and refusal checks passed'

# The pre-optimization algorithm is the reference for results, lookup order and class-bit allocation.
reference = lambda do |cg, name, recv, classes|
  next nil unless recv.is_a?(Integer)

  mask = 0
  rest = recv
  found = false
  entries = (cg.instance_variable_get(:@numeric_class_bits) || {}).to_a + CodeGen::RETURN_CORE_CLASS.map { |bit, klass| [klass, bit] }
  entries.each do |klass, bit|
    next unless recv.anybits?(bit)

    rest &= ~bit
    kind = cg.native_result_kind(name, klass)
    found ||= !kind.nil?
    mask |= cg.native_result_bits(kind, classes)
  end
  next nil unless found

  rest &= ~NumericFlow::NIL if cg.nil_unanswerable?(name)
  rest.zero? ? mask : mask | NumericFlow::OTHER
end
rng = Random.new(20_261_019)
choices = [:fixnum, :float, :nil, 'Result', [:fixnum, 'Result'], nil]
equivalent = 1_000.times.all? do
  kinds = (%w[First Second Third] + CodeGen::RETURN_CORE_CLASS.values).to_h { |klass| [['read', klass], choices.sample(random: rng)] }
  nil_raises = rng.rand(2).zero?
  old = probe_class.new(kinds, nil_raises)
  current = probe_class.new(kinds, nil_raises)
  rng.rand(80).times do |index|
    old.numeric_class_bit("Filler#{index}")
    current.numeric_class_bit("Filler#{index}")
  end
  bits = %w[First Second Third].map do |klass|
    bit = old.numeric_class_bit(klass)
    current.numeric_class_bit(klass)
    bit
  end
  candidates = bits + CodeGen::RETURN_CORE_CLASS.keys + [NumericFlow::NIL, NumericFlow::INT, NumericFlow::OTHER, old.numeric_class_bit('Unknown')]
  current.numeric_class_bit('Unknown')
  4.times.all? do
    recv = candidates.sample(rng.rand(candidates.size + 1), random: rng).reduce(0, :|)
    recv = ~recv if rng.rand(10).zero?
    classes = rng.rand(2).zero?
    expected = reference.call(old, 'read', recv, classes)
    got = current.native_result_flow_mask('read', recv, classes: classes)
    expected == got && old.lookups == current.lookups &&
      old.instance_variable_get(:@numeric_class_bits) == current.instance_variable_get(:@numeric_class_bits)
  end
end
check.call('4,000 randomized narrow/wide queries preserve masks, lookup order and discovered class bits', equivalent)
check.call('noninteger receiver masks still have no result', probe.native_result_flow_mask('read', nil).nil?)

mutating_class = Class.new(probe_class) do
  def native_result_kind(name, klass)
    numeric_class_bit('Discovered')
    native_result_class_bits
    super
  end
end
mutating = mutating_class.new({ ['read', 'First'] => :fixnum, ['read', 'Discovered'] => :float })
first_bit = mutating.numeric_class_bit('First')
future_bit = 1 << (NumericFlow::CLASS_BIT_BASE + 1)
check.call('class discovery during a query retains that query snapshot',
           mutating.native_result_flow_mask('read', first_bit | future_bit) == (NumericFlow::INT | NumericFlow::OTHER))
check.call('the next query sees a class discovered by the previous query',
           mutating.native_result_flow_mask('read', future_bit) == NumericFlow::FLT)

# -- 3. generated code ------------------------------------------------------------------------

if ENV['MRBC']
  puts '-- generated code'
  require_relative 'fixture_runtime'
  mrbc = ENV['MRBC']
  gems = NomethodReviewedProbe.closed_gems(root)
  native_srcs = rgss_srcs + core_native_srcs(File.join(root, '3rd/mruby')) + external_gem_native_srcs(root)
  generate = lambda do |source, name|
    Dir.mktmpdir do |dir|
      path = File.join(dir, "#{name}.rb")
      File.write(path, source)
      env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
              'NATIVE_SRCS' => Shellwords.join(native_srcs), 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(root)),
              'BC2CPP_BUILD_NAME' => 'closed',
              'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }) }
      out, err, status = Open3.capture3(bc2cpp_closed_world_probe_env(env), RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', path)
      abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
      out
    end
  end
  body_of_impl = lambda do |code, fn|
    code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
  end

  # The RGSS reopenings and `include RGSS` give `Bitmap` and friends the class-name proofs the
  # shipped Ruby has.
  PRELUDE = <<~'RUBY'
    module RGSS
      class Bitmap; end
      class Rect; end
      class Color; end
    end
    class Object
      include RGSS
    end
  RUBY

  # A second `width` whose result nothing proves: the name alone, which the natives' own facts would
  # otherwise carry, proves nothing, so a proof below is the receiver's class.
  UNKNOWN_WIDTH = <<~'RUBY'
    class NrOther
      def w=(v); @w = v; end
      def width; @w; end
    end
  RUBY

  WORLD = PRELUDE + UNKNOWN_WIDTH + <<~'RUBY'
    class NrBox
      def initialize
        @bmp = Bitmap.new(16, 16)
        @color = Color.new(1, 2, 3, 4)
      end
      def half; @bmp.width / 2; end
      def below; @bmp.height < 100; end
      def tint; @color.red * 2; end
      def label_width(bitmap, text); 1 + bitmap.text_size(text).width; end
    end
  RUBY

  code = generate.call(WORLD, 'nr_world')
  half = body_of_impl.call(code, 'NrBox_half')
  check.call('an ivar-held Bitmap#width is a proven Fixnum: the division has no check and no fallback',
             half.include?('operands proven Fixnum') && !half.include?('bc2cpp_slow_div') && !half.include?('bc2cpp_send(') &&
               !half.include?('mrb_div_float'))
  check.call('and the receiver is exact, so the call is the entry point with no class-guard chain',
             half.include?('NATIVE_EXACT_DIRECT :width -> RGSS::Bitmap') && !half.include?('POLY_SMALL_N'))
  below = body_of_impl.call(code, 'NrBox_below')
  check.call('Bitmap#height is a proven Fixnum for a comparison too',
             below.include?('NATIVE_EXACT_DIRECT :height') && !below.include?('bc2cpp_slow_lt('))
  tint = body_of_impl.call(code, 'NrBox_tint')
  check.call('Color#red is a Float: the product is proven numeric, not Fixnum, with no slow path',
             tint.include?('NUMERIC_OPERAND_PROOF') && !tint.include?('bc2cpp_slow_mul') && !tint.include?('operands proven Fixnum'))
  label = body_of_impl.call(code, 'NrBox_label_width')
  check.call('text_size is defined only by Bitmap, so its result is a Rect whatever the receiver: `.width` is exact',
             label.include?('NATIVE_EXACT_DIRECT :width -> RGSS::Rect') && label.include?('operands proven Fixnum'))
  check.call('and the sum has no by-name fallback', !label.include?('bc2cpp_slow_add'))
  check.call('the unproven receiver of text_size keeps its class guard and Bitmap owner-call fallback',
             label.match?(/native_bitmap_class\(\)\) \{\n\s*r\d+ = rgss::bitmap_text_size_direct[^\n]*\n\} else \{\n\s*r\d+ = bc2cpp_owner_call\([^\n]*BC2CPP_OWNERS\("RGSS::Bitmap"\)/))

  override = generate.call(PRELUDE.sub('class Bitmap; end', "class Bitmap\n    def width; 1.5; end\n  end") + <<~'RUBY', 'nr_override')
    class NrBox
      def initialize; @bmp = Bitmap.new(16, 16); end
      def half; @bmp.width / 2; end
    end
  RUBY
  half = body_of_impl.call(override, 'NrBox_half')
  check.call('a Ruby `Bitmap#width` voids the fact: the Ruby body is called, the entry point and the Fixnum proof are gone',
             half.include?('RGSS__Bitmap_width_impl') && !half.include?('NATIVE_EXACT_DIRECT') && !half.include?('operands proven Fixnum'))

  rebound = generate.call(PRELUDE + UNKNOWN_WIDTH + <<~'RUBY', 'nr_rebound')
    RGSS::Rect = Object
    class NrBox
      def label_width(bitmap, text); 1 + bitmap.text_size(text).width; end
    end
  RUBY
  label = body_of_impl.call(rebound, 'NrBox_label_width')
  check.call('a rebound Rect constant voids the class fact: the sum keeps its slow path',
             label.include?('bc2cpp_slow_add') && !label.include?('NATIVE_EXACT_DIRECT :width -> RGSS::Rect'))

  extended = generate.call(WORLD + "\nObject.new.extend(Comparable)\n", 'nr_extend')
  half = body_of_impl.call(extended, 'NrBox_half')
  check.call('a singleton maker anywhere withdraws every exact-class fact',
             half.include?('bc2cpp_slow_div') && !half.include?('NATIVE_EXACT_DIRECT'))

  unproven = generate.call(PRELUDE + UNKNOWN_WIDTH + <<~'RUBY', 'nr_unproven')
    class NrBox
      def half(bitmap); bitmap.width / 2; end
    end
  RUBY
  half = body_of_impl.call(unproven, 'NrBox_half')
  check.call('a receiver nothing proves keeps the class-guard chain and the slow path',
             half.include?('bc2cpp_slow_div') && half.include?('native_bitmap_class()') && !half.include?('NATIVE_EXACT_DIRECT'))

  mixed = generate.call(PRELUDE + UNKNOWN_WIDTH + <<~'RUBY', 'nr_mixed')
    class NrBox
      def initialize(flag)
        if flag
          @thing = Bitmap.new(1, 1)
        else
          @thing = NrOther.new
        end
      end
      def half; @thing.width / 2; end
    end
  RUBY
  half = body_of_impl.call(mixed, 'NrBox_half')
  check.call('a receiver that may be a second class gets no fact',
             half.include?('bc2cpp_slow_div') && !half.include?('NATIVE_EXACT_DIRECT') && !half.include?('operands proven Fixnum'))
  named = generate.call(PRELUDE + <<~'RUBY', 'nr_named')
    class NrBox
      def half(bitmap); bitmap.width / 2; end
    end
  RUBY
  half = body_of_impl.call(named, 'NrBox_half')
  check.call('with no other `width` anywhere the NAME is proven Integer, whatever the receiver',
             half.include?('NUMERIC_OPERAND_PROOF') && !half.include?('bc2cpp_slow_div'))

  # INSTANCE_RECEIVER: a `def self.width` next to instance readers of the same name.
  singleton_world = <<~'RUBY'
    class NrScreen
      def self.width; 640; end
    end
    class NrPane
      attr_reader :width
      def initialize; @width = 3; end
    end
    class NrPaneB
      attr_reader :width
      def initialize; @width = 4; end
    end
    class NrUse
      def initialize(flag)
        if flag
          @thing = NrPane.new
        else
          @thing = NrPaneB.new
        end
      end
      def read; @thing.width; end
      def read_open(x); x.width; end
      def read_class; NrScreen.width; end
    end
  RUBY
  code = generate.call(singleton_world, 'nr_instances')
  read = body_of_impl.call(code, 'NrUse_read')
  check.call('a receiver proven NrPane-or-NrPaneB ignores the singleton `width` of NrScreen: the fallback is the proven-dead nomethod',
             read.include?('/* CLOSED_WORLD nomethod: recv.width */') && !read.include?('kept: singleton_definer'))
  read = body_of_impl.call(code, 'NrUse_read_open')
  check.call('an unproven receiver could be NrScreen itself: the singleton definer keeps the dispatch',
             read.match?(/bc2cpp_owner_call\([^\n]*BC2CPP_OWNERS\([^\n]*"NrScreen\.singleton"/) && !read.include?('bc2cpp_nomethod'))
  read = body_of_impl.call(code, 'NrUse_read_class')
  check.call('a send to the class object itself is not an instance receiver', !read.include?('bc2cpp_nomethod'))

  ghost = generate.call(singleton_world + <<~'RUBY', 'nr_ghost')
    class NrGhost
      def method_missing(name, *args); name == :width ? 1 : super; end
    end
  RUBY
  check.call('a method_missing class elsewhere does not block a receiver proven not to be one',
             body_of_impl.call(ghost, 'NrUse_read').include?('/* CLOSED_WORLD nomethod: recv.width */'))
  check.call('but it still blocks the unproven receiver',
             !body_of_impl.call(ghost, 'NrUse_read_open').include?('bc2cpp_nomethod'))

  ghost_in_set = generate.call(singleton_world.sub('@thing = NrPaneB.new', '@thing = NrGhost.new') + <<~'RUBY', 'nr_ghost_set')
    class NrGhost
      def method_missing(name, *args); name == :width ? 1 : super; end
    end
  RUBY
  check.call('a receiver that may be the method_missing class keeps the dispatch',
             !body_of_impl.call(ghost_in_set, 'NrUse_read').include?('bc2cpp_nomethod'))
else
  puts '  SKIP generated code: set MRBC'
end

puts "\n#{failures.size} check(s) failed" unless failures.empty?
exit(failures.empty? ? 0 : 1)
