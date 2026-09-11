#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true
#
# A dynamic, CRuby-based companion to bc2cpp.rb's own
# `report_annotation_candidates` diagnostic (see that method's comment in
# tools/bc2cpp/bc2cpp.rb).
#
# report_annotation_candidates finds every SETIV site whose value comes from a
# bare, never-otherwise-resolved incoming argument -- exactly the set a
# `# bc2cpp: (T1, T2, ...) -> T3` magic comment (Annotations::COMMENT_RE)
# could unlock, structurally almost always #initialize (`X.new(args)` compiles
# to `SEND :new`, never a real bytecode `SEND :initialize`, so ArgTypes' own
# call-site scan can never see what a real `Foo.new(1, 2)` call site passes).
# It is silent on whether any candidate is *actually* Fixnum in practice --
# hand-inspection of real candidates shows most are not (object/Symbol
# references such as @state, @scene, @parent), and a wrong annotation raises a
# real TypeError at runtime (IvarLayout's embedded-ivar codegen always guards
# every embedded write with mrb_integer_p + mrb_raise, regardless of how the
# type was established -- see bc2cpp.rb's own comment on Annotations).
#
# This script replaces "read the source and guess" with real evidence: it
# runs bc2cpp.rb for real (the same MRBC / closed-world source list / NATIVE_SRCS
# mruby-rpg2k-compiled/mrbgem.rake and mruby-lcf-compiled/mrbgem.rake use) to
# get the live candidate list, then re-runs the project's own real CRuby
# game-logic harnesses (scripts/rpg2k_logic_check.rb and friends -- see
# DEFAULT_HARNESSES below) with a TracePoint(:call) probe installed, and
# records the actual Ruby class of the candidate argument on every real call
# any harness makes to any candidate method. A candidate every real observed
# call passed an Integer to gets a ready-to-paste annotation comment; anything
# else (including "never called by any harness in this environment") is
# reported honestly instead of guessed at.
#
# Each harness runs in its own clean `ruby` subprocess (not `load`ed into this
# process) -- these are large, independent scripts that each define their own
# top-level `check`/`ok`/`eq` helpers and their own RGSS stubs (a lightweight
# audio-only stub in rpg2k_logic_check.rb/rpg2k_testbed_logic_check.rb, a much
# larger Sprite/Bitmap/Viewport/Input/Graphics stub in rpg2k_scene_check.rb, a
# whole separate value-type/pixel-arithmetic compat layer in
# rgss_cruby_compat.rb for rgss_cruby_test_check.rb) that would collide if
# `load`ed together into one process. A TracePoint(:call), unlike a
# Module#prepend wrapper, needs no class to already exist at install time --
# it is enabled before anything is loaded and matches calls dynamically as
# real classes get defined -- so this same probe works unmodified regardless
# of which harness (or load order within one) is running.
#
# Usage:
#   MRBC=/path/to/mrbc ruby tools/bc2cpp/profile_annotations.rb
# Env:
#   MRBC             required -- same host mrbc the real mrbgem.rake builds use.
#   HARNESSES        optional, comma-separated harness script paths (relative
#                     to the repo root or absolute) to replace DEFAULT_HARNESSES.
#   NATIVE_SRCS      optional override for bc2cpp's own NATIVE_SRCS (defaults
#                     to mruby-rgss/src/*.cxx, matching both mrbgem.rake files).

require 'json'
require 'shellwords'
require 'tmpdir'
require 'fileutils'
require 'open3'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')

