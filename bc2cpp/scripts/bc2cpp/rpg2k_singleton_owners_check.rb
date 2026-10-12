#!/usr/bin/env ruby
# frozen_string_literal: true

# Game::CommonEvent.singleton and Game::MoveRoute.singleton as compiled owners (docs/adr/0426), and the bare
# `new(a, k: v)` of a class method (KEYWORD_IMPLICIT_NEW) that Game::MoveRoute.from_page needs.
#
# The fixture is the engine's own source: Prism slices `module CommonEvent` and the two class methods
# `from_page` and `same_route?` out of mruby-rpg2k/mrblib/game.rb, so the check cannot drift from the
# code it stands for. Only what the real files give to those bodies is stubbed (MoveRoute#initialize with its
# keywords, command records).
#
# 1. With MRBC: the generated code of worlds that each add one way for the proof to change. Each world names the
#    sites that must be bound and those that must not.
# 2. With MRBC, BC2CPP_MRUBY_FULL and g++: the worlds run on real mruby, interpreted and compiled, and must answer
#    alike (values, exception classes, the messages a failed load or comparison writes to $stderr). A compiled
#    run also reports the by-name dispatches each call made; the bound calls must have made none of their own.
#
# RSO_WORLDS=w1,w2 limits the worlds; RSO_GENERATED_ONLY=1 skips part 2.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/rpg2k_singleton_owners_check.rb

require 'fileutils'
require 'json'
require 'open3'
require 'prism'
require 'tmpdir'
require_relative 'cxx'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless ENV['MRBC']
  puts '  SKIP generated code: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  puts 'bc2cpp_rpg2k_singleton_owners_check OK'
  exit 0
end

require_relative 'fixture_runtime'
runtime = Bc2cppFixtureRuntime
ROOT = runtime::ROOT
GAME_RB = File.join(ROOT, 'mruby-rpg2k/mrblib/game.rb')
# The engine's gems stay out of the closed world: the fixture carries the slices of them it exercises.
ENGINE_GEMS = %w[mruby-rpg2k-compiled mruby-lcf-compiled mruby-rgss-compiled mruby-core-compiled].freeze
TIME_GEM = [['mruby-time', "#{ROOT}/3rd/mruby/mrbgems/mruby-time"]].freeze
OWNERS = %w[Game::CommonEvent.singleton Game::CommonEvent::CommonEventRecord Game::MoveRoute Game::MoveRoute.singleton
            RsoCaller RsoSub RsoSubCaller].freeze

# [module source, from_page source, same_route? source] of the real game.rb.
slices = lambda do
  source = File.read(GAME_RB)
  tree = Prism.parse(source).value
  found = {}
  walk = lambda do |node, path|
    case node
    when Prism::ModuleNode, Prism::ClassNode
      path += [node.constant_path.slice]
      found[path.join('::')] = node
    when Prism::DefNode
      found["#{path.join('::')}.#{node.name}"] = node if node.receiver.is_a?(Prism::SelfNode)
    end
    node.compact_child_nodes.each { |child| walk.call(child, path) }
  end
  walk.call(tree, [])
  common = found.fetch('Game::CommonEvent')
  # The slice keeps its own indentation; the first line starts mid-line.
  text = lambda do |node|
    line_start = source.rindex("\n", node.location.start_offset - 1).to_i + 1
    source[line_start...node.location.end_offset]
  end
  [text.call(common), text.call(found.fetch('Game::MoveRoute.from_page')), text.call(found.fetch('Game::MoveRoute.same_route?'))]
end
COMMON_EVENT, FROM_PAGE, SAME_ROUTE = slices.call

