#!/usr/bin/env ruby
# frozen_string_literal: true

# LOAD_COMPILE (tools/bc2cpp/load_compile.rb): the residual mrblib plus the compiled load must leave the VM in the
# state the whole mrblib does.
#
#   planner      what stays in the residual and why (promotion, pinned names, residual headers, modes, DSL
#                statements), that every residual still compiles with mrbc and keeps its line numbers and its
#                defs, and that the generated C++ is valid
#   equivalence  one fixture loaded as written, and as residual + compiled load (with the defs the compiled gem would
#                install added back): classes, superclasses, ancestors, singleton chains, constants with their
#                frozen state, class ivars, method names and visibility, equal; a load without the residual's marker
#                is a no-op
#   real gems    the engine gems' own mrblib through the planner with every def dropped: the residuals compile,
#                keep their line count, lose exactly the dropped defs, and the C++ is valid
#
# Needs MRBC; the equivalence half needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++).
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require 'open3'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/load_compile'
require_relative '../../tools/bc2cpp/class_world'

suite = FixtureCheck.new('class_body_check')
suite.require_mrbc!
MRBC_PATH = Bc2cppFixtureRuntime.mrbc
ROOT_DIR = File.expand_path('../..', __dir__)

FILE_A = <<~'RUBY'
  # frozen_string_literal: true
  module Top
    MARK = 7
  end

  class Free; end

  def helper_top = 1

  module Cb
    VERSION = 3
    PI = 3.25
    NAME = 'cb'
    SYM = :cb
    NIL = nil
    LIST = %w[a b].freeze
    MAP = { a: 1, 'b' => [2, 3], 4 => (1..3) }.freeze
    EMPTY = [].freeze
    # Integers: the 32-bit edges and a negative go through the constant table's varint; one outside the range stays
    # bytecode (a bignum on a 32-bit mrb_int target) -- LCF::INT32_WRAP read through a truncated varint was
    # 2147483648, and every negative number read from a file came out 2**31 - 3 instead of -3.
    NEG = -3
    EDGE_HI = 2147483647
    EDGE_LO = -2147483648
    WRAP = 0x1_0000_0000
    SIGN_BIT = 0x8000_0000
    BIG = VERSION * 10 + 2
    TOP_MARK = ::Top::MARK + 1
    OBJ = Object.new.freeze
    COLORS = [LIST, *LIST].freeze
    LIST_A = (0..3).map { |i| i * 2 }.freeze
    DERIVED = LIST_A + [1]
    BASE_N = 5
    TABLE = (0..BASE_N).map { |i| i }

    module Mixin
      def mixed = 1
      def other_mixed = 2
    end

    module Util
      def self.shout(x) = x.to_s
    end

    class Base
      LIMIT = 10
      attr_reader :x
      attr_writer :w
      def initialize = @x = 1
      def helper = LIMIT
      protected :helper
    end

    class Child < Base
      include Mixin
      extend Util
      DOUBLE = LIMIT * 2
      attr_accessor :y, :z
      def work = helper
      def free_one = 1
      alias_method :other, :free_one
      alias again free_one
      private
      attr_reader :hidden
      def secret = 2
      public
      def open_again = 3
    end

    class Child
      class << self
        attr_reader :count
        @count = 0
        def build = new
        private
        def hidden_cls = 1
      end
      @registry = { a: 1 }
    end

    class WithStruct < Struct.new(:a, :b)
      include Comparable
      LIM = 2
      def <=>(other) = a <=> other.a
    end

    # ORDER: an alias holds the method that existed when it ran, and a def above an attr is overridden by it.
    class Redef
      def run = 1
      alias_method :old_run, :run
      def run = old_run + 1
      def val = 5
      attr_reader :val
    end

    class Regd
      def self.tag(name) = (@tags ||= []) << name
      tag :one
      TAGGED = 5
    end
  end
RUBY

FILE_B = <<~'RUBY'
  class Cb::Child
    EXTRA = 9
    NAME_B = 'b'
    include Enumerable
  end

  module Cb::Extra
    FLAG = true
  end

  class ::Top2 < Cb::Base
    LATE = Cb::VERSION + 1
  end
RUBY