# The real CRuby game-logic harnesses this repo ships, in the order they are
# run. Each entry is [path relative to ROOT, one-line note on what it can
# realistically add evidence for -- printed in the final report so the tool's
# own coverage claims stay honest rather than implied].
#
# Left out on purpose: scripts/rpg2k_testbed_logic_check.rb,
# scripts/rpg2k_command_soak.rb and scripts/rpg2k_save_load_check.rb are real,
# genuine-data-driven harnesses (see rpg2k_testbed_logic_check.rb's own header
# comment), but every one of them needs a real RPG_RT.ldb test bed under
# ./data or an explicit game dir on ARGV -- absent here (see the coverage
# section of this tool's own report) they exit 0 having exercised nothing, so
# running them adds a data point ("no test bed available") rather than
# candidate evidence. rpg2k_testbed_logic_check.rb is still included below,
# specifically so that data point is real and re-checked every run rather than
# assumed -- the other two are pure duplicates of the same absence and are
# left out to keep the run fast.
DEFAULT_HARNESSES = [
  ['scripts/rpg2k_logic_check.rb',
   'fixture-based Game::*/LCF::* checks (hand-built Struct fixtures, not a real .ldb)'],
  ['scripts/rpg2k_scene_check.rb',
   'RPG2k::Scene::* (Map/Menu/ItemMenu/SkillMenu/EquipMenu/SaveLoad/Order/Battle/...) behind RGSS stubs'],
  ['scripts/rpg2k_testbed_logic_check.rb',
   'real RPG_RT.ldb test-bed driven Game::*/Interpreter checks -- only runs if ./data has one'],
  ['scripts/error_report_check.rb',
   'RGSS::ErrorReport::Tee'],
  ['scripts/rgss_cruby_test_check.rb',
   'mruby-rgss/test/test.rb under the CRuby RGSS compat layer (scripts/rgss_cruby_compat.rb)'],
].freeze