# The real code needs nothing but these: records with the command accessors same_route? reads, and a
# MoveRoute whose #initialize declares the keywords from_page passes (the engine's has the same signature).
FIXTURE = <<~RUBY
  class RsoCmd
    attr_reader :command_id, :parameter_string, :parameter_a, :parameter_b, :parameter_c
    def initialize(id, s = '', a = 0, b = 0, c = 0)
      @command_id = id; @parameter_string = s; @parameter_a = a; @parameter_b = b; @parameter_c = c
    end
  end

  module Game
  #{COMMON_EVENT}
    class MoveRoute
      attr_reader :commands, :repeat, :skippable
      def initialize(commands, repeat: false, skippable: false)
        raise ArgumentError, 'bad command' if commands.include?(:bad)
        @commands = commands
        @repeat = repeat
        @skippable = skippable
      end

      # A bare `new` in an instance method is NoMethodError: the class-method rule must not reach it.
      def clone_with(cmds)
        new(cmds, repeat: @repeat)
      end

  #{FROM_PAGE}

  #{SAME_ROUTE}
    end
  end

  class RsoCaller
    # Blocks keep a caller interpreted, so the $stderr swap is a pair of calls around the one under test.
    def cap_start
      @old = $stderr
      $stderr = StringIO.new
    end

    def cap_end(value)
      text = $stderr.string
      $stderr = @old
      [value, text]
    end

    def records(list)
      list.map { |r| [r.id, r.trigger, r.need_flag, r.switch_id, r.commands, r.chunk] }
    end

    def db
      { common_event: {
        1 => { start_term: 3, need_flag: true, switch_id: 2, event: [:a] },
        2 => { start_term: 4, need_flag: false, switch_id: 0, event: [:b] },
        3 => { start_term: 5, need_flag: true, switch_id: 1, event: [:c] },
        4 => { start_term: 3, need_flag: false, switch_id: 9, event: nil }
      } }
    end

    def load_none; cap_start; cap_end(Game::CommonEvent.load({})); end
    def load_all; cap_start; cap_end(records(Game::CommonEvent.load(db))); end
    def load_not_a_db; cap_start; cap_end(Game::CommonEvent.load(Object.new)); end
    def load_bad_entry; cap_start; cap_end(Game::CommonEvent.load({ common_event: { 1 => nil } })); end

    def eligible(switches)
      cap_start
      cap_end(Game::CommonEvent.eligible(Game::CommonEvent.load(db), switches).map(&:id))
    end

    def route(cmds, repeat, skippable); { commands: cmds, repeat: repeat, skippable: skippable }; end

    def same(a, b); cap_start; cap_end(Game::MoveRoute.same_route?(a, b)); end
    def same_nil_nil; same(nil, nil); end
    def same_nil_route; same(nil, route([], false, false)); end
    def same_route_nil; same(route([], false, false), nil); end
    def same_repeat; same(route([], true, false), route([], false, false)); end
    def same_skippable; same(route([], false, true), route([], false, false)); end
    def same_equal; same(route([RsoCmd.new(1, 's', 2)], true, true), route([RsoCmd.new(1, 's', 2)], true, true)); end
    def same_size; same(route([RsoCmd.new(1)], true, true), route([RsoCmd.new(1), RsoCmd.new(2)], true, true)); end
    def same_id; same(route([RsoCmd.new(1)], true, true), route([RsoCmd.new(2)], true, true)); end
    def same_string; same(route([RsoCmd.new(1, 'a')], true, true), route([RsoCmd.new(1, 'b')], true, true)); end
    def same_a; same(route([RsoCmd.new(1, '', 1)], true, true), route([RsoCmd.new(1, '', 2)], true, true)); end
    def same_b; same(route([RsoCmd.new(1, '', 0, 1)], true, true), route([RsoCmd.new(1, '', 0, 2)], true, true)); end
    def same_c; same(route([RsoCmd.new(1, '', 0, 0, 1)], true, true), route([RsoCmd.new(1, '', 0, 0, 2)], true, true)); end
    def same_no_commands; same({ repeat: true, skippable: false }, { repeat: true, skippable: false }); end
    def same_broken; same(route([1], true, true), route([2], true, true)); end

    def summary(r)
      r.nil? ? nil : [r.class, r.commands, r.repeat, r.skippable]
    end

    def page(route); cap_start; cap_end(summary(Game::MoveRoute.from_page(route))); end
    def page_nil; page(nil); end
    def page_no_commands; page({ commands: nil }); end
    def page_empty; page({ commands: [] }); end
    def page_full; page(route([1, 2], true, false)); end
    def page_keywords_default; page({ commands: [3] }); end
    def page_not_a_route; page(Object.new); end
    def page_initialize_raises; page(route([:bad], true, true)); end
    def sub_clone; Game::MoveRoute.new([1]).clone_with([2]); rescue NoMethodError => e; e.class; end
  end
