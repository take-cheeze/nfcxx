#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true
#
# A dynamic companion to bc2cpp.rb's `report_annotation_candidates`: that
# diagnostic lists SETIV sites fed by a bare incoming argument (almost always
# #initialize, since `X.new(args)` is `SEND :new` and ArgTypes never sees the
# arguments), which a `# bc2cpp: (T1, ...) -> T3` comment could unlock, but not
# whether the argument is actually Fixnum. A wrong annotation raises TypeError
# at runtime (every embedded write is guarded by mrb_integer_p).
#
# This runs bc2cpp.rb the way the *-compiled mrbgem.rake files do to get the
# live candidates, then runs the CRuby game-logic harnesses (DEFAULT_HARNESSES)
# under a TracePoint(:call) probe and records the argument classes actually
# passed. Only a candidate every observed call passed an Integer (or one other
# single class) gets a ready-to-paste annotation; everything else, including
# "never called", is reported as such.
#
# Each harness runs in its own `ruby` subprocess: they define colliding
# top-level helpers and RGSS stubs. TracePoint (unlike Module#prepend) needs no
# class to exist when installed, so one probe works for every harness.
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

# [path relative to ROOT, note on what it can add evidence for], run in order;
# the note is printed in the report.
#
# scripts/rpg2k_command_soak.rb and scripts/rpg2k_save_load_check.rb are left
# out: like rpg2k_testbed_logic_check.rb they need a real RPG_RT.ldb test bed
# and exercise nothing without one. rpg2k_testbed_logic_check.rb stays so the
# "no test bed" data point is re-checked every run.
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
# Step 1: the live candidate list. Both rake files use the same closed-world
# source set and report_annotation_candidates ignores ONLY_OWNERS, so one run
# reproduces the project-wide list. Parses `== annotation candidates ==`.
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
    # Every group must be named: once one named group is present, Ruby makes
    # plain groups non-capturing, which would silently renumber m[1..4].
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
# harness subprocess.
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

  # Grouped by method: a method with several candidate positions must get one
  # comment claiming only the positions the evidence covers, not one comment per
  # position claiming every mandatory position is fixnum.
  class_resolvable = 0
  candidates.group_by { |c| [c[:owner], c[:name]] }.each do |(owner, name), method_candidates|
    mand = method_candidates.first[:mand]
    confirmed = {} # pos -> true once real evidence confirms it Integer-only.
    confirmed_class = {} # pos -> real class name once real evidence confirms exactly one, non-primitive class.

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

      # `classes.size == 1` is the "every real call agreed" bar: Integer gives the
      # fixnum annotation (feeds ivar embedding), any other single class the class
      # annotation. ClassAnnotations' known_owners gate ignores a test-fixture
      # stand-in (OpenStruct, FakeActorDB, ...) when the comment is applied.
      if classes.size == 1 && classes.key?('Integer')
        confirmed[c[:pos]] = true
        puts "  #{label}"
        puts "      fixnum (#{calls} real call#{'s' unless calls == 1} observed, all Integer -- via #{harnesses})"
      elsif classes.size == 1 && classes.keys.first =~ /\A[A-Z]\w*(::[A-Z]\w*)*\z/
        confirmed_class[c[:pos]] = classes.keys.first
        puts "  #{label}"
        puts "      #{classes.keys.first} (#{calls} real call#{'s' unless calls == 1} observed, always this one class -- via #{harnesses})"
      else
        types = classes.sort_by { |_k, n| -n }.map { |cls, n| "#{cls}:#{n}" }.join(', ')
        puts "  #{label}"
        puts "      #{types} -- not annotatable (#{calls} real call#{'s' unless calls == 1} observed via #{harnesses})"
      end
    end

    if confirmed.any?
      resolvable += confirmed.size
      # Unconfirmed positions stay blank (Annotations::TYPES[''] is "no claim").
      # No `-> T`: the probe only sees incoming arguments, never return values.
      sig = (1..mand).map { |pos| confirmed[pos] ? 'fixnum' : '' }.join(', ')
      puts "  ==> #{owner}##{name}:  # bc2cpp: (#{sig})"
    end

    next if confirmed_class.empty?

    class_resolvable += confirmed_class.size
    # A separate line: Annotations and ClassAnnotations read the same syntax, and
    # Integer vs. "always one other class" are mutually exclusive outcomes.
    class_sig = (1..mand).map { |pos| confirmed_class[pos] || '' }.join(', ')
    puts "  ==> #{owner}##{name}:  # bc2cpp: (#{class_sig})"
  end

  puts ''
  puts "== summary: #{resolvable} of #{candidates.size} candidate position(s) confidently resolvable to fixnum, " \
       "#{class_resolvable} to a known class, from real evidence =="
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
