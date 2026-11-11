# frozen_string_literal: true

# The oracle without the oracle: a table of what the fork's `mrbc -g` wrote for every input bc2cpp and its tests compile, so
# the emitter's bytes can be checked against it where no mrbc is built (BC2CPP_MRBC_RB=snapshot, golden_test.rb, cli_test.rb).
#
# The table is two sorted text files next to this one, one line per input:
#   snapshot.txt        the inputs that do not depend on a world checkout (the golden snippets and file groups);
#                       BC2CPP_MRBC_SNAPSHOT=<file> overrides
#   snapshot_world.txt  the inputs read from the pinned rpg-maker-clone world (its mrblib sets, scripts, gems, optcarrot) and what
#                       world builds recorded; BC2CPP_MRBC_SNAPSHOT_WORLD=<file> overrides. Its header has "# world: <commit>", the
#                       checkout the entries were generated at (the pin of tests/bc2cpp/fetch.sh), and "# oracle: ..." (the fork's
#                       mrbc of that world). A world at another commit (a pin bump) does not match 300 entries one by one: it
#                       fails once with "world pin changed: run snapshot.rb --update", and --update with the new world's mrbc
#                       regenerates the file.
# Both have the same line format:
#   <key> <value>
#   key   = first 32 hex digits of SHA-256 over "g\n", the number of files, and for each file in command-line order the SHA-256 of
#           its content. The file names are not part of the key (they are not part of what decides the output, see below).
#   value = first 32 hex digits of SHA-256 of the oracle's RITE image with the DBG file names neutralised (RiteDump.neutral_files).
# The one place where a name does matter is a source that reads its own name (__FILE__, __dir__): the name ends up in the image's
# string pool. For such an input the key also hashes the file names as given, so it only matches where it was recorded (the
# check then says "not in snapshot" instead of passing wrongly). Lines starting with # are the header (what the oracle was; for
# snapshot.txt it is informational, drift shows as STALE values, for snapshot_world.txt it is checked, see above).
#
#   ruby snapshot.rb --update [--prune] [--from-record FILE...]
#                                                       needs MRBC (the oracle): compile every enumerated input with both, refuse
#                                                       to write when the emitter differs, merge the record files (into the world
#                                                       table); --prune first drops the entries no enumerated input or record file
#                                                       gives. Without a world only snapshot.txt is written; with one, both, and
#                                                       snapshot_world.txt is rebuilt from scratch when the world's commit changed
#   ruby snapshot.rb --check                            needs MRBC: the world pin and oracle are the recorded ones, every enumerated
#                                                       input is in the table and the oracle still gives the recorded value (drift
#                                                       of the oracle or an incomplete table fail)
#   ruby snapshot.rb --verify                           no oracle: the world pin is the recorded one, the emitter's bytes against the
#                                                       table for every enumerated input
#   ruby snapshot.rb --stats                            size of the table
# Inputs: the golden snippets and file groups and, when a world checkout exists (BC2CPP_RPG_DIR, else
# build/bc2cpp/rpg-maker-clone), its mrblib sets (whole, neighbour pairs, single files), scripts, mruby-*/ and optcarrot's lib.
# bc2cpp/**/*.rb (the emitter's corpus) is not in the table: every change edits some of it, so --check compares the emitter with
# the oracle on those directly. What a world compiles beyond that is recorded: BC2CPP_MRBC_RB=verify with BC2CPP_MRBC_SNAPSHOT_RECORD=<file> appends
# "<key> <oracle value>" per compile, and --update --from-record merges those files.

require 'digest'
require 'open3'
require 'tmpdir'
require_relative 'mrbc_rb'
require_relative 'rite_dump'