# ---------------------------------------------------------------------------
# Step 1: the real, live candidate list -- run bc2cpp.rb exactly the way
# mruby-rpg2k-compiled/mrbgem.rake and mruby-lcf-compiled/mrbgem.rake do (same
# MRBC, same closed-world source list: both rake files build the identical
# `Dir["mruby-rpg2k/mrblib/**/*.rb"] + Dir["mruby-lcf/mrblib/*.rb"] +
# Dir["mruby-rgss/mrblib/*.rb"]` set -- ONLY_OWNERS differs between them and
# report_annotation_candidates is never filtered by ONLY_OWNERS, so one run
# here reproduces the full project-wide candidate list either rake task's own
# bc2cpp invocation would report), and parse its `== annotation candidates ==`
# stderr section.
# ---------------------------------------------------------------------------
def live_candidates
  mrbc = ENV['MRBC'] || 'mrbc'
  closed_world = Dir[File.join(ROOT, 'mruby-rpg2k/mrblib/**/*.rb')] +
                 Dir[File.join(ROOT, 'mruby-lcf/mrblib/*.rb')] +
                 Dir[File.join(ROOT, 'mruby-rgss/mrblib/*.rb')]
  native_srcs = ENV['NATIVE_SRCS'] || Shellwords.join(Dir[File.join(ROOT, 'mruby-rgss/src/*.cxx')])

  out_dir = Dir.mktmpdir('bc2cpp_candidates')
  begin
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => 'profile_annotations_scan', 'OUT_DIR' => out_dir,
            'NATIVE_SRCS' => native_srcs }
    _stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, BC2CPP, *closed_world)
    unless status.success?
      warn stderr
      raise "bc2cpp.rb exited #{status.exitstatus} -- is MRBC (#{mrbc.inspect}) a real, working mrbc?"
    end
  ensure
    FileUtils.remove_entry(out_dir)
  end

  candidates = []
  stderr.each_line do |line|
    # Every group must be named, not just :ivar/:via -- Ruby treats *all*
    # plain groups in a pattern as non-capturing the moment any one named
    # group is present, so a mix (as this briefly, wrongly, was) silently
    # renumbers `owner`/`name`/`pos`/`mand` out from under m[1..4]. Caught
    # by running this against real output, not assumed.
    m = /^\s*CANDIDATE\s+(?<owner>[^#]+)#(?<name>.+), arg (?<pos>\d+)\/(?<mand>\d+) -> (?:@(?<ivar>\S+)|\((?<via>[^)]+)\))$/.match(line)
    next unless m

    candidates << { owner: m[:owner], name: m[:name], pos: m[:pos].to_i, mand: m[:mand].to_i,
                     ivar: m[:ivar], via: m[:via] }
  end
  raise 'bc2cpp.rb ran but reported no "== annotation candidates ==" section at all -- ' \
        'did tools/bc2cpp/bc2cpp.rb change shape?' if candidates.empty? && !stderr.include?('annotation candidates')

  candidates
end

# ---------------------------------------------------------------------------
# Step 2: the TracePoint probe library, generated once and `-r`'d into every
# harness subprocess. See this file's own header comment for why a TracePoint
# (rather than a Module#prepend wrapper installed after loading the target
# classes) is what lets one unmodified probe work across every harness.
# ---------------------------------------------------------------------------
PROBE_TEMPLATE = <<~'RUBY'
  require 'json'

  candidates = JSON.parse(File.read(ENV.fetch('BC2CPP_PROFILE_CANDIDATES')), symbolize_names: true)
  positions_by_target = Hash.new { |h, k| h[k] = [] }
  candidates.each { |c| positions_by_target[[c[:owner], c[:name]]] << c[:pos] }
  positions_by_target.each_value(&:uniq!)
  target_method_names = positions_by_target.keys.map { |(_o, n)| n }.to_set

  recorder = Hash.new { |h, k| h[k] = { 'calls' => 0, 'classes' => Hash.new(0) } }

  probe_tp = TracePoint.new(:call) do |tp|
    mid = tp.method_id.to_s
    next unless target_method_names.include?(mid)

    owner = tp.defined_class&.name
    next unless owner

    positions = positions_by_target[[owner, mid]]
    next if positions.empty?

    # Only the *leading* run of required (:req) parameters corresponds to
    # bc2cpp's own `pos` -- it comes from ENTER's `mandatory1` field, mruby's
    # count of mandatory args *before* any optional/rest/post-mandatory ones
    # (see bc2cpp.rb's own pure_mandatory_arity? and report_annotation_candidates
    # comments) -- so this must stop at the first non-:req parameter rather
    # than collecting every :req entry in the signature (Ruby's own
    # TracePoint#parameters reports a post-optional mandatory arg as :req too).
    leading_req = []
    tp.parameters.each do |type, pname|
      break unless type == :req

      leading_req << pname
    end

    positions.each do |pos|
      pname = leading_req[pos - 1]
      next unless pname

      begin
        val = tp.binding.local_variable_get(pname)
      rescue NameError
        next
      end
      rec = recorder["#{owner}\x00#{mid}\x00#{pos}"]
      rec['calls'] += 1
      rec['classes'][val.class.name] += 1
    end
  end
  probe_tp.enable

  # at_exit fires on every exit path -- a clean finish, `exit 1` from a
  # harness's own failure summary (Kernel#exit still runs at_exit hooks), or
  # an uncaught exception -- so whatever was recorded up to that point is
  # never lost even when a harness's own checks fail partway through.
  at_exit do
    probe_tp.disable
    File.write(ENV.fetch('BC2CPP_PROFILE_OUT'), JSON.generate(recorder))
  end
RUBY

# ---------------------------------------------------------------------------
# Step 3: run every harness in its own subprocess with the probe installed,
# merging each one's recorded evidence into one combined map.
# ---------------------------------------------------------------------------
def profile_harnesses(candidates, harnesses)
  Dir.mktmpdir('bc2cpp_profile') do |dir|
    candidates_json = File.join(dir, 'candidates.json')
    File.write(candidates_json, JSON.generate(candidates))
    probe_path = File.join(dir, 'probe.rb')
    File.write(probe_path, PROBE_TEMPLATE)

    merged = Hash.new { |h, k| h[k] = { 'calls' => 0, 'classes' => Hash.new(0), 'harnesses' => [] } }

    harnesses.each_with_index do |(rel_path, note), idx|
      path = File.absolute_path?(rel_path) ? rel_path : File.join(ROOT, rel_path)
      unless File.exist?(path)
        warn "  (skipping #{rel_path} -- not found)"
        next
      end

      out_path = File.join(dir, "out_#{idx}.json")
      env = { 'BC2CPP_PROFILE_CANDIDATES' => candidates_json, 'BC2CPP_PROFILE_OUT' => out_path }
      warn "== running #{rel_path} (#{note}) =="
      _stdout, _stderr, status = Open3.capture3(env, RbConfig.ruby, '-r', probe_path, path,
                                                 chdir: ROOT)
      warn "   exit #{status.exitstatus}#{status.success? ? '' : ' (non-clean exit -- recorded evidence up to that point still counted, see this harness\'s own note above)'}"

      next unless File.exist?(out_path)

      data = JSON.parse(File.read(out_path))
      data.each do |key, rec|
        m = merged[key]
        m['calls'] += rec['calls']
        rec['classes'].each { |cls, n| m['classes'][cls] = (m['classes'][cls] || 0) + n }
        m['harnesses'] << rel_path if rec['calls'].positive?
      end
    end

    merged
  end
end

# ---------------------------------------------------------------------------
# Step 4: the report -- one line per live candidate, using only what was
# really observed.
# ---------------------------------------------------------------------------
def report(candidates, merged)
  resolvable = 0
  puts ''
  puts '== profiled annotation candidates =='

  # Grouped by method, not printed one candidate at a time: a method with
  # several candidate positions (e.g. Game::State#initialize, mand=4) must
  # not get a separate "ready to paste" comment per position, each
  # independently claiming *every* mandatory position is fixnum -- only
  # the specific position that call site's own evidence actually covers.
  # Real bug this replaced: the first version filled every slot in
  # `(['fixnum'] * mand).join(', ')` regardless of which single position
  # `c` was for, so a method with 4 mandatory args and only arg 2
  # confirmed printed a comment claiming positions 1, 3 and 4 were also
  # fixnum -- never observed at all. Caught before this file was
  # integrated, not shipped.
  candidates.group_by { |c| [c[:owner], c[:name]] }.each do |(owner, name), method_candidates|
    mand = method_candidates.first[:mand]
    confirmed = {} # pos -> true once real evidence confirms it Integer-only.

    method_candidates.each do |c|
      key = "#{c[:owner]}\x00#{c[:name]}\x00#{c[:pos]}"
      rec = merged[key]
      target = c[:ivar] ? "@#{c[:ivar]}" : "(#{c[:via]})"
      label = "#{owner}##{name}, arg #{c[:pos]}/#{mand} -> #{target}"

      if rec.nil? || rec['calls'].zero?
        puts "  #{label}"
        puts '      NO EVIDENCE -- never called by any harness run here'
        next
      end

      classes = rec['classes']
      calls = rec['calls']
      harnesses = rec['harnesses'].uniq.join(', ')

      if classes.size == 1 && classes.key?('Integer')
        confirmed[c[:pos]] = true
        puts "  #{label}"
        puts "      fixnum (#{calls} real call#{'s' unless calls == 1} observed, all Integer -- via #{harnesses})"
      else
        types = classes.sort_by { |_k, n| -n }.map { |cls, n| "#{cls}:#{n}" }.join(', ')
        puts "  #{label}"
        puts "      #{types} -- not annotatable (#{calls} real call#{'s' unless calls == 1} observed via #{harnesses})"
      end
    end

    next if confirmed.empty?

    resolvable += confirmed.size
    # Only positions this run actually confirmed get a `fixnum` token; every
    # other mandatory position (no evidence here, or genuinely not
    # Fixnum-shaped) is left blank -- a real, already-supported partial
    # annotation (Annotations::TYPES[''] parses to nil, the same "no claim"
    # an unrecognized token already gets -- see bc2cpp.rb's own Annotations
    # class), never a position this run has zero evidence for. No `-> T`
    # either: this tool only ever observes incoming *arguments* (a
    # TracePoint(:call) probe), never a method's own return value, so
    # claiming a return type here would be pure guesswork.
    sig = (1..mand).map { |pos| confirmed[pos] ? 'fixnum' : '' }.join(', ')
    puts "  ==> #{owner}##{name}:  # bc2cpp: (#{sig})"
  end

  puts ''
  puts "== summary: #{resolvable} of #{candidates.size} candidate position(s) confidently resolvable to fixnum from real evidence =="
end

if $PROGRAM_NAME == __FILE__
  require 'set' # pulled in by the generated probe too; harmless to require twice here.

  candidates = live_candidates
  warn "#{candidates.size} live annotation candidate(s) from bc2cpp.rb"

  harnesses = if ENV['HARNESSES']
                ENV['HARNESSES'].split(',').map { |p| [p, '(explicit HARNESSES override)'] }
              else
                DEFAULT_HARNESSES
              end

  merged = profile_harnesses(candidates, harnesses)
  report(candidates, merged)
end
