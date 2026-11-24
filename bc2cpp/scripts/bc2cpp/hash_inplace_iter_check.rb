#!/usr/bin/env ruby
# frozen_string_literal: true

# HASH_INPLACE_ITER (tools/bc2cpp/hash_inplace_iter.rb): inlined Hash#each/#each_value/#each_key loops, and Array loops
# over `hash.values`/`hash.keys`, read the Hash into a C buffer instead of building the keys/values Arrays. The
# generated part checks which sites take the snapshot, which absorb their `values`/`keys` send and which are refused,
# and that BC2CPP_HASH_INPLACE_ITER=0 keeps the Arrays. The runtime part runs every site interpreted and compiled
# (small and large Hashes, a body that deletes, adds and overwrites entries and runs the GC, break/next/return, a nil
# receiver) and compares the output, also with BC2CPP_HASH_INPLACE_ITER_VERIFY=1. Needs MRBC; the runtime part also
# needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and a C++ compiler).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

SOURCE = <<~RUBY
  class HiItem
    def initialize(n) = (@n = n)
    def n = @n
    def big? = @n > 10
    def bump = (@n += 1)
  end
  class HiFx
    def initialize(size)
      @h = {}
      size.times { |i| @h[i] = HiItem.new(i) }
      @routes = { a: nil, b: nil }
    end

    def reset(size)
      @h = {}
      size.times { |i| @h[i] = HiItem.new(i) }
    end

    def bump_all
      @h.each_value { |it| it.bump }
      @h.size
    end

    def sum_values
      s = 0
      @h.each_value { |it| s += it.n }
      s
    end

    def pairs
      out = []
      @h.each { |k, v| out << [k, v.n] }
      out
    end

    def key_list
      out = []
      @h.each_key { |k| out << k }
      out
    end

    def mutate_each
      out = []
      @h.each do |k, v|
        @h.delete(k + 1)
        @h[k + 100] = HiItem.new(k + 100) if k < 3
        @h[k + 2] = HiItem.new(-1) if @h.key?(k + 2)
        GC.start
        out << [k, v.n]
      end
      [out, @h.size]
    end

    def mutate_values
      out = []
      @h.each_value do |v|
        @h.clear
        GC.start
        out << v.n
      end
      out
    end

    def mutate_keys
      out = []
      @h.each_key do |k|
        @h.delete(k + 1)
        GC.start
        out << k
      end
      out
    end

    def first_big_value
      found = nil
      @h.each_value do |v|
        next unless v.big?
        found = v.n
        break
      end
      found
    end

    def early_return
      @h.each { |k, v| return [:at, k] if v.n == 2 }
      :none
    end

    def any_big = @h.values.any? { |v| v.big? }
    def any_big_sym = @h.values.any?(&:big?)
    def all_small = @h.values.all? { |v| !v.big? }
    def none_big = @h.values.none? { |v| v.big? }
    def count_big = @h.values.count { |v| v.big? }
    def find_big = @h.values.find { |v| v.big? }&.n
    def map_n = @h.values.map { |v| v.n }
    def map_sym = @h.values.map(&:n)
    def select_keys = @h.keys.select { |k| k.odd? }
    def reject_keys = @h.keys.reject { |k| k.odd? }
    def routes_idle = !@routes.values.any? { |r| r }
    def maybe_values = @maybe.values.any? { |r| r }
    def fill_maybe(n) = (@maybe = { 1 => nil, 2 => n })
    def any_mutating = @h.values.any? { |v| @h.delete(v.n + 1); GC.start; v.n > 5 }

    # Refused: `each` returns the values Array, and a value held in a local is not the instruction before the block.
    def each_values
      n = 0
      @h.values.each { |v| n += v.n }
      n
    end

    def held_values
      vals = @h.values
      vals.any? { |v| v.big? }
    end
  end
RUBY

DRIVER = <<~'RUBY'
  show = lambda do |label, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{label}: #{out}"
  end
  [3, 40].each do |size|
    fx = HiFx.new(size)
    show.call("#{size} bump") { fx.bump_all }
    show.call("#{size} sum") { fx.sum_values }
    show.call("#{size} pairs") { fx.pairs }
    show.call("#{size} keys") { fx.key_list }
    show.call("#{size} first big") { fx.first_big_value }
    show.call("#{size} return") { fx.early_return }
    show.call("#{size} any") { fx.any_big }
    show.call("#{size} any sym") { fx.any_big_sym }
    show.call("#{size} all") { fx.all_small }
    show.call("#{size} none") { fx.none_big }
    show.call("#{size} count") { fx.count_big }
    show.call("#{size} find") { fx.find_big }
    show.call("#{size} map") { fx.map_n }
    show.call("#{size} map sym") { fx.map_sym }
    show.call("#{size} select keys") { fx.select_keys }
    show.call("#{size} reject keys") { fx.reject_keys }
    show.call("#{size} each values") { fx.each_values }
    show.call("#{size} held values") { fx.held_values }
    show.call("#{size} routes") { fx.routes_idle }
    show.call("#{size} nil values") { fx.maybe_values }
    fx.fill_maybe(size)
    show.call("#{size} maybe values") { fx.maybe_values }
    show.call("#{size} mutate each") { fx.mutate_each }
    fx.reset(size)
    show.call("#{size} mutate values") { fx.mutate_values }
    fx.reset(size)
    show.call("#{size} mutate keys") { fx.mutate_keys }
    fx.reset(size)
    show.call("#{size} any mutating") { fx.any_mutating }
    fx.reset(size)
    show.call("#{size} after") { fx.pairs.size }
  end
  puts 'end'