module MrbcRb
  module Snapshot
    DEFAULT_FILE = File.join(__dir__, 'snapshot.txt')
    DEFAULT_WORLD_FILE = File.join(__dir__, 'snapshot_world.txt')
    PATH_DEPENDENT = /__FILE__|__dir__/

    NotInSnapshot = Class.new(StandardError)

    module_function

    def file = ENV.fetch('BC2CPP_MRBC_SNAPSHOT', DEFAULT_FILE)

    def world_file = ENV.fetch('BC2CPP_MRBC_SNAPSHOT_WORLD', DEFAULT_WORLD_FILE)

    def digest(bytes) = Digest::SHA256.hexdigest(bytes)

    # Sources of the world are compiled, hashed and checked under their path relative to the world root, as `cd <world> && mrbc
    # scripts/x.rb` sees them: a source that reads its own name (__FILE__, __dir__) puts it into the image, and the absolute
    # path is wherever the checkout happens to be. Other paths (the repo's bc2cpp/, snippets) stay as given.
    # Returns [sources with relative paths, the world root when any path was made relative].
    def relative(sources, world = world_root)
      return [sources, nil] unless world

      root = File.expand_path(world) + '/'
      changed = false
      rel = sources.map do |src, path|
        abs = File.expand_path(path)
        next [src, path] unless abs.start_with?(root)

        changed = true
        [src, abs[root.size..]]
      end
      [rel, changed ? File.expand_path(world) : nil]
    end

    # +sources+: [[content, path], ...] in command-line order.
    def key(sources)
      sources, = relative(sources)
      parts = sources.map { |src, _| digest(src.b) }
      parts.concat(sources.map { |_, path| "path:#{path}" }) if sources.any? { |src, _| src.b.match?(PATH_DEPENDENT) }
      digest("g\n#{sources.size}\n#{parts.join("\n")}")[0, 32]
    end

    def value(image) = digest(RiteDump.neutral_files(image))[0, 32]

    def load(path = file)
      table = {}
      return table unless File.exist?(path)

      File.foreach(path) do |line|
        next if line.start_with?('#') || line.strip.empty?

        k, v = line.split
        table[k] = v
      end
      table
    end

    def header(path = file)
      File.exist?(path) ? File.readlines(path).take_while { |l| l.start_with?('#') } : []
    end

    def write(table, header_lines, path = file)
      File.write(path, header_lines.join + table.sort.map { |k, v| "#{k} #{v}\n" }.join)
    end

    # "# <name>: <value>" of the header, or nil.
    def header_value(name, path)
      header(path).each { |l| return Regexp.last_match(1).strip if l =~ /\A# #{name}: (.*)/ }
      nil
    end

    # The commit of the world checkout (what tests/bc2cpp/fetch.sh pins), nil when there is no world or it is not a git checkout.
    def world_pin(world = world_root)
      return nil unless world

      @world_pins ||= {}
      @world_pins.fetch(world) do
        out, st = Open3.capture2('git', '-C', world, 'rev-parse', 'HEAD', err: File::NULL)
        @world_pins[world] = st.success? ? out.strip : nil
      end
    end

    # One message when the world is not the one snapshot_world.txt was generated at, else nil (also nil with no world or no pin
    # to compare: the entries are then looked up as they are).
    def world_pin_problem(world = world_root, path = world_file)
      pin = world_pin(world)
      return nil unless pin

      recorded = header_value('world', path)
      return nil if recorded == pin

      "world pin changed: #{File.basename(path)} was generated at #{recorded ? recorded[0, 12] : '(no world header)'}, " \
        "the world is at #{pin[0, 12]}; run snapshot.rb --update with that world's mrbc (MRBC=<fork mrbc> BC2CPP_RPG_DIR=<world>)"
    end

    # The oracle of the world table is derived from the pin (the fork's submodule commit), so it must be the same; a mrbc
    # without a git checkout has no revision to compare, then the version alone is.
    def oracle_problem(oracle, path = world_file)
      recorded = header_value('oracle', path)
      now = oracle_id(oracle)
      return nil if recorded == now || (recorded && !now.end_with?(')') && recorded.start_with?(now))
      return nil if recorded.nil? && !File.exist?(path)

      "oracle changed: #{File.basename(path)} was generated with #{recorded || '(no oracle header)'}, MRBC is #{now}"
    end

    @tables = {}
    # The base table merged with the world table (+world_path+ is looked up too when it exists).
    def table(path = file, world_path = world_file) = (@tables[[path, world_path]] ||= load(world_path).merge!(load(path)))

    # :ok, or raises NotInSnapshot / returns :differs. +image+ is the emitter's output for +sources+.
    def check(sources, image, path = file)
      rel, = relative(sources)
      if rel != sources && sources.any? { |src, _| src.b.match?(PATH_DEPENDENT) }
        # the image the caller built has the checkout's absolute path in it: what is compared is the emitter's image of the
        # same sources under their world-relative names
        image = begin
          rel.size == 1 ? MrbcRb.compile(rel[0][0], rel[0][1]) : MrbcRb.compile_files(rel)
        rescue MrbcRb::Error
          image
        end
      end
      recorded = table(path)[key(sources)]
      unless recorded
        hint = world_pin_problem || 'run snapshot.rb --update with the oracle'
        raise NotInSnapshot, "input not in snapshot (#{sources.first&.last}#{sources.size > 1 ? " +#{sources.size - 1}" : ''}): #{hint}"
      end

      recorded == value(image) ? :ok : :differs
    end

    def record(sources, oracle_image, into)
      File.open(into, 'a') { |f| f.puts "#{key(sources)} #{value(oracle_image)}" }
    end

    # ---- the inputs ----

    def world_root
      dir = ENV['BC2CPP_RPG_DIR'] || File.expand_path('../../../build/bc2cpp/rpg-maker-clone', __dir__)
      File.directory?(File.join(dir, '3rd/mruby')) ? dir : nil
    end

    # Yields [label, [[content, path], ...]]. Paths are as the tests give them (relative to the repository root for bc2cpp/).
    def each_input(world: world_root)
      return to_enum(__method__, world: world) unless block_given?

      SNIPPETS.each_with_index { |s, i| yield "snippet #{i}", [["#{s}\n", 't.rb']], :base }
      MULTI_FILE_GROUPS.each_with_index do |g, gi|
        yield "group #{gi}", g.each_with_index.map { |s, i| [s, "g#{gi}_#{i}.rb"] }, :base
      end
      return unless world

      mruby = File.join(world, '3rd/mruby')
      sets = { 'core mrblib' => Dir["#{mruby}/mrblib/*.rb"].sort.reject { |p| p.end_with?('/10error.rb') } }
      (Dir["#{mruby}/mrbgems/*"] + Dir["#{world}/3rd/*"] + Dir["#{world}/mruby-*"]).sort.each do |gem_dir|
        sets[File.basename(gem_dir)] = Dir["#{gem_dir}/mrblib/**/*.rb"].sort
      end
      sets.each do |name, files|
        next if files.empty?

        ([files] + (files.size > 1 ? files.each_cons(2).to_a : [])).each { |ps| yield "#{name} (#{ps.size})", ps.map { |p| [File.binread(p), p] }, :world }
        files.each { |p| yield p, [[File.binread(p), p]], :world } if files.size > 1
      end
      (Dir["#{world}/scripts/**/*.rb"] + Dir["#{world}/mruby-*/**/*.rb"] + Dir["#{world}/3rd/optcarrot/lib/**/*.rb"]).sort.uniq.each do |p|
        yield p, [[File.binread(p), p]], :world
      end
    end

    # The repository's own Ruby files (bc2cpp/**/*.rb): the emitter's corpus, but not inputs of any world, and edited by every
    # change, so not in the table: --check compares the emitter with the oracle on them directly. Paths relative to the repo root.
    def each_volatile
      return to_enum(__method__) unless block_given?

      Dir.chdir(File.expand_path('../../..', __dir__)) do
        Dir.glob('bc2cpp/**/*.rb').sort.each { |p| yield p, [[File.binread(p), p]] }
      end
    end

    # [emitter image or nil (not covered), oracle image or nil (rejected), compile error] for +sources+.
    def compile_both(sources, oracle)
      sources, world = relative(sources)
      emitted = begin
        sources.size == 1 ? MrbcRb.compile(sources[0][0], sources[0][1]) : MrbcRb.compile_files(sources)
      rescue MrbcRb::Error
        nil
      end
      Dir.mktmpdir('snapshot') do |dir|
        # the oracle sees the names the input has: a file is read where it is, a snippet is written under its name in a
        # scratch directory the oracle runs in
        on_disk = world ? true : sources.all? { |src, path| File.file?(path) && File.binread(path) == src.b }
        sources.each { |src, path| File.binwrite(File.join(dir, path), src) } unless on_disk
        out = File.join(dir, 'o.mrb')
        names = sources.map(&:last)
        opts = world ? { chdir: world } : on_disk ? {} : { chdir: dir }
        _o, _e, st = Open3.capture3(oracle, '-g', '-o', out, *names, binmode: true, **opts)
        [emitted, st.success? ? File.binread(out) : nil]
      end
    end

    def oracle_id(oracle)
      mruby = File.expand_path('..', File.dirname(oracle))
      rev = `git -C #{mruby} rev-parse --short HEAD 2>/dev/null`.strip
      ver, = Open3.capture2(oracle, '--version')
      "#{ver.strip}#{rev.empty? ? '' : " (#{rev})"}"
    end

    def run(argv)
      mode = argv.shift
      case mode
      when '--stats' then stats
      when '--verify' then verify
      when '--update', '--check' then with_oracle(mode, argv)
      else
        warn 'usage: snapshot.rb --update [--from-record FILE...] | --check | --verify | --stats'
        2
      end
    end

    def stats
      [file, world_file].each do |f|
        next unless File.exist?(f)

        t = load(f)
        raw = File.size(f)
        puts "#{File.basename(f)}: #{t.size} entries, #{raw} bytes (#{(raw.to_f / [t.size, 1].max).round(1)} per entry)"
      end
      0
    end

    def verify(*)
      if (problem = world_pin_problem)
        puts problem
        return 1
      end
      bad = missing = ok = skipped = 0
      each_input do |label, sources, _scope|
        image = begin
          sources.size == 1 ? MrbcRb.compile(sources[0][0], sources[0][1]) : MrbcRb.compile_files(sources)
        rescue MrbcRb::Error
          skipped += 1
          next
        end
        case check(sources, image)
        when :ok then ok += 1
        else bad += 1; puts "DIFFERS #{label}"
        end
      rescue NotInSnapshot => e
        missing += 1
        puts "MISSING #{label}: #{e.message}"
      end
      puts "snapshot: #{ok} match, #{bad} differ, #{missing} missing, #{skipped} not covered by the emitter"
      bad.zero? && missing.zero? ? 0 : 1
    end

    def with_oracle(mode, argv)
      oracle = ENV['MRBC']
      abort "snapshot.rb #{mode} needs the oracle: set MRBC=<fork mrbc>" unless oracle && File.executable?(oracle)
      update = mode == '--update'
      prune = argv.delete('--prune')
      world = world_root
      pin = world_pin(world)
      # --check: the pin and the oracle first, one line each instead of a line per input that cannot match
      unless update
        early = [world_pin_problem(world), (oracle_problem(oracle) if world)].compact
        unless early.empty?
          early.each { |m| puts m }
          puts "snapshot --check: #{early.size} problem(s)"
          exit 1
        end
      end
      # --update: the base table merges into the existing one unless --prune; the world table too, but only at the same world
      # commit (entries of another one are stale by construction: a bump regenerates it)
      new_world = world && !(File.exist?(world_file) && header_value('world', world_file) == pin)
      tables = { base: update && !prune ? load : {}, world: update && !prune && !new_world ? load(world_file) : {} }
      old = update ? nil : table
      problems = 0
      seen = Hash.new(0)
      each_input do |label, sources, scope|
        emitted, theirs = compile_both(sources, oracle)
        if theirs.nil?
          seen[:oracle_rejects] += 1
          next
        end
        k = key(sources)
        v = value(theirs)
        if emitted && emitted != theirs && value(emitted) != v
          problems += 1
          puts "EMITTER DIFFERS #{label}"
          next
        end
        seen[emitted ? :covered : :fallback] += 1
        if update
          tables[scope][k] = v
        elsif old[k].nil?
          problems += 1
          puts "NOT IN SNAPSHOT #{label}"
        elsif old[k] != v
          problems += 1
          puts "STALE #{label}: snapshot #{old[k]}, oracle now #{v}"
        end
      end
      Dir.chdir(File.expand_path('../../..', __dir__)) do
        each_volatile do |label, sources|
          emitted, theirs = compile_both(sources, oracle)
          next unless emitted && theirs

          seen[:live] += 1
          next if emitted == theirs

          problems += 1
          puts "EMITTER DIFFERS #{label}"
        end
      end
      if update
        (argv.empty? ? [] : argv.drop(1)).each do |f|
          File.foreach(f) { |l| (k, v = l.split) && tables[:world][k] = v if l =~ /\A\h{32} \h{32}\s*\z/ }
        end
        abort "snapshot.rb: #{problems} input(s) where the emitter differs from the oracle; not written" unless problems.zero?
        gen = "# generated by bc2cpp/tools/mrbc_rb/snapshot.rb --update; <key> <value>, see snapshot.rb\n"
        write(tables[:base], ["# oracle: #{oracle_id(oracle)}\n", gen])
        puts "wrote #{file}: #{tables[:base].size} entries"
        if world
          write(tables[:world], ["# world: #{pin || 'unknown'}\n", "# oracle: #{oracle_id(oracle)}\n", gen], world_file)
          puts "wrote #{world_file}: #{tables[:world].size} entries (world #{pin.to_s[0, 12]})"
        end
      else
        puts "snapshot --check: #{seen.inspect}, #{problems} problem(s); oracle #{oracle_id(oracle)}; snapshot header #{header.first.to_s.strip}"
        exit(problems.zero? ? 0 : 1)
      end
      problems.zero? ? 0 : 1
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require_relative 'golden_data'
  exit MrbcRb::Snapshot.run(ARGV)
end