RUBY

# name => [extra Ruby, sites that must bind (site => marker), sites that must not (site => marker)].
# A site is "Class#method"; its marker is the text the generated body carries when it is bound.
LOAD_BOUND = 'MONO :load -> Game::CommonEvent.singleton#load'
SAME_BOUND = 'MONO :same_route? -> Game::MoveRoute.singleton#same_route?'
PAGE_BOUND = 'MONO :from_page -> Game::MoveRoute.singleton#from_page'
KEYWORD_NEW = 'MONO :new -> Game::MoveRoute, direct compiled construct with real KEYWORD arguments'
WORLDS = {
  'base' => {
    # The fixture's bare `new` in an instance method (NoMethodError at run time) is the one refusal.
    refused: %w[Game::MoveRoute#clone_with],
    extra: '',
    bound: { 'RsoCaller#load_all' => LOAD_BOUND, 'RsoCaller#same' => SAME_BOUND, 'RsoCaller#page' => PAGE_BOUND,
             'Game::MoveRoute.singleton#from_page' => KEYWORD_NEW },
    kept: { 'Game::MoveRoute#clone_with' => KEYWORD_NEW }
  },
  'a redefinition of the class method' => {
    refused: %w[Game::MoveRoute#clone_with],
    extra: "class Game::MoveRoute\n  def self.same_route?(a, b); :mine; end\nend\n",
    bound: { 'RsoCaller#load_all' => LOAD_BOUND, 'RsoCaller#page' => PAGE_BOUND },
    kept: { 'RsoCaller#same' => SAME_BOUND }
  },
  'an open world' => {
    # Without the closed world nothing says the class has no descendants.
    open: true,
    refused: %w[Game::MoveRoute#clone_with Game::MoveRoute.singleton#from_page],
    extra: '',
    kept: { 'Game::MoveRoute.singleton#from_page' => KEYWORD_NEW }
  },
  'a subclass inherits the class method' => {
    # The guard-miss arm of the construct cannot build a subclass's object, so a descendant refuses the route.
    refused: %w[Game::MoveRoute#clone_with Game::MoveRoute.singleton#from_page],
    extra: "class RsoSub < Game::MoveRoute\nend\nclass RsoSubCaller\n  def sub_page\n    old = $stderr\n    $stderr = StringIO.new\n    r = RsoSub.from_page({ commands: [1], repeat: true, skippable: true })\n    text = $stderr.string\n    $stderr = old\n    [[r.class, r.commands, r.repeat, r.skippable], text]\n  end\nend\n",
    bound: { 'RsoCaller#load_all' => LOAD_BOUND },
    kept: { 'Game::MoveRoute.singleton#from_page' => KEYWORD_NEW },
    cases: %w[sub_page]
  }
}.freeze

selected = ENV['RSO_WORLDS']&.split(',')&.map(&:strip)
worlds = WORLDS.select { |name, _| selected.nil? || selected.include?(name) }
if worlds.empty?
  puts "  FAIL no world named #{selected.inspect}"
  exit 1
end

# The generated function bodies of one site ("Game::MoveRoute.singleton#from_page" ->
# Game__MoveRoute_singleton_from_page): its _impl and the helpers it outlines (a rescue's try body, block bodies).
body_of = lambda do |code, site|
  fn = site.sub('#', '_').sub('.singleton_', '_singleton_').gsub('::', '__')
  header = /\A(?:static )?mrb_value #{Regexp.escape(fn)}_impl(?:_\w+)?\(mrb_state\* M/
  code.split(/^(?=(?:static )?mrb_value [\w$]+\(mrb_state\* M)/).grep(header).join
end

generated = {}
puts '-- generated code'
worlds.each do |name, world|
  Dir.mktmpdir do |dir|
    code, err = runtime.generate(FIXTURE + world[:extra], dir, only_owners: OWNERS, build_gems: TIME_GEM,
                                                                drop_gems: ENGINE_GEMS, skip_unsupported: false,
                                                                closed: !world[:open])
    generated[name] = [code, err]
    File.write(File.join(ENV['RSO_DUMP'], "#{name.tr(' ', '_')}.cpp"), code) if ENV['RSO_DUMP']
    File.write(File.join(ENV['RSO_DUMP'], "#{name.tr(' ', '_')}.err"), err) if ENV['RSO_DUMP']
  end
  code, = generated.fetch(name)
  puts "-- world: #{name}"
  refused = code.split(/^(?=(?:static )?mrb_value [\w$]+\(mrb_state\* M)/).select { |chunk| chunk.include?('#error') }
                .map { |chunk| chunk[/\A(?:static )?mrb_value ([\w$]+?)_impl/, 1] || chunk[/\A[^\n]*/] }.sort
  expected = (world[:refused] || []).map { |site| site.sub('#', '_').sub('.singleton_', '_singleton_').gsub('::', '__') }.sort
  check.call("#{name}: the compiler refuses #{(world[:refused] || []).join(', ')} and nothing else (got #{refused.inspect})",
             refused == expected)
  (world[:bound] || {}).each do |site, marker|
    body = body_of.call(code, site)
    check.call("#{name}: #{site} carries `#{marker}`", !body.empty? && body.include?(marker))
  end
  (world[:kept] || {}).each do |site, marker|
    body = body_of.call(code, site)
    check.call("#{name}: #{site} does not carry `#{marker}`", !body.empty? && !body.include?(marker))
  end
end

# The wiring around the generator: the owners list, the hand registration of a full build, and the hot-only builds
# (wio, psp, maix), which compile none of these methods and so spend no flash on the new owners.
if selected.nil? || selected.include?('base')
  puts '-- wiring'
  # The tools directory of the generator under test (a mutant copy under BC2CPP_TOOL), read in a child so its
  # constants cannot meet the ones fixture_runtime already loaded.
  tools = File.dirname(runtime::BC2CPP)
  gems_json, = Open3.capture2(RbConfig.ruby, '-rjson', '-e',
                              'require ARGV[0]; puts JSON.generate(gems: BC2CPP_COMPILED_GEMS.transform_values { |g| g[:owners] }, hot: BC2CPP_HOT_METHODS_PATH)',
                              File.join(tools, 'compiled_gems.rb'))
  wiring = JSON.parse(gems_json)
  METHODS = { 'Game::CommonEvent.singleton' => %w[load eligible], 'Game::MoveRoute.singleton' => %w[from_page same_route?] }.freeze
  owners = wiring.fetch('gems').fetch('mruby-rpg2k-compiled')
  METHODS.each_key do |owner|
    check.call("#{owner} is an owner of mruby-rpg2k-compiled", owners.include?(owner))
    check.call("#{owner} is an owner of no other compiled gem", wiring.fetch('gems').except('mruby-rpg2k-compiled').none? { |_, gem_owners| gem_owners.include?(owner) })
  end
  # RSO_REGISTER names a modified copy (the mutation check).
  register = File.read(ENV.fetch('RSO_REGISTER') { File.join(ROOT, 'mruby-rpg2k-compiled/src/register.cxx') })
  guarded = register[/^#ifndef BC2CPP_HOT_ONLY_STUBS\n(.*?)^#endif  \/\/ BC2CPP_HOT_ONLY_STUBS/m, 1].to_s
  {
    'load' => 'common_event', 'eligible' => 'common_event', 'from_page' => 'move_route', 'same_route?' => 'move_route'
  }.each do |name, klass|
    fn = { 'common_event' => 'Game__CommonEvent', 'move_route' => 'Game__MoveRoute' }.fetch(klass) + "_singleton_#{name.sub('?', '$3f')}"
    check.call("register.cxx registers #{klass}.#{name} as #{fn} inside the full-build region",
               guarded.match?(/mrb_define_class_method\(M, #{klass}, "#{Regexp.escape(name)}",\s+#{Regexp.escape(fn)},/))
  end
  # A world that is not closed (the desktop build) refuses from_page; the shipped pass (SKIP_UNSUPPORTED) then drops it and
  # says so with BC2CPP_SKIPPED_<entry>, which register.cxx's registration of it must be guarded by.
  check.call('register.cxx guards move_route.from_page with BC2CPP_SKIPPED_Game__MoveRoute_singleton_from_page',
             guarded.match?(/^#ifndef BC2CPP_SKIPPED_Game__MoveRoute_singleton_from_page\n\s*mrb_define_class_method\(M, move_route, "from_page",/))
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE + worlds.fetch('an open world')[:extra], dir, only_owners: OWNERS, build_gems: TIME_GEM,
                                                                                    drop_gems: ENGINE_GEMS, skip_unsupported: true, closed: false)
    check.call('an open world, shipped pass: from_page is dropped and BC2CPP_SKIPPED_Game__MoveRoute_singleton_from_page says so',
               code.include?("#define BC2CPP_SKIPPED_Game__MoveRoute_singleton_from_page 1\n"))
    check.call('an open world, shipped pass: same_route? is emitted and not marked skipped',
               code.match?(/^(?:static )?mrb_value Game__MoveRoute_singleton_same_route\$3f_impl\(mrb_state\* M/) &&
                 !code.include?('BC2CPP_SKIPPED_Game__MoveRoute_singleton_same_route'))
  end
  hot_path = wiring.fetch('hot')
  hot = File.readlines(hot_path, chomp: true)
  METHODS.each do |owner, names|
    names.each { |name| check.call("hot_methods.txt does not list #{owner}##{name}", !hot.include?("#{owner}##{name}")) }
  end
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE, dir, only_owners: OWNERS, build_gems: TIME_GEM, drop_gems: ENGINE_GEMS,
                                           hot_methods: hot_path)
    METHODS.each do |owner, names|
      names.each do |name|
        fn = "#{owner.sub('.singleton', '').gsub('::', '__')}_singleton_#{name.sub('?', '$3f')}"
        check.call("a hot-only build emits no code for #{owner}##{name}", !code.match?(/^(?:static )?mrb_value #{Regexp.escape(fn)}(?:_impl)?\(mrb_state\* M/))
      end
    end
  end
end

full = ENV['RSO_GENERATED_ONLY'] == '1' ? nil : runtime.full_or_build
if ENV['RSO_GENERATED_ONLY'] == '1'
  puts '  SKIP run: RSO_GENERATED_ONLY=1'
elsif full.nil? || !runtime.compiler?
  puts '  SKIP run: set BC2CPP_MRUBY_FULL (libmruby.a with the full-core gems, from the patched 3rd/mruby) and have g++'
else
  puts '-- on real mruby, interpreted and compiled'
  CASES = %w[load_none load_all load_not_a_db load_bad_entry same_nil_nil same_nil_route same_route_nil same_repeat
             same_skippable same_equal same_size same_id same_string same_a same_b same_c same_no_commands same_broken
             page_nil page_no_commands page_empty page_full page_keywords_default page_not_a_route
             page_initialize_raises sub_clone].freeze
  # The class-identity accessors the engine's register.cxx defines for DIRECT_CONSTRUCT_TARGETS (captured per VM).
  scenario = lambda do |extra_cases|
    <<~CPP
      static RClass* g_move_route = nullptr;
      static RClass* g_record = nullptr;
      RClass* Game__MoveRoute_compiled_class(void) { return g_move_route; }
      RClass* Game__CommonEvent__CommonEventRecord_compiled_class(void) { return g_record; }
      static int scenario(mrb_state* M) {
        RClass* game = mrb_module_get(M, "Game");
        g_move_route = mrb_class_get_under(M, game, "MoveRoute");
        g_record = mrb_class_get_under(M, mrb_module_get_under(M, game, "CommonEvent"), "CommonEventRecord");
        mrb_value use = mrb_obj_new(M, mrb_class_get(M, "RsoCaller"), 0, nullptr);
        #{CASES.map { |c| "call(M, #{c.dump}, use, #{c.dump});" }.join("\n  ")}
        mrb_value some = mrb_ary_new(M);
        mrb_ary_push(M, some, mrb_false_value());
        mrb_ary_push(M, some, mrb_false_value());
        mrb_ary_push(M, some, mrb_true_value());
        call(M, "eligible with switch 2 on", use, "eligible", 1, &some);
        mrb_value off = mrb_ary_new(M);
        call(M, "eligible with no switch on", use, "eligible", 1, &off);
        #{extra_cases.empty? ? '' : "mrb_value sub = mrb_obj_new(M, mrb_class_get(M, \"RsoSubCaller\"), 0, nullptr);"}
        #{extra_cases.map { |c| "call(M, #{c.dump}, sub, #{c.dump});" }.join("\n  ")}
        return 0;
      }
    CPP
  end
  worlds.select { |name, _| %w[base].include?(name) || WORLDS.fetch(name)[:cases] }.each do |name, world|
    extra_cases = world[:cases] || []
    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(FIXTURE + world[:extra], dir, only_owners: OWNERS, build_gems: TIME_GEM,
                                                                  drop_gems: ENGINE_GEMS)
      built, output = runtime.run(dir, err, OWNERS, scenario.call(extra_cases), build: full, full: true)
      check.call("#{name}: the fixture compiles and runs against real mruby", built)
      puts output unless built
      next unless built

      sections = runtime.sections(output)
      values = ->(section) { sections.fetch(section, []).reject { |l| l.start_with?('  ') } }
      interpreted = values.call('interpreted')
      compiled = values.call('compiled')
      total = CASES.size + 2 + extra_cases.size
      check.call("#{name}: the interpreter answered every case (#{total})", interpreted.size == total)
      check.call("#{name}: the compiled calls answer what the interpreter answers", !interpreted.empty? && interpreted == compiled)
      unless interpreted == compiled
        puts (interpreted - compiled).first(8).map { |l| "    interpreted: #{l}" }
        puts (compiled - interpreted).first(8).map { |l| "    compiled:    #{l}" }
      end
      puts output if ENV['BC2CPP_CHECK_VERBOSE']
      answers = interpreted.to_h { |l| [l[/\A(.*?) =>/, 1], l] }
      if name == 'base'
        # The inputs reach each branch: a failed load or comparison writes its message, an equal pair is true.
        check.call('a database without common events loads none', answers['load_none'].to_s.include?('[[], ""]'))
        check.call('a failed load writes its message and loads none', answers['load_not_a_db'].to_s.include?('common event load failed'))
        check.call('equal routes compare equal', answers['same_equal'].to_s.include?('[true, ""]'))
        check.call('a comparison that raises treats the routes as different', answers['same_broken'].to_s.include?('comparison failed'))
        check.call('from_page builds a MoveRoute with its keywords', answers['page_full'].to_s.include?('Game::MoveRoute, [1, 2], true, false'))
        check.call('from_page rescues a failing initialize', answers['page_initialize_raises'].to_s.include?('move route parse failed'))
        check.call('a bare new in an instance method is still NoMethodError', answers['sub_clone'].to_s.include?('NoMethodError'))
      else
        check.call('a subclass gets an instance of itself back', answers['sub_page'].to_s.include?('RsoSub, [1], true, true'))
      end
    end
  end
end

puts(failures.empty? ? 'bc2cpp_rpg2k_singleton_owners_check OK' : "FAILED: #{failures.size}")
exit(failures.empty? ? 0 : 1)
