#!/usr/bin/env ruby
# frozen_string_literal: true

# Check CAPTURED_LOCAL_CLASS (docs/adr/0308): a block reads a local of an enclosing frame through GETUPVAR, and the
# exact-class flow answers the class the defining frame stored there (the frame's state at the creating BLOCK joined
# with every value it stores afterwards), so `acc[i] = acc.size` in `3.times { }` drops its class test and its
# by-name dispatch when `acc` is a literal.
#
# 1. Generated code (needs MRBC): the positives lose their guard and dispatch; each negative keeps it (an argument, a
#    join of two classes, a store after the block exists, a store inside a block); each withdrawal (binding,
#    local_variable_set, eval, a string instance_eval, outside Ruby or native naming one, a singleton maker, the kill
#    switch, the open world) keeps the guard of an otherwise exact read.
# 2. Behaviour on real mruby: compiled answers equal interpreted ones, including a block that outlives a reassignment
#    of the local, a nil-then-array local and a frozen Array. Run it on a full-core and a core-only mruby, and with
#    BC2CPP_CXXFLAGS="-DMRB_32BIT -DMRB_INT32" on a 32-bit mrb_int build.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/captured_local_class_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

HOLDER = <<~RUBY
  class CaHolder
    # -- positives: the local is assigned a literal in the defining method and only read or mutated by blocks
    def cap_hash; h = {}; 3.times { |i| h[i] = h.size }; h; end
    def cap_array; a = [10, 20, 30]; out = {}; 3.times { |i| out[i] = a.size + a.first }; out; end
    def cap_string; s = 'abc'; out = {}; 2.times { |i| out[i] = s.size }; out; end
    def cap_nested; acc = {}; 2.times { |i| 2.times { |j| acc[i * 2 + j] = acc.size } }; acc; end
    def cap_each; seen = {}; [1, 2, 2, 3].each { |x| seen[x] = seen.size }; seen; end
    def cap_two_blocks; h = {}; 2.times { |i| h[i] = h.size }; 2.times { |i| h[i + 5] = h.size }; h; end
    # A frame-confined lambda reads the frame's register through a pointer, like a block.
    def cap_lambda_exact; acc = {}; line = ->(n) { acc[n] = acc.size }; line.call(0); line.call(1); acc; end
    # An unused reassignment of the same class keeps the set exact.
    def cap_same_class; h = {}; h = { z: 1 } if h.empty?; 2.times { |i| h[i] = h.size }; h; end
    # nil first, an Array later: nil or exactly Array, so the nil arm raises NoMethodError on its own.
    # Block-free methods: the only ones a core-only mruby (no mrblib, so no Integer#times or Array#each) can run.
    def plain_nil(flag); acc = nil; acc = [1, 2] if flag; acc.size; end
    def plain_frozen; acc = [].freeze; acc.push(1); end
    def cap_nil(flag); acc = nil; acc = [1, 2] if flag; r = nil; 1.times { r = acc.size }; r; end

    # -- negatives: no single class
    def cap_arg(a); out = {}; 2.times { |i| out[i] = a.size }; out; end
    def cap_mixed(flag); v = [1, 2]; v = { a: 1, b: 2, c: 3 } if flag; out = {}; 2.times { |i| out[i] = v.size }; out; end
    # The owner reassigns after the closure of the previous iteration exists.
    def cap_late
      acc = [1]
      out = {}
      n = 0
      while n < 2
        1.times { |i| out[n] = acc.size }
        acc = { a: 1, b: 2 }
        n += 1
      end
      out
    end
    def cap_block_write; acc = [1]; out = {}; 2.times { |i| out[i] = acc.size; acc = { a: 1, b: 2 } }; out; end
    # The lambda is created while acc is a Hash and called after it became an Array.
    def cap_lambda_late; acc = { a: 1 }; line = ->(n) { acc.size + n }; a = line.call(0); acc = [1, 2, 3]; b = line.call(1); [a, b]; end
    def cap_sibling_write; acc = [1]; out = {}; 2.times { |i| out[i] = acc.size }; 1.times { acc = { a: 1, b: 2 } }; out; end
    def cap_block_param(rows); out = {}; rows.each { |row| 2.times { |i| out[i] = row.size } }; out; end
    def cap_unknown_call(src); acc = src.first; out = {}; 2.times { |i| out[i] = acc.size }; out; end
    def cap_frozen; acc = [].freeze; r = {}; 2.times { |i| r[i] = acc.size }; acc.push(1); r; end
    def cap_subclass; acc = CaSub.new; acc << 5; out = {}; 2.times { |i| out[i] = acc.size }; out; end
  end

  class CaSub < Array; end

  class CaDrv
    def go(h)
      [h.cap_arg([1, 2, 3]), h.cap_arg({ a: 1 }), h.cap_arg('abcd'),
       h.cap_mixed(true), h.cap_mixed(false),
       h.cap_unknown_call([[1, 2]]), h.cap_unknown_call([{ q: 1 }]),
       h.cap_nil(true)]
    end

    def go_blocks(h); h.cap_block_param([[1], { a: 1, b: 2 }, 'xyz']); end
  end
