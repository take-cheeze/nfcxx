#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates tools/bc2cpp/hot_methods.txt, the profile the flash-limited
# builds' BC2CPP_HOT_ONLY mode compiles (docs/adr/0214), from callgrind runs
# of the desktop RPGMAKER_BC2CPP=1 binary. Two steps:
#
#   ruby scripts/bc2cpp/hot_profile.rb record --binary build/rpg_maker_clone \
#        --out /tmp/hot --game NEPHESHEL_DIR [--game OTHER_RPG2K_DIR ...]
#     Runs every scenario below under `valgrind --tool=callgrind` (headless:
#     xvfb-run, SDL_AUDIODRIVER=dummy), one callgrind.<scenario>.out each. The
#     first --game is the main game (every scenario); every further one only
#     boots into its first map. The binary must be a full-compile build (no
#     BC2CPP_HOT_ONLY) so every compiled method can show up.
#
#   ruby scripts/bc2cpp/hot_profile.rb select --gen-dir build/mruby/host/mrbgems \
#        [--threshold 0.98] /tmp/hot/callgrind.*.out > tools/bc2cpp/hot_methods.txt
#     Sums self Ir per compiled method over every profile and takes the
#     smallest set covering at least --threshold of all compiled-code Ir.
#     To that set it adds the #initialize of each class (see
#     with_initializers) and, to a fixpoint, every keyword-call or `super`
#     target, since those have no dynamic fallback (see
#     with_required_calls). --report prints the threshold tradeoff table to
#     stderr and writes the per-method Ir/call table to
#     $TMPDIR/bc2cpp_hot_profile_ir.tsv. docs/profiling.md has the whole
#     procedure.
#
# Self Ir is attributed by source line of the generated *_gen.cpp, to the
# method whose cpp_name prefixes the enclosing function (its _impl, entry and
# helpers): -O3 inlining would make a symbol-level count miss inlined methods.

require 'fileutils'
require 'optparse'
require 'set'
require 'shellwords'
require 'tmpdir'

