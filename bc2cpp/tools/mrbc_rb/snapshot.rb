# frozen_string_literal: true

# The oracle without the oracle: a table of what the fork's `mrbc -g` wrote for every input bc2cpp and its tests compile, so
# the emitter's bytes can be checked against it where no mrbc is built (BC2CPP_MRBC_RB=snapshot, golden_test.rb, cli_test.rb).
#
# The table (snapshot.txt next to this file; BC2CPP_MRBC_SNAPSHOT=<file> overrides) is a sorted text file, one line per input:
#   <key> <value>
#   key   = first 32 hex digits of SHA-256 over "g\n", the number of files, and for each file in command-line order the SHA-256 of
#           its content. The file names are not part of the key (they are not part of what decides the output, see below).
#   value = first 32 hex digits of SHA-256 of the oracle's RITE image with the DBG file names neutralised (RiteDump.neutral_files).
# The one place where a name does matter is a source that reads its own name (__FILE__, __dir__): the name ends up in the image's
# string pool. For such an input the key also hashes the file names as given, so it only matches where it was recorded (the
# check then says "not in snapshot" instead of passing wrongly). Lines starting with # are the header (what the oracle was).
#
#   ruby snapshot.rb --update [--prune] [--from-record FILE...]
#                                                       needs MRBC (the oracle): compile every enumerated input with both, refuse
#                                                       to write when the emitter differs, merge the record files; --prune first
#                                                       drops the entries no enumerated input or record file gives
#   ruby snapshot.rb --check                            needs MRBC: every enumerated input is in the table and the oracle still
#                                                       gives the recorded value (drift of the oracle or an incomplete table fail)
#   ruby snapshot.rb --verify                           no oracle: the emitter's bytes against the table for every enumerated input
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
    PATH_DEPENDENT = /__FILE__|__dir__/

    NotInSnapshot = Class.new(StandardError)

    module_function

    def file = ENV.fetch('BC2CPP_MRBC_SNAPSHOT', DEFAULT_FILE)

    def digest(bytes) = Digest::SHA256.hexdigest(bytes)

    # +sources+: [[content, path], ...] in command-line order.
    def key(sources)
      parts = sources.map { |src, _| digest(src.b) }
      parts.concat(sources.map { |_, path| "path:#{path}" }) if sources.any? { |src, _| src.b.match?(PATH_DEPENDENT) }
      digest("g\n#{sources.size}\n#{parts.join("\n")}")[0, 32]
    end

    def value(image) = digest(RiteDump.neutral_files(image))[0, 32]

    def load(path = file)
      table = {}
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

    @tables = {}
    def table(path = file) = (@tables[path] ||= load(path))

    # :ok, or raises NotInSnapshot / returns :differs. +image+ is the emitter's output for +sources+.
    def check(sources, image, path = file)
      recorded = table(path)[key(sources)]
      raise NotInSnapshot, "input not in snapshot, run snapshot.rb --update with the oracle (#{sources.first&.last}#{sources.size > 1 ? " +#{sources.size - 1}" : ''})" unless recorded

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

      SNIPPETS.each_with_index { |s, i| yield "snippet #{i}", [["#{s}\n", 't.rb']] }
      MULTI_FILE_GROUPS.each_with_index do |g, gi|
        yield "group #{gi}", g.each_with_index.map { |s, i| [s, "g#{gi}_#{i}.rb"] }
      end
      return unless world

      mruby = File.join(world, '3rd/mruby')
      sets = { 'core mrblib' => Dir["#{mruby}/mrblib/*.rb"].sort.reject { |p| p.end_with?('/10error.rb') } }
      (Dir["#{mruby}/mrbgems/*"] + Dir["#{world}/3rd/*"] + Dir["#{world}/mruby-*"]).sort.each do |gem_dir|
        sets[File.basename(gem_dir)] = Dir["#{gem_dir}/mrblib/**/*.rb"].sort
      end
      sets.each do |name, files|
        next if files.empty?

        ([files] + (files.size > 1 ? files.each_cons(2).to_a : [])).each { |ps| yield "#{name} (#{ps.size})", ps.map { |p| [File.binread(p), p] } }
        files.each { |p| yield p, [[File.binread(p), p]] } if files.size > 1
      end
      (Dir["#{world}/scripts/**/*.rb"] + Dir["#{world}/mruby-*/**/*.rb"] + Dir["#{world}/3rd/optcarrot/lib/**/*.rb"]).sort.uniq.each do |p|
        yield p, [[File.binread(p), p]]
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
      emitted = begin
        sources.size == 1 ? MrbcRb.compile(sources[0][0], sources[0][1]) : MrbcRb.compile_files(sources)
      rescue MrbcRb::Error
        nil
      end
      Dir.mktmpdir('snapshot') do |dir|
        # the oracle sees the names the input has: a file is read where it is, a snippet is written under its name in a
        # scratch directory the oracle runs in
        on_disk = sources.all? { |src, path| File.file?(path) && File.binread(path) == src.b }
        sources.each { |src, path| File.binwrite(File.join(dir, path), src) } unless on_disk
        out = File.join(dir, 'o.mrb')
        names = sources.map(&:last)
        opts = on_disk ? {} : { chdir: dir }
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
      t = load
      raw = File.size(file)
      puts "#{t.size} entries, #{raw} bytes (#{(raw.to_f / t.size).round(1)} per entry)"
      0
    end

    def verify(*)
      bad = missing = ok = skipped = 0
      each_input do |label, sources|
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
      table = update && !prune && File.exist?(file) ? load : {}
      old = update ? table.dup : load
      problems = 0
      seen = Hash.new(0)
      each_input do |label, sources|
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
          table[k] = v
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
          File.foreach(f) { |l| (k, v = l.split) && table[k] = v if l =~ /\A\h{32} \h{32}\s*\z/ }
        end
        abort "snapshot.rb: #{problems} input(s) where the emitter differs from the oracle; not written" unless problems.zero?
        hdr = ["# oracle: #{oracle_id(oracle)}\n", "# generated by bc2cpp/tools/mrbc_rb/snapshot.rb --update; <key> <value>, see snapshot.rb\n"]
        write(table, hdr)
        puts "wrote #{file}: #{table.size} entries"
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