RUBY

OWNERS = %w[CaHolder CaSub CaDrv].freeze
POSITIVES = %w[cap_hash cap_array cap_string cap_nested cap_two_blocks cap_each cap_same_class cap_lambda_exact].freeze
NEGATIVES = %w[cap_arg cap_mixed cap_late cap_lambda_late cap_block_write cap_sibling_write cap_block_param cap_unknown_call cap_subclass].freeze

# The method's own body plus the functions its blocks were outlined into.
bodies_of = lambda do |code, owner, fn|
  code.scan(/^(?:static )?mrb_value #{owner}_#{fn}(?:_\w*?)?_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end
live_of = ->(code, owner, fn) { bodies_of.call(code, owner, fn).lines.reject { |l| l.lstrip.start_with?('//') }.join }
# No class test on the receiver and no by-name dispatch left anywhere in the method and its blocks.
unguarded = lambda do |code, owner, fn|
  body = live_of.call(code, owner, fn)
  !body.empty? && !body.include?('bc2cpp_send(') && !body.include?('mrb_funcall(') && !body.include?('bc2cpp_getidx(') &&
    !body.include?('bc2cpp_setidx(') && !body.include?('->c == M->') && !body.include?('switch (mrb_type(')
end
guarded = lambda do |code, owner, fn|
  body = live_of.call(code, owner, fn)
  !body.empty? && (body.include?('bc2cpp_send(') || body.include?('bc2cpp_getidx(') || body.include?('bc2cpp_setidx(') || body.include?('->c == M->') || body.include?('switch (mrb_type('))
end

generate = lambda do |source, dir, closed: true, env: {}, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(source, dir, closed: closed, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

# -- 1. generated code -----------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, = generate.call(HOLDER, dir)

    POSITIVES.each do |fn|
      check.call("CaHolder##{fn}: a captured literal takes no class test and no by-name dispatch", unguarded.call(code, 'CaHolder', fn))
    end
    NEGATIVES.each do |fn|
      check.call("NEG CaHolder##{fn}: keeps the class test or the dispatch", guarded.call(code, 'CaHolder', fn))
    end
    check.call('CaHolder#cap_frozen: the push stays the checked call (FrozenError path kept)',
               live_of.call(code, 'CaHolder', 'cap_frozen').include?('ARRAY_PUSH') || guarded.call(code, 'CaHolder', 'cap_frozen'))

    # Withdrawal conditions: each variant world keeps the guard of an otherwise exact captured read.
    gem_dir = lambda do |root, name, files|
      File.join(root, name).tap do |gem|
        files.each { |rel, text| FileUtils.mkdir_p(File.dirname(File.join(gem, rel))) && File.write(File.join(gem, rel), text) }
      end
    end
    variants = {
      'a binding' => { extra: "class CaBind\n  def peek; binding; end\nend\n" },
      'a local_variable_set' => { extra: "class CaBind\n  def poke(b); b.local_variable_set(:x, 1); end\nend\n" },
      'an eval' => { extra: "class CaBind\n  def run; eval('1'); end\nend\n" },
      'a string class_eval' => { extra: "class CaBind\n  def run(c); c.class_eval('1'); end\nend\n" },
      'a binding named by a symbol' => { extra: "class CaBind\n  def peek; send(:binding); end\nend\n" },
      'a singleton maker' => { extra: "class CaBind\n  def run(x); x.extend(Comparable); end\nend\n" },
      'a build gem with a native local_variable_set' =>
        { gem: ['ca_native_gem', { 'src/ca.c' => "void ca_init(void) { mrb_define_method(0, 0, \"local_variable_set\", 0, 0); }\n" }] },
      'a build gem with a native binding' =>
        { gem: ['ca_binding_gem', { 'src/ca.c' => "void ca_init(void) { mrb_define_method(0, 0, \"binding\", 0, 0); }\n" }] },
      'a build gem whose mrblib spells binding' => { gem: ['ca_ruby_gem', { 'mrblib/ca.rb' => "module CaOut\n  def self.peek; binding; end\nend\n" }] }
    }
    variants.each do |what, spec|
      d = File.join(dir, what.gsub(/\W+/, '_'))
      Dir.mkdir(d)
      gems = spec[:gem] ? [[spec[:gem][0], gem_dir.call(d, *spec[:gem])]] : []
      vcode, = generate.call(HOLDER + spec.fetch(:extra, ''), d, build_gems: gems)
      verdict = %w[cap_hash cap_array cap_string].all? { |fn| guarded.call(vcode, 'CaHolder', fn) }
      check.call("NEG #{what}: withdrawn as the model says", verdict)
    end

    # A rebinding send with a literal block is not an eval of text.
    Dir.mktmpdir do |bd|
      bcode, = generate.call(HOLDER + "class CaBind\n  def run(c); c.class_eval { 1 }; end\nend\n", bd)
      check.call('a class_eval with a literal block does not withdraw the proof', unguarded.call(bcode, 'CaHolder', 'cap_hash'))
    end

    # Outside Ruby or a build gem without a way to write a local leaves the proof alone.
    Dir.mktmpdir do |gd|
      gem = gem_dir.call(gd, 'ca_plain_gem', 'src/ca.c' => "void ca_init(void) {}\n", 'mrblib/ca.rb' => "module CaPlain\n  def self.x; 1; end\nend\n")
      pcode, = generate.call(HOLDER, gd, build_gems: [['ca_plain_gem', gem]])
      check.call('an unrelated build gem does not withdraw the proof', unguarded.call(pcode, 'CaHolder', 'cap_hash'))
    end

    Dir.mktmpdir do |off_dir|
      off_code, = generate.call(HOLDER, off_dir, env: { 'BC2CPP_CAPTURED_LOCAL_CLASS' => '0' })
      check.call('the kill switch (BC2CPP_CAPTURED_LOCAL_CLASS=0): the old guards on every captured read',
                 %w[cap_hash cap_array cap_string cap_nested cap_two_blocks cap_each cap_lambda_exact].all? { |fn| guarded.call(off_code, 'CaHolder', fn) })
    end

    Dir.mktmpdir do |pool_dir|
      pool_code, = generate.call(HOLDER, pool_dir, env: { 'BC2CPP_CLASS_POOLS' => '0' })
      check.call('the class-pool kill switch leaves the flow of a captured literal in place',
                 unguarded.call(pool_code, 'CaHolder', 'cap_hash'))
    end

    Dir.mktmpdir do |open_dir|
      open_code, = generate.call(HOLDER, open_dir, closed: false)
      check.call('the open world proves nothing about a captured local', guarded.call(open_code, 'CaHolder', 'cap_hash'))
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 2. behaviour ----------------------------------------------------------------------

builds = { 'full-core' => runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil), 'core-only' => runtime.core }.compact
builds['full-core'] = runtime.full_or_build if builds.empty?
builds.compact!
if ENV['MRBC'] && !builds.empty? && runtime.compiler? && !ENV['CAL_GENERATED_ONLY']
  puts '== fixture on real mruby, interpreted and compiled'
  all_zero_arg = %w[cap_hash cap_array cap_string cap_nested cap_two_blocks cap_each cap_same_class cap_lambda_exact cap_lambda_late cap_late cap_block_write cap_sibling_write cap_frozen cap_subclass]
  # A block outlined inside another block and a confined lambda run through a thunk that stores a function pointer in an
  # mrb_int sized slot: that cannot work when a 64-bit host is built with MRB_INT32, so the 32-bit run leaves those out.
  narrow = ENV['BC2CPP_CXXFLAGS'].to_s.include?('MRB_INT32')
  all_zero_arg -= %w[cap_nested cap_lambda_exact cap_lambda_late] if narrow
  scenario_for = lambda do |with_blocks|
    zero_arg = with_blocks ? all_zero_arg : []
    calls = zero_arg.map { |m| "  call(M, \"#{m}\", holder, \"#{m}\");" }.join("\n")
    block_calls = if with_blocks
                    <<~CALLS
                      call(M, "cap_nil_true", holder, "cap_nil", 1, &yes);
                      call(M, "cap_nil_false", holder, "cap_nil", 1, &no);
                      call(M, "driver", drv, "go", 1, &holder);
                      #{narrow ? '' : 'call(M, "driver_blocks", drv, "go_blocks", 1, &holder);'}
                    CALLS
                  else
                    ''
                  end
    <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value holder = mrb_obj_new(M, mrb_class_get(M, "CaHolder"), 0, nullptr);
        mrb_value drv = mrb_obj_new(M, mrb_class_get(M, "CaDrv"), 0, nullptr);
        mrb_value yes = mrb_true_value();
        mrb_value no = mrb_false_value();
      #{calls}
        call(M, "plain_nil_true", holder, "plain_nil", 1, &yes);
        call(M, "plain_nil_false", holder, "plain_nil", 1, &no);
        call(M, "plain_frozen", holder, "plain_frozen");
      #{block_calls}
        return 0;
      }
    CPP
  end
  worlds = {
    'plain world' => '',
    'a binding in the world' => "class CaBind\n  def peek; binding; end\nend\n"
  }
  builds.each do |build_name, build|
    full = File.exist?("#{build}/lib/libmruby.a")
    worlds.each do |world, extra|
      label = "#{build_name}, #{world}"
      Dir.mktmpdir do |dir|
        _code, err = generate.call(HOLDER + extra, dir)
        built, output = runtime.run(dir, err, OWNERS, scenario_for.call(build_name != 'core-only'), build: build, full: full)
        check.call("#{label}: the fixture compiles and runs against real mruby", built)
        puts output unless built
        next unless built

        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
        check.call("#{label}: every method answers what the interpreter answers (#{values.call('interpreted').size} lines), values and exceptions alike",
                   !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
        compiled = values.call('compiled')
        next unless extra.empty?

        # A core-only mruby (no mrblib) reports a different exception class on both sides, so there the check is the
        # interpreter's own answer, and that it raised; full-core pins NoMethodError.
        nil_line = ->(lines) { lines.find { |l| l.start_with?('plain_nil_false =>') }.to_s }
        expected_nil = build_name == 'core-only' ? nil_line.call(values.call('interpreted')) : 'plain_nil_false => raised NoMethodError'
        nil_ok = nil_line.call(compiled) == expected_nil && expected_nil.include?('raised') && compiled.include?('plain_nil_true => 2')
        puts "    expected #{expected_nil.inspect}, actual #{nil_line.call(compiled).inspect}" unless nil_ok
        check.call("#{label}: a nil receiver raises, as the interpreter does", nil_ok)
        check.call("#{label}: a frozen Array still raises on push", compiled.include?('plain_frozen => raised FrozenError'))
        next if build_name == 'core-only'

        check.call("#{label}: the captured hash grows by its own size", compiled.include?('cap_hash => {0 => 0, 1 => 1, 2 => 2}'))
        check.call("#{label}: an owner that reassigns between two closures sees the new class in the second", compiled.include?('cap_late => {0 => 1, 1 => 2}'))
        check.call("#{label}: a block-side reassignment is seen by the next iteration", compiled.include?('cap_block_write => {0 => 1, 1 => 2}'))
        check.call("#{label}: a confined lambda called after the local changed class sees the new class", compiled.include?('cap_lambda_late => [1, 4]')) unless narrow
        check.call("#{label}: the frozen Array still raises on push in a block", compiled.include?('cap_frozen => raised FrozenError'))
        check.call("#{label}: a captured nil receiver raises NoMethodError", compiled.include?('cap_nil_false => raised NoMethodError') &&
                                                                              compiled.include?('cap_nil_true => 2'))
        lines = sections.fetch('compiled', [])
        (%w[cap_hash cap_array cap_string cap_nested cap_two_blocks cap_each cap_same_class cap_lambda_exact] - (narrow ? %w[cap_nested cap_lambda_exact] : [])).each do |m|
          at = lines.index { |l| l.start_with?("#{m} =>") }
          n = at && lines[at + 1].to_s[/dispatches=(\d+)/, 1]&.to_i
          check.call("#{label}: #{m}: the compiled call makes no dynamic dispatch", n == 0)
        end
      end
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
end

if failures.empty?
  puts 'bc2cpp captured local class check: PASS'
else
  warn "bc2cpp captured local class check: #{failures.size} failure(s)"
  exit 1
end