module HotProfile
  # One callgrind profile, reduced to what selection needs.
  class Profile
    attr_reader :line_ir, :fn_ir, :calls
    attr_accessor :total

    def initialize
      @line_ir = Hash.new(0) # [file, line] -> self Ir
      @fn_ir = Hash.new(0)   # [fn, file] -> self Ir (all files)
      @calls = Hash.new(0)   # fn -> calls into it
      @total = 0
    end
  end

  module_function

  # Parses the callgrind format (compressed names and positions) for self Ir.
  def parse_callgrind(path)
    prof = Profile.new
    names = { 'fl' => {}, 'fn' => {} }
    fl = fi = fn = cfn = nil
    last = 0
    call_pending = false
    decode = lambda do |kind, rest|
      table = names[kind]
      if (m = rest.match(/\A\((\d+)\)(?: (.*))?\z/))
        m[2] ? (table[m[1]] = m[2]) : table.fetch(m[1])
      else
        rest
      end
    end
    File.foreach(path, chomp: true, encoding: 'BINARY') do |line|
      case line
      when /\A(fl|fi|fe)=(.*)\z/
        kind = Regexp.last_match(1)
        name = decode.call('fl', Regexp.last_match(2))
        kind == 'fl' ? (fl = fi = name) : (fi = name)
      when /\Afn=(.*)\z/
        fn = decode.call('fn', Regexp.last_match(1))
        fi = fl
      when /\Ac(?:fl|fi|fe)=(.*)\z/
        decode.call('fl', Regexp.last_match(1))
      when /\Acfn=(.*)\z/
        cfn = decode.call('fn', Regexp.last_match(1))
      when /\Acob=|\Aob=/
        next
      when /\Acalls=(\d+)/
        prof.calls[cfn] += Regexp.last_match(1).to_i
        call_pending = true
      when /\A([+\-*]?\d*)\s+(\d+)/
        pos = Regexp.last_match(1)
        ir = Regexp.last_match(2).to_i
        last = if pos == '*' then last
               elsif pos.start_with?('+', '-') then last + pos.to_i
               else pos.to_i
               end
        if call_pending
          call_pending = false
          next
        end
        prof.line_ir[[fi, last]] += ir
        prof.fn_ir[[fn, fi]] += ir
        prof.total += ir
      end
    end
    prof
  end

  # One compiled gem's generated file: every top-level function's line range
  # and the method each function belongs to.
  class GenFile
    attr_reader :path, :methods, :functions

    HEADER = /\A\/\/ (\S+#\S+) \(compiled from irep /
    # Generated bodies also put statements at column 0 (`if (...) {`).
    CONTROL = %w[if else for while switch do return catch try sizeof].freeze
    FUNC_START = /\A(?:static\s+|inline\s+|extern\s+"C"\s+)*[A-Za-z_][\w:<>*&\s]*?\b([A-Za-z_]\w*)\s*\(.*\{\s*\z/

    def initialize(path)
      @path = File.expand_path(path)
      @methods = {}   # cpp_name -> "Owner#name"
      @functions = [] # [name, first_line, last_line]
      lines = File.readlines(path, chomp: true, encoding: 'BINARY')
      lines.each_with_index do |l, i|
        next unless (m = l.match(HEADER))

        impl = lines[i + 1].to_s[/\Amrb_value (\w+)_impl\(/, 1]
        @methods[impl] = m[1] if impl
      end
      # A function runs up to the next one: generated bodies can carry a
      # column-0 `}` of their own, so the first one is not the end.
      starts = []
      lines.each_with_index do |l, i|
        m = l.match(FUNC_START)
        starts << [m[1], i + 1] if m && !CONTROL.include?(m[1]) && !l.start_with?('else', '}')
      end
      starts.each_with_index do |(name, first), k|
        last = k + 1 < starts.size ? starts[k + 1][1] - 1 : lines.size
        @functions << [name, first, last]
      end
      by_length = @methods.keys.sort_by { |k| -k.size }
      @owner_of = {}
      # ATTR_STRUCT_DEVIRT's synthesized accessors (`Owner_ivar[_eq][_impl]`)
      # read and write the embedded struct. They exist only while the ivar
      # embeds, which needs the class's compiled #initialize, so their Ir is
      # credited to that #initialize: a record class like
      # RPG2k::Scene::Map::MapEventState has no hot bytecode method of its
      # own, but its accessors run per event per frame.
      synthesized = {}
      lines.each do |l|
        next unless (m = l.match(/\A\/\/ (\S+)#(\w+)=? -- synthesized attr_(?:reader|writer) override/))

        base = "#{m[1].gsub(/[^a-zA-Z0-9_]/, '_')}_#{m[2]}"
        [base, "#{base}_impl", "#{base}_eq", "#{base}_eq_impl"].each { |f| synthesized[f] = "#{m[1]}#initialize" }
      end
      @functions.each do |name, _, _|
        cpp = by_length.find { |k| name == k || name.start_with?("#{k}_") }
        @owner_of[name] = synthesized[name] || (@methods[cpp] if cpp)
      end
      @line_owner = []
      @functions.each { |name, a, b| (a..b).each { |ln| @line_owner[ln] = @owner_of[name] } }
      scan_required_calls(lines)
    end

    # method -> targets of its keyword calls and `super`s: they have no dynamic
    # form, so an uncompiled target leaves the caller uncompiled too.
    attr_reader :required

    def scan_required_calls(lines)
      @required = Hash.new { |h, k| h[k] = [] }
      lines.each_with_index do |l, i|
        owner = @line_owner[i + 1]
        next unless owner

        if (m = l.match(/\A\s*\/\/ \S+ :\S+ -> (\S+#\S+) \(keyword call/))
          @required[owner] << m[1]
        elsif (m = l.match(/\A\s+r\d+ = (\w+)_impl\(M, self\b/)) && !lines[i - 1].to_s.lstrip.start_with?('//')
          @required[owner] << m[1]
        end
      end
    end

    def method_at(line)
      @line_owner[line]
    end

    # `name` as callgrind spells it: the demangled C++ name, argument list
    # included (a lambda inside a function is `outer(...)::{lambda...}`).
    def method_of_function(name)
      name && @owner_of[name[/\A[^(]*/]]
    end
  end

  def gen_files(gen_dir)
    Dir[File.join(gen_dir, 'mruby-*-compiled', '*_gen.cpp')].sort.map { |p| GenFile.new(p) }
  end

  # Self Ir per "Owner#name" (and calls into each method's functions).
  def attribute(profiles, gens)
    by_path = gens.to_h { |g| [g.path, g] }
    ir = Hash.new(0)
    calls = Hash.new(0)
    total = 0
    profiles.each do |prof|
      total += prof.total
      prof.fn_ir.each do |(fn, file), cost|
        gen = file && by_path[File.expand_path(file)]
        next if gen # attributed by line below

        owner = gens.lazy.map { |g| g.method_of_function(fn) }.find(&:itself)
        ir[owner] += cost if owner
      end
      prof.line_ir.each do |(file, line), cost|
        gen = file && by_path[File.expand_path(file)]
        next unless gen

        owner = gen.method_at(line)
        ir[owner] += cost if owner
      end
      prof.calls.each do |fn, n|
        owner = gens.lazy.map { |g| g.method_of_function(fn) }.find(&:itself)
        calls[owner] += n if owner
      end
    end
    [ir, calls, total]
  end

  def select(ir, threshold)
    sum = ir.values.sum
    acc = 0
    ir.sort_by { |k, v| [-v, k] }.each_with_object([]) do |(k, v), out|
      break out if sum.positive? && acc >= threshold * sum

      out << k
      acc += v
    end
  end

  # Every hot method's class keeps its compiled #initialize: it allocates the
  # embedded-ivar struct, so excluding it would un-embed the class's hot ivars.
  def with_initializers(hot, compiled_methods)
    extra = hot.filter_map do |k|
      owner = k[/\A(.*)#/, 1]
      init = "#{owner}#initialize"
      init if !owner.end_with?('.singleton') && compiled_methods.include?(init)
    end
    (hot + extra).uniq
  end

  # Adds, to a fixpoint, every GenFile#required target of a listed method, which
  # would otherwise not compile.
  def with_required_calls(hot, gens)
    by_cpp = gens.each_with_object({}) { |g, h| h.merge!(g.methods) }
    known = by_cpp.values.to_set
    required = Hash.new { |h, k| h[k] = [] }
    gens.each { |g| g.required.each { |m, targets| required[m].concat(targets) } }
    out = hot.dup
    queue = hot.dup
    seen = hot.to_set
    until queue.empty?
      caller = queue.shift
      required[caller].each do |t|
        key = known.include?(t) ? t : by_cpp[t]
        # A bare self call is `super` only when it names the caller's method.
        next if key && !known.include?(t) && key[/#(.*)\z/, 1] != caller[/#(.*)\z/, 1]
        next unless key && seen.add?(key)

        out << key
        queue << key
      end
    end
    out
  end

  # Scenario driver, run inside the engine with --script. A frame is one
  # RPG2k#main_loop, so every scenario does a fixed amount of work regardless
  # of how slowly callgrind runs it (--timeout_ms is wall-clock).
  DRIVER = <<~'RUBY'
    game = RPG2k.new(ARGV)
    input = RGSS::Input
    step = lambda { |n| n.times { game.main_loop } }
    tap = lambda do |key, wait|
      input.press(key)
      game.main_loop
      input.release(key)
      step.call(wait)
    end
    scenes = lambda { game.instance_variable_get(:@scenes) }
    map_scene = lambda { scenes.call.find { |s| s.is_a?(RPG2k::Scene::Map) } }
    case HP_SCENARIO
    when 'walk_menu', 'walk'
      step.call(240)
      [input::DOWN, input::RIGHT, input::UP, input::LEFT, input::DOWN, input::LEFT].each do |k|
        input.press(k)
        step.call(48)
        input.release(k)
        step.call(8)
      end
      # The main menu's entries one by one: open, move down `i`, confirm into
      # the sub-screen, poke it, back out to the map. Opened the way the
      # cancel key does (Scene::Map#try_open_menu), since the game's opening
      # event may still hold the map or forbid the menu.
      6.times do |i|
        map = map_scene.call
        game.push(RPG2k::Scene::Menu.new(game, map.state)) if map && scenes.call.last.equal?(map)
        step.call(20)
        i.times { tap.call(input::DOWN, 6) }
        tap.call(input::C, 30)
        tap.call(input::C, 30)
        $stderr.puts "[HOTPROFILE] menu #{i}: #{scenes.call.map { |s| s.class }.inspect}"
        tap.call(input::DOWN, 10)
        tap.call(input::RIGHT, 10)
        tap.call(input::C, 30)
        4.times { tap.call(input::B, 12) }
      end
      step.call(HP_FRAMES)
    when 'save_load'
      step.call(240)
      map = map_scene.call
      game.save_game(map.state, 1) # Save01.lsd via State#to_lsd
      step.call(30)
      game.load_save_state(1) # Save01.lsd via Game::State.from_lsd

      game.continue_game(1) # Save01.lsd only: Game::State.from_lsd
      step.call(HP_FRAMES)
      map = map_scene.call
      game.save_game(map.state, 2) if map
      game.continue_game(2)
      step.call(60)
    else
      step.call(HP_FRAMES)
    end
    $stderr.puts "[HOTPROFILE] #{HP_SCENARIO} done: scenes=#{scenes.call.map { |s| s.class }.inspect}"
  RUBY

  # name => [game index (0: the main game, :each: every other game), frames, engine flags]
  SCENARIOS = {
    'map' => [0, 1800, %w[--rpg2k_new_game]],
    'battle1' => [0, 2400, %w[--rpg2k_battle_troop=1 --rpg2k_battle_play]],
    'battle6' => [0, 3600, %w[--rpg2k_battle_troop=6 --rpg2k_battle_play]],
    'walk_menu' => [0, 600, %w[--rpg2k_new_game]],
    'save_load' => [0, 600, %w[--rpg2k_new_game]],
    'animation' => [0, 600, %w[--rpg2k_preview_animation=1]],
    'boot' => [:each, 1200, %w[--rpg2k_new_game]],
    'walk' => [:each, 600, %w[--rpg2k_new_game]]
  }.freeze

  def record(binary:, out:, games:, only: nil, valgrind: true, server_num: nil)
    FileUtils.mkdir_p(out)
    main, *others = games.map { |g| File.expand_path(g) }
    work = Dir.mktmpdir('bc2cpp_hot_profile')
    # save_load writes Save01.lsd / save1.mrb into the game directory, so the
    # main game runs from a copy.
    main_copy = File.join(work, File.basename(main))
    FileUtils.cp_r(main, main_copy)
    runs = SCENARIOS.flat_map do |scenario, (which, frames, flags)|
      next [] if only && !only.include?(scenario)

      if which == :each
        others.each_with_index.map { |g, i| ["#{scenario}#{i + 1}", scenario, g, frames, flags] }
      else
        [[scenario, scenario, main_copy, frames, flags]]
      end
    end
    runs.each do |name, scenario, game, frames, flags|
      driver = File.join(work, "#{name}.rb")
      File.write(driver, "HP_SCENARIO = #{scenario.inspect}\nHP_FRAMES = #{frames}\n#{DRIVER}")
      prof = File.join(File.expand_path(out), "callgrind.#{name}.out")
      cmd = ['xvfb-run', server_num ? "--server-num=#{server_num}" : '-a']
      cmd += ['valgrind', '--tool=callgrind', "--callgrind-out-file=#{prof}"] if valgrind
      cmd += [File.expand_path(binary), '--game_dir', game, '--test_play', '--no_render_wait', *flags,
              "--script=#{driver}"]
      warn "== #{name}: #{Shellwords.join(cmd)}"
      log = File.join(File.expand_path(out), "#{name}.log")
      # Run from the scratch directory: a crash writes error-report.md to the
      # working directory.
      report = File.join(work, 'error-report.md')
      FileUtils.rm_f(report)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ok = system({ 'SDL_AUDIODRIVER' => 'dummy' }, *cmd, out: log, err: %i[child out], chdir: work)
      secs = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      done = File.read(log, encoding: 'BINARY').include?('[HOTPROFILE]')
      FileUtils.cp(report, File.join(File.expand_path(out), "#{name}.error-report.md")) if File.exist?(report)
      warn format('   %s in %.0fs (%s)', ok && done ? 'ok' : 'FAILED', secs, log)
    end
  ensure
    FileUtils.rm_rf(work) if work
  end
end

if $PROGRAM_NAME == __FILE__
  mode = ARGV.shift
  opts = { threshold: 0.98, games: [], report: false, initializers: true }
  parser = OptionParser.new do |o|
    o.on('--binary PATH') { |v| opts[:binary] = v }
    o.on('--out DIR') { |v| opts[:out] = v }
    o.on('--game DIR') { |v| opts[:games] << v }
    o.on('--only NAMES') { |v| opts[:only] = v.split(',') }
    o.on('--server-num N', Integer) { |v| opts[:server_num] = v }
    o.on('--gen-dir DIR') { |v| opts[:gen_dir] = v }
    o.on('--threshold F', Float) { |v| opts[:threshold] = v }
    o.on('--report') { opts[:report] = true }
    o.on('--[no-]initializers') { |v| opts[:initializers] = v }
  end
  files = parser.parse(ARGV)
  case mode
  when 'record'
    abort 'record needs --binary, --out and at least one --game' unless opts[:binary] && opts[:out] && opts[:games].any?
    HotProfile.record(binary: opts[:binary], out: opts[:out], games: opts[:games], only: opts[:only],
                      server_num: opts[:server_num])
  when 'select'
    abort 'select needs --gen-dir and callgrind files' unless opts[:gen_dir] && files.any?
    gens = HotProfile.gen_files(opts[:gen_dir])
    abort "no mruby-*-compiled/*_gen.cpp under #{opts[:gen_dir]}" if gens.empty?
    profiles = files.map { |f| HotProfile.parse_callgrind(f) }
    ir, calls, total = HotProfile.attribute(profiles, gens)
    compiled = ir.values.sum
    all_methods = gens.flat_map { |g| g.methods.values }.uniq
    expand = lambda do |set|
      with_init = opts[:initializers] ? HotProfile.with_initializers(set, all_methods.to_set) : set
      [with_init, HotProfile.with_required_calls(with_init, gens)]
    end
    by_ir = HotProfile.select(ir, opts[:threshold])
    with_init, hot = expand.call(by_ir)
    if opts[:report]
      warn format('profiles: %d, total Ir %d, compiled-code Ir %d (%.1f%%), %d of %d compiled methods executed',
                  files.size, total, compiled, 100.0 * compiled / total, ir.size, all_methods.size)
      [0.98, 0.99, 0.995, 0.997, 0.999, 1.0].each do |t|
        set = HotProfile.select(ir, t)
        init, full = expand.call(set)
        warn format('  threshold %5.1f%%: %4d by Ir + %d initializers + %d required callees = %d, %.3f%% of compiled Ir',
                    100 * t, set.size, init.size - set.size, full.size - init.size, full.size,
                    100.0 * full.sum { |k| ir[k] } / compiled)
      end
    end
    puts '# tools/bc2cpp/hot_methods.txt -- the methods BC2CPP_HOT_ONLY builds compile to C++'
    puts '# (docs/adr/0214). Generated by scripts/bc2cpp/hot_profile.rb from'
    puts "# #{files.size} callgrind profile(s): #{files.map { |f| File.basename(f) }.join(' ')}"
    puts format('# %d of %d compiled methods: %d covering %.1f%% of compiled-code Ir, %d #initialize of',
                hot.size, all_methods.size, by_ir.size, 100 * opts[:threshold], with_init.size - by_ir.size)
    puts "# their classes (so their ivars can stay embedded), #{hot.size - with_init.size} keyword/super callees"
    puts '# those need to compile at all. Every method not listed stays mruby bytecode on those builds.'
    hot.sort.each { |k| puts k }
    if opts[:report]
      File.write(File.join(Dir.tmpdir, 'bc2cpp_hot_profile_ir.tsv'),
                 ir.sort_by { |k, v| [-v, k] }.map { |k, v| "#{k}\t#{v}\t#{calls[k]}\n" }.join)
    end
  else
    abort "usage: #{$PROGRAM_NAME} record|select [options] -- see the header comment"
  end
end