# Public defs only: the compiled gem registers a dropped def with the visibility the registry gives it, which is a
# different mechanism (the equivalence adds them back public).
DROP = %w[Object#helper_top Cb::Mixin#mixed Cb::Mixin#other_mixed Cb::Util.singleton#shout Cb::Base#initialize
          Cb::Base#helper Cb::Child#work Cb::Child#free_one Cb::Child.singleton#build Cb::WithStruct#<=>
          Cb::Child#open_again Cb::Redef#run Cb::Redef#val].freeze

DUMP = <<~'RUBY'
  $bc2cpp_out = []
  # An address in a name (an anonymous class) is not part of the graph. No Regexp in this VM.
  def bc2cpp_norm(s)
    s = s.to_s
    out = ''
    i = 0
    while i < s.size
      if s[i, 2] == '0x'
        out << '0x_'
        i += 2
        i += 1 while i < s.size && '0123456789abcdef'.include?(s[i])
      else
        out << s[i]
        i += 1
      end
    end
    out
  end
  def bc2cpp_walk(mod, seen)
    return if seen.key?(mod.object_id)

    seen[mod.object_id] = true
    o = $bc2cpp_out
    o << "#{bc2cpp_norm(mod.inspect)} #{mod.is_a?(Class) ? 'class' : 'module'}"
    o << "  superclass=#{bc2cpp_norm(mod.superclass.inspect)}" if mod.is_a?(Class)
    o << "  ancestors=#{bc2cpp_norm(mod.ancestors.inspect)}"
    o << "  singleton_ancestors=#{bc2cpp_norm(mod.singleton_class.ancestors.inspect)}"
    %w[public private protected].each { |v| o << "  #{v}=#{mod.send("#{v}_instance_methods", false).sort.inspect}" }
    o << "  singleton=#{mod.singleton_methods(false).sort.inspect}"
    o << "  ivars=#{bc2cpp_norm(mod.instance_variables.sort.map { |v| [v, mod.instance_variable_get(v)] }.inspect)}"
    o << "  sclass_ivars=#{bc2cpp_norm(mod.singleton_class.instance_variables.sort.map { |v| [v, mod.singleton_class.instance_variable_get(v)] }.inspect)}"
    mod.constants(false).sort.each do |c|
      v = mod.const_get(c)
      if v.is_a?(Module) && v.name == "#{mod.name == 'Object' ? '' : "#{mod.name}::"}#{c}"
        bc2cpp_walk(v, seen)
      else
        o << "  const #{c}=#{bc2cpp_norm(v.inspect)} #{v.class} frozen=#{v.frozen?}"
      end
    end
  end
  seen = {}
  %w[Top Top2 Free Cb].each { |n| bc2cpp_walk(Object.const_get(n), seen) }
  $bc2cpp_out << "redef #{Cb::Redef.new.run} #{Cb::Redef.new.val.inspect}"
  $bc2cpp_out << "top-level helper_top: #{Object.instance_methods(false).include?(:helper_top) || Object.private_instance_methods(false).include?(:helper_top)}"
  $bc2cpp_out.join("\n")
RUBY

# CLASS_WORLD against the graph the interpreted load built: the facts file (tools/bc2cpp/class_world.rb) is only worth
# having if every class it calls exact is what the VM made. The dump names the classes under Top, Top2, Free and Cb.
def graph_facts_check(suite, files, interpreted)
  world = ClassWorld.build(files.map { |f| ClassBodyScan.scan([f]) }.then { |scans| [merge_roots(scans)] })
  real = {}
  interpreted.each_with_index do |line, i|
    next unless line =~ /\A([A-Z]\S*) (class|module)\z/ || line.match?(/\A[A-Z]\S* (class|module)\z/)

    name, kind = line.split(' ')
    fields = {}
    interpreted[(i + 1)..].take_while { |l| l.start_with?('  ') }.each do |l|
      key, value = l.strip.split('=', 2)
      fields[key] = value
    end
    real[name] = fields.merge('kind' => kind)
  end
  names = ->(text) { text.to_s.delete('[]').split(', ') }
  facts = world.facts
  known = facts.keys.to_set
  exact = facts.select { |name, h| h['exact'] && real.key?(name) }
  bad = []
  exact.each do |name, h|
    r = real.fetch(name)
    bad << "#{name} kind #{r['kind']} vs #{h['kind']}" unless r['kind'] == h['kind']
    bad << "#{name} superclass #{r['superclass']} vs #{h['superclass']}" if r['kind'] == 'class' && r['superclass'] != h['superclass']
    got = names.(r['ancestors']).select { |n| known.include?(n) }
    bad << "#{name} ancestors #{got} vs #{h['ancestors']}" unless got == h['ancestors'].select { |n| known.include?(n) }
    sing = names.(r['singleton_ancestors']).select { |n| n.start_with?('#<Class:') || known.include?(n) }
    want = h['singleton_chain'].select { |n| n.start_with?('#<Class:') || known.include?(n) }
    bad << "#{name} singleton #{sing} vs #{want}" unless sing == want
    supers = real.values.filter_map { |o| o['superclass'] }
    bad << "#{name} final=#{h['final']} but #{supers.count(name)} subclasses" if h['final'] == !supers.count(name).zero?
  end
  puts bad.first(8).map { |l| "    graph: #{l}" } unless bad.empty?
  suite.check("class world facts match the interpreted graph (#{exact.size} exact of #{real.size} classes the dump saw)",
              !exact.empty? && bad.empty?)
  suite.check('class world: a class with a DSL call or computed constant is unknown, not exact',
              facts['Cb::Mixin'] && facts.values.any? { |h| !h['exact'] })
end

# One root over several files' scans (load order): what ClassWorld.build reads.
def merge_roots(scans)
  root = scans.first
  scans.drop(1).each { |s| root.statements.concat(s.statements); root.children.concat(s.children) }
  root
end

Dir.mktmpdir('bc2cpp-class-body') do |dir|
  paths = { 'fxa.rb' => FILE_A, 'fxb.rb' => FILE_B }.to_h do |name, text|
    path = File.join(dir, name)
    File.write(path, text)
    [path, text]
  end
  files = paths.keys
  result = LoadCompile.plan({ 'g' => files }, gem: 'g', drop_keys: DROP.to_set, symbol: 'fx')
  residual = files.to_h { |f| [f, LoadCompile.apply(paths[f], result.ranges.fetch(f), marker: f == result.last_file ? result.marker : nil)] }
  res_a = residual[files[0]]
  res_b = residual[files[1]]

  def_keys = lambda do |text|
    names = []
    walk = lambda do |node, owner|
      case node
      when Prism::ClassNode, Prism::ModuleNode
        name = node.constant_path.slice.delete_prefix('::')
        inner = node.constant_path.slice.start_with?('::') || owner.empty? ? name : "#{owner}::#{name}"
        node.body&.compact_child_nodes&.each { |c| walk.call(c, inner) }
      when Prism::StatementsNode then node.body.each { |c| walk.call(c, owner) }
      when Prism::SingletonClassNode then node.body&.compact_child_nodes&.each { |c| walk.call(c, "#{owner}.singleton") }
      when Prism::DefNode
        names << "#{owner.empty? ? 'Object' : owner}#{node.receiver ? '.singleton' : ''}##{node.name}"
      when Prism::CallNode
        (node.arguments&.arguments || []).each { |a| walk.call(a, owner) if a.is_a?(Prism::DefNode) }
      end
    end
    walk.call(Prism.parse(text).value.statements, '')
    names
  end

  # --- planner ---------------------------------------------------------------------------------------------
  suite.check('each residual keeps its line count (the marker adds one)',
              paths[files[0]].lines.size == res_a.lines.size && paths[files[1]].lines.size + 2 == res_b.lines.size)
  compiles = files.all? do |f|
    out = File.join(dir, "#{File.basename(f)}.res.rb")
    File.write(out, residual[f])
    system(MRBC_PATH, '-o', File.join(dir, 'x.mrb'), out, out: File::NULL, err: File::NULL)
  end
  suite.check('every residual compiles with mrbc', compiles)
  original_defs = files.flat_map { |f| def_keys.call(paths[f]) }
  kept_defs = files.flat_map { |f| def_keys.call(residual[f]) }
  dropped = DROP.select { |k| original_defs.include?(k) } - ['Cb::Base#helper', 'Cb::Child#free_one', 'Cb::Redef#run', 'Cb::Redef#val']
  suite.check('the residual has exactly the defs that were not dropped', (original_defs - kept_defs).sort == dropped.sort)
  suite.check('a def a compiled statement names stays (protected :helper, alias_method)',
              kept_defs.include?('Cb::Base#helper') && kept_defs.include?('Cb::Child#free_one'))
  suite.check('ORDER: an alias above a redefinition stays residual, and a def above an attr that redefines it stays',
              res_a.include?('alias_method :old_run, :run') && kept_defs.count('Cb::Redef#run') == 2 &&
              kept_defs.include?('Cb::Redef#val') && res_a.include?('attr_reader :val') == false)
  suite.check('an Integer outside 32 bits stays residual; the edges and a negative are compiled',
              res_a.include?('WRAP = 0x1_0000_0000') && res_a.include?('SIGN_BIT = 0x8000_0000') &&
              !res_a.include?('NEG = -3') && !res_a.include?('EDGE_HI') && !res_a.include?('EDGE_LO'))
  suite.check('a residual statement that reads a constant keeps that constant in the residual (promotion)',
              res_a.include?('BASE_N = 5') && res_a.include?('TABLE = (0..BASE_N)') && !res_a.include?('PI = 3.25'))
  suite.check('an attr under `private` stays residual, in its place; a bare mode stays',
              res_a.match?(/^\s*private\n\s*attr_reader :hidden/) && res_a.include?('def secret = 2'))
  suite.check('a DSL call (tag :one) and a header the compiler cannot run (Struct.new superclass) stay',
              res_a.include?('tag :one') && res_a.include?('class WithStruct < Struct.new(:a, :b)') &&
              !res_a.include?('include Comparable'))
  suite.check('a body with nothing left is deleted whole; one that stays keeps header and end',
              !res_a.include?('module Mixin') && !res_a.include?('module Top') && res_a.include?('class Base') &&
              !res_b.include?('Extra') && res_b.include?('class Cb::Child'.dup) == false)
  suite.check('a superclass the residual names keeps its class (class Child < Base)', res_a.match?(/^\s*class Base\n/))
  suite.check('the marker closes the last file only', res_b.end_with?("#{result.marker} = true\n") && !res_a.include?(result.marker))

  syntax = lambda do |code, label|
    build = Bc2cppFixtureRuntime.full_or_build
    next true unless build

    src = File.join(dir, "#{label}_syntax.cpp")
    File.write(src, code)
    flags = %w[-std=c++17 -fexceptions -DMRB_USE_CXX_EXCEPTION -w -fsyntax-only] + Bc2cppFixtureRuntime.library_defines(build)
    system('g++', *flags, "-I#{build}/include", "-I#{ROOT_DIR}/3rd/mruby/include", src, out: File::NULL, err: File::NULL)
  end
  suite.check('the generated C++ compiles', syntax.call(result.code, 'fixture'))

  # --- equivalence -----------------------------------------------------------------------------------------
  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP load equivalence: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    snippet = result.dropped.map do |d|
      case d[:kind]
      when :sclass then "class << #{d[:owner].delete_suffix('.singleton')}\n#{d[:source]}\nend\n"
      when :module then "module #{d[:owner]}\n#{d[:source]}\nend\n"
      when :class then "class #{d[:owner]}\n#{d[:source]}\nend\n"
      else "#{d[:source]}\n"
      end
    end.join
    File.write(File.join(dir, 'load_gen.cpp'), result.code)
    File.write(File.join(dir, 'dump.rb'), DUMP)
    File.write(File.join(dir, 'snippet.rb'), snippet)
    res_paths = files.map { |f| File.join(dir, "#{File.basename(f)}.res.rb") }
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      #include <mruby/compile.h>
      #include <mruby/string.h>
      #include <cstdio>
      #include <fstream>
      #include <iterator>
      #include <string>
      #include "load_gen.cpp"
      static std::string slurp(const char* path) {
        std::ifstream in(path, std::ios::binary);
        return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
      }
      static mrb_value run(mrb_state* M, const std::string& code) {
        mrb_value v = mrb_load_nstring(M, code.data(), code.size());
        if (M->exc) { mrb_print_error(M); std::exit(2); }
        return v;
      }
      static void emit(const char* label, mrb_state* M, const std::string& dump) {
        mrb_value s = run(M, dump);
        std::printf("== %s\\n%.*s\\n", label, (int)RSTRING_LEN(s), RSTRING_PTR(s));
      }
      int main(int, char** argv) {
        std::string dump = slurp(argv[1]), snippet = slurp(argv[4]);
        std::string a = slurp(argv[2]), b = slurp(argv[3]), ra = slurp(argv[5]), rb = slurp(argv[6]);
        { mrb_state* M = mrb_open(); run(M, a); run(M, b); emit("interpreted", M, dump); mrb_close(M); }
        { mrb_state* M = mrb_open(); run(M, ra); run(M, rb); bc2cpp_load_fx(M); run(M, snippet); emit("compiled", M, dump); mrb_close(M); }
        { mrb_state* M = mrb_open(); run(M, a); run(M, b); bc2cpp_load_fx(M); emit("ungated", M, dump); mrb_close(M); }
        return 0;
      }
    CPP
    flags = %w[-std=c++17 -fexceptions -DMRB_USE_CXX_EXCEPTION -w] + Bc2cppFixtureRuntime.library_defines(build)
    binary = File.join(dir, 'fixture')
    built = Bc2cppCxx.system(*flags, "-I#{dir}", "-I#{build}/include", "-I#{ROOT_DIR}/3rd/mruby/include",
                             File.join(dir, 'main.cpp'), "#{build}/lib/libmruby.a", '-lm', '-o', binary)
    suite.check('the fixture builds', built)
    if built
      out, status = Open3.capture2e(binary, File.join(dir, 'dump.rb'), files[0], files[1], File.join(dir, 'snippet.rb'),
                                    res_paths[0], res_paths[1])
      suite.check('the fixture runs', status.success?)
      puts out.lines.last(20).join unless status.success?
      sections = Bc2cppFixtureRuntime.sections(out)
      interpreted = sections['interpreted'].to_a
      compiled = sections['compiled'].to_a
      ungated = sections['ungated'].to_a
      File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'interpreted.txt'), interpreted.join("\n")) if ENV['BC2CPP_KEEP_DIR']
      File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'compiled.txt'), compiled.join("\n")) if ENV['BC2CPP_KEEP_DIR']
      suite.check('the dump saw the fixture (classes, constants, methods)',
                  status.success? && interpreted.size > 60 && interpreted.any? { |l| l.include?('const BIG=32') })
      unless compiled == interpreted
        puts (interpreted - compiled).first(8).map { |l| "    only interpreted: #{l}" }
        puts (compiled - interpreted).first(8).map { |l| "    only compiled:    #{l}" }
      end
      suite.check('residual + compiled load gives the interpreted classes, ancestors, constants and methods',
                  !interpreted.empty? && compiled == interpreted)
      graph_facts_check(suite, files, interpreted)
      suite.check('a load without the residual marker is a no-op (the full mrblib is not loaded twice)',
                  !interpreted.empty? && ungated == interpreted)
    end
  end

  # defs mode: no compiled load runs, so no body may be deleted, and no code or marker is produced.
  defs = LoadCompile.plan({ 'g' => files }, gem: 'g', drop_keys: DROP.to_set, symbol: 'fx', statements: false)
  defs_a = LoadCompile.apply(paths[files[0]], defs.ranges.fetch(files[0]))
  suite.check('defs mode: no marker, no load code, every class body keeps its header',
              defs.marker.nil? && defs.code.empty? && defs.stats[:deleted_bodies].to_i.zero? &&
              %w[module\ Cb class\ Free].all? { |h| defs_a.include?(h) })

  # --- the real gems ----------------------------------------------------------------------------------------
  gems = {
    'mruby-lcf' => Dir["#{ROOT_DIR}/mruby-lcf/mrblib/*.rb"].sort,
    'mruby-rgss' => Dir["#{ROOT_DIR}/mruby-rgss/mrblib/*.rb"].sort,
    'mruby-rpg2k' => Dir["#{ROOT_DIR}/mruby-rpg2k/mrblib/**/*.rb"].reject { |p| p.end_with?('scene/map_tts.rb') }.sort +
                     ["#{ROOT_DIR}/mruby-rpg2k/mrblib_limited/map_tts_off.rb"]
  }
  all_keys = gems.transform_values do |fs|
    fs.flat_map do |f|
      keys = []
      LoadCompile.each_ubody(LoadCompile.build_root(f)) { |ub| ub.items.each { |i| keys << i.def_key if i.def_key } }
      keys
    end.to_set
  end
  # STAYS_BYTECODE: the statements of the engine's class bodies the compiled load leaves to the residual mrblib. A new
  # one is a decision (compile it, fold it to data, or list it here with the reason), not something a refactor adds.
  stays = {
    'LCF::Schema::COMMON_EVENT' => 'read by the DATABASE hash below, which is residual',
    'LCF::Schema::DATABASE' => 'nested hash holding the `elements:` lambdas (a lambda is bytecode)',
    'LCF::Schema::MAP_UNIT' => 'the same, with lambdas',
    'RGSS::Audio::EXTS' => 'read by EXT_SPELLINGS, which is residual',
    'RGSS::Audio::EXT_SPELLINGS' => 'built by an `each` block',
    'Game::State::SYSTEM_SFX_SAVE_FIELD' => 'built by an `each_with_object` block',
    'LCF::INT32_MASK' => 'a bignum on a 32-bit mrb_int target: an irep literal',
    'LCF::INT32_SIGN_BIT' => 'the same',
    'LCF::INT32_WRAP' => 'the same',
    'Array.alias_method sort!' => 'ORDER: holds the core sort!, a def of the same name follows',
    'RGSS::Window.alias_method initialize' => 'ORDER: holds the native initialize, a def of the same name follows'
  }
  found = []
  gems.each do |gem, fs|
    r = LoadCompile.plan(gems, gem: gem, drop_keys: all_keys.fetch(gem), symbol: gem.delete_prefix('mruby-'))
    out_dir = File.join(dir, gem)
    FileUtils.mkdir_p(out_dir)
    ok = true
    kept_all = []
    original_all = []
    fs.each do |f|
      text = File.binread(f)
      res = LoadCompile.apply(text, r.ranges.fetch(f), marker: f == r.last_file ? r.marker : nil)
      out = File.join(out_dir, File.basename(f))
      File.binwrite(out, res)
      ok &&= res.lines.size == text.lines.size + (f == r.last_file ? 2 : 0)
      ok &&= system(MRBC_PATH, '-o', File.join(out_dir, 'x.mrb'), out, out: File::NULL, err: File::NULL)
      original_all.concat(def_keys.call(text.force_encoding(Encoding::UTF_8)))
      kept_all.concat(def_keys.call(res.dup.force_encoding(Encoding::UTF_8)))
    end
    r.bodies.each do |root|
      LoadCompile.each_ubody(root) do |ub|
        ub.items.each do |i|
          next unless i.role == :residual

          node = i.stmt.node
          found << (node.respond_to?(:name) && node.is_a?(Prism::ConstantWriteNode) ? "#{ub.body.path}::#{node.name}" : "#{ub.body.path}.#{node.is_a?(Prism::AliasMethodNode) ? 'alias' : node.name} #{LoadCompile.taken_names(node).last}")
        end
      end
    end
    suite.check("#{gem}: every residual compiles with mrbc and keeps its line count", ok)
    pinned_kept = (original_all - kept_all).size
    suite.check("#{gem}: the residual lost the dropped defs and no other (#{pinned_kept} of #{original_all.size})",
                (kept_all - original_all).empty? && pinned_kept == r.stats[:defs_dropped] && pinned_kept.positive?)
    suite.check("#{gem}: the generated C++ compiles", syntax.call(r.code, gem.delete_prefix('mruby-')))
    s = r.stats
    puts "    #{gem}: #{s[:bodies]} bodies (#{s[:deleted_bodies]} deleted, #{s[:skeleton_bodies]} kept as skeleton), " \
         "#{s[:defs_dropped]} defs dropped, #{s[:defs_kept]} kept, #{s[:promoted].to_i} constants promoted, " \
         "#{s[:role_residual]} residual statements"
  end
  puts "    unlisted: #{found.sort - stays.keys}, missing: #{stays.keys.sort - found}" unless found.sort == stays.keys.sort
  suite.check("the statements that stay bytecode are the #{stays.size} listed", found.sort == stays.keys.sort)
  # The engine's class graph from source: how much of it is exact (tools/bc2cpp/class_world.rb).
  engine = ClassWorld.build(gems.values.map { |fs| ClassBodyScan.scan(fs) })
  sum = ClassWorld.summary(engine)
  picture = engine.facts['Game::Picture']
  suite.check("class world of the engine gems: #{sum['exact']} of #{sum['classes']} classes exact, " \
              "#{sum['bodies_bytecode']} bodies left as bytecode",
              picture && picture['exact'] && picture['kind'] == 'class' && sum['exact'] > sum['unknown'])
end

suite.finish!