RUBY

SNAPSHOT = {
  'bump_all' => 'values', 'sum_values' => 'values', 'pairs' => 'pairs', 'key_list' => 'keys',
  'mutate_each' => 'pairs', 'mutate_values' => 'values', 'mutate_keys' => 'keys', 'first_big_value' => 'values',
  'early_return' => 'pairs', 'any_big' => 'values', 'any_big_sym' => 'values', 'all_small' => 'values',
  'none_big' => 'values', 'count_big' => 'values', 'find_big' => 'values', 'map_n' => 'values',
  'map_sym' => 'values', 'select_keys' => 'keys', 'reject_keys' => 'keys', 'routes_idle' => 'values',
  'maybe_values' => 'values', 'any_mutating' => 'values'
}.freeze
ABSORBED = %w[any_big any_big_sym all_small none_big count_big find_big map_n map_sym select_keys reject_keys
              routes_idle maybe_values any_mutating].freeze
REFUSED = %w[each_values held_values].freeze

if ENV['MRBC'].nil?
  puts '  SKIP hash in-place iteration check: set MRBC'
  exit 0
end

body = ->(code, name) { code[/^mrb_value HiFx_#{Regexp.escape(name)}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value |\z)/m].to_s }
generate = lambda do |dir, env|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  FileUtils.mkdir_p(dir)
  Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: %w[HiFx HiItem])
ensure
  saved&.each { |k, v| ENV[k] = v }
end

Dir.mktmpdir('bc2cpp-hash-inplace-iter') do |dir|
  code, err = generate.call(dir, {})
  SNAPSHOT.each do |name, mode|
    text = body.call(code, name)
    check.call("#{name}: the loop reads a #{mode} snapshot", text.include?("// HASH_INPLACE_ITER #{mode}"))
    check.call("#{name}: no keys/values Array is built", !text.match?(/mrb_hash_(?:keys|values)\(/))
  end
  ABSORBED.each do |name|
    check.call("#{name}: the values/keys send is absorbed", body.call(code, name).include?('absorbed #'))
  end
  REFUSED.each do |name|
    text = body.call(code, name)
    check.call("#{name}: refused, the values Array is kept",
               text.include?('mrb_hash_values(') && !text.include?('HASH_INPLACE_ITER'))
  end
  check.call('the nil receiver keeps the send NoMethodError', body.call(code, 'maybe_values').include?('nil-receiver: values'))

  # A Ruby Hash#keys answers `keys` instead of the C method, so its send is not absorbed.
  overridden = Dir.mktmpdir('bc2cpp-hash-inplace-iter-keys') do |odir|
    Bc2cppFixtureRuntime.generate("#{SOURCE}\nclass Hash\n  def keys = map { |k, _| k }\nend\n", odir, core: true,
                                  only_owners: %w[HiFx HiItem]).first
  end
  check.call('a Ruby Hash#keys keeps the keys send', !body.call(overridden, 'select_keys').include?('absorbed #') &&
                                                     body.call(overridden, 'any_big').include?('absorbed #values'))

  off, = generate.call(File.join(dir, 'off'), { 'BC2CPP_HASH_INPLACE_ITER' => '0' })
  check.call('BC2CPP_HASH_INPLACE_ITER=0 takes no snapshot', !off.include?('HASH_INPLACE_ITER'))
  check.call('BC2CPP_HASH_INPLACE_ITER=0 keeps the Arrays', body.call(off, 'pairs').include?('mrb_hash_keys(') &&
                                                            body.call(off, 'any_big').include?('mrb_hash_values('))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP hash in-place iteration behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and ' \
         '3rd/mruby)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"HID(#{DRIVER})HID";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    [['', dir, err], ['verify ', File.join(dir, 'verify'), nil]].each do |tag, run_dir, run_err|
      run_err ||= generate.call(run_dir, { 'BC2CPP_HASH_INPLACE_ITER_VERIFY' => '1' })[1]
      built, output = Bc2cppFixtureRuntime.run(run_dir, run_err, %w[HiFx HiItem], scenario, build: build, full: true)
      check.call("#{tag}fixture builds and runs", built)
      sections = Bc2cppFixtureRuntime.sections(output)
      interpreted = sections['interpreted']
      compiled = sections['compiled']
      check.call("#{tag}both runs reach the end", interpreted&.last == 'end' && compiled&.last == 'end')
      check.call("#{tag}interpreted and compiled runs print the same", interpreted == compiled)
      interpreted.to_a.zip(compiled.to_a).reject { |a, b| a == b }.first(10).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
      check.call("#{tag}a mutated Hash yields its snapshot", interpreted.to_a.include?('3 mutate values: [0, 1, 2]'))
      puts output.lines.last(30).join unless built && interpreted && compiled
    end
  end
end

if failures.empty?
  puts 'bc2cpp hash in-place iteration check: PASS'
else
  warn "bc2cpp hash in-place iteration check: #{failures.size} failure(s)"
  exit 1
end
