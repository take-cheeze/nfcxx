#!/usr/bin/env ruby
# frozen_string_literal: true

# Fixture check for scripts/bc2cpp/promote_candidates.rb (tools/bc2cpp/promote_candidates.rb). Host only: no mrbc, no
# clang, no closed build. Every target and candidate directory is a temporary copy.
#
#   ruby scripts/bc2cpp/promote_candidates_check.rb
#
# Checks: a dry run writes nothing; existing declarations are never changed; untyped and undeclared members are skipped
# and listed; a candidate carrying base-section lines is refused; a target without the block_types line is refused;
# a target that does not parse is refused; a write adds the absent members, leaves the base section byte for byte and
# parses again; a second write changes nothing. With --proofs (the TC1011 verdicts of bc2cpp's declared-constant check):
# a constant the check rejects is skipped, an Integer or Array constant without a verdict is skipped, other constants
# are not gated, a verdict file for another directory or of another shape is refused, and the write leaves the target
# unchanged when the file is refused.

require 'digest'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/bc2cpp/promote_candidates'

ROOT = File.expand_path('../..', __dir__)
CLI = File.join(ROOT, 'scripts/bc2cpp/promote_candidates.rb')
failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

TARGET = <<~RBS
  # ---- base stubs (fixture)
  # Base RBS (scripts/bc2cpp/base_rbs.rb): shapes from the AST, no types.
  # bc2cpp-native: base_fixture
  class Game::Actor
    def base_only: () -> untyped
  end

  # ---- block_types.rbs
  class Game::Actor
    def existing: () -> Integer
    def self.make: (Integer) -> Game::Actor
    @hp: Integer
    LIMIT: Integer
  end

  class Game::Party
  end
RBS

# The candidate directory name is the heading's name, so it is fixed here.
CANDIDATES = {
  'Game/Actor.rbs' => <<~RBS,
    # Inferred from the fixture program (type_check.rb --emit-rbs-suggestions).
    # Written 2026-10-23 by the fixture: a dated line is not carried over.
    class Game::Actor
      def existing: () -> String
      def name: () -> String
      def level: () -> untyped
      def hp_gain: (untyped) -> Integer
      def self.build: (Integer) -> Game::Actor
      def gold: () -> Game::Wallet
      def base_only: () -> Integer
      @name: String
      @hp: String
      TITLE: String
      LIMIT: String
      private
      def secret: () -> nil
    end
  RBS
  'Game/Party.rbs' => "class Game::Party\n  def size: () -> Integer\nend\n",
  'Game/Fresh.rbs' => "class Game::Fresh < Game::Actor\n  def greet: () -> String\nend\n",
  'Game/Orphan.rbs' => "class Game::Orphan < Game::Missing\n  def wave: () -> Integer\nend\n",
  'Game/Drawable.rbs' => "interface _Drawable\n  def draw: () -> void\nend\n"
}.freeze

def write_candidates(root, files)
  dir = File.join(root, 'rbs-suggestions')
  files.each do |rel, text|
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
  dir
end

def snapshot(dir)
  Dir.glob(File.join(dir, '**', '*')).sort.to_h { |p| [p, File.file?(p) ? Digest::SHA256.file(p).hexdigest : nil] }
end

def base_of(text)
  text[0...text.index(PromoteCandidates::END_MARKER)]
end

Dir.mktmpdir('promote-candidates') do |root|
  target = File.join(root, 'declarations.rbs')
  File.write(target, TARGET)
  candidates = write_candidates(root, CANDIDATES)
  before = snapshot(root)
  label = target

  puts 'fixture: dry run through the command line'
  out, err, status = Open3.capture3(RbConfig.ruby, CLI, '--target', target, candidates)
  check.call('the dry run exits 0', status.success?)
  check.call('the dry run writes nothing (target and candidate files unchanged)', snapshot(root) == before)
  check.call('the dry run prints a unified diff of the target', out.include?("--- a/#{label}") && out.include?("+  def name: () -> String"))
  check.call('the dry run lists the untyped return as skipped', out.include?('skip  Game::Actor#level: untyped'))
  check.call('the dry run lists the untyped parameter as skipped', out.include?('skip  Game::Actor#hp_gain: untyped'))
  check.call('the dry run lists the undeclared type as skipped', out.include?('Game::Wallet is not declared by the target'))
  check.call('the dry run lists the undeclared superclass as skipped',
             out.include?('Game::Orphan: superclass Game::Missing is not declared by the target'))
  check.call('the dry run says it wrote nothing', out.include?('dry run: nothing written'))
  check.call('the dry run prints no error', err.empty?)

  puts 'fixture: the plan'
  plan = PromoteCandidates.plan(File.read(target), candidates, target_label: label)
  text = plan.text
  check.call('the target is only appended to (every existing line is kept, in order)', text.start_with?(TARGET))
  check.call('the base section is byte for byte the same', base_of(text) == base_of(TARGET))
  check.call('an existing method keeps its declaration (existing: () -> Integer)',
             text.include?('def existing: () -> Integer') && !text.include?('def existing: () -> String'))
  check.call('an existing ivar keeps its declaration (@hp: Integer)', !text.include?('@hp: String'))
  check.call('an existing constant is not written again (LIMIT: String is absent)', !text.include?('LIMIT: String'))
  check.call('a method declared only in the base section is not promoted again',
             plan.already.positive? && text.scan('def base_only').size == 1)
  check.call('an absent instance method is added (name)', text.include?("class Game::Actor\n  def name: () -> String\n"))
  check.call('an absent singleton method is added (self.build)', text.include?('  def self.build: (Integer) -> Game::Actor'))
  check.call('an absent ivar and constant are added', text.include?('  @name: String') && text.include?('  TITLE: String'))
  check.call('an untyped method, parameter and undeclared type are not written',
             !text.include?('def level') && !text.include?('def hp_gain') && !text.include?('def gold'))
  check.call('a private candidate method is added under private', text.include?("  private\n  def secret: () -> nil"))
  check.call('a new class with a declared superclass keeps the header', text.include?('class Game::Fresh < Game::Actor'))
  check.call('a new class with an undeclared superclass is not written', !text.include?('Game::Orphan'))
  check.call('a reopened class is written without a superclass', text.include?("class Game::Party\n  def size: () -> Integer\nend"))
  check.call('the heading names the candidate directory', text.include?('# ---- promoted candidates: rbs-suggestions'))
  check.call('the provenance comment is carried over and its dated line is dropped',
             text.include?("# Inferred from the fixture program (type_check.rb --emit-rbs-suggestions).\nclass Game::Actor\n") &&
             !text.include?('2026-10-23'))
  check.call('the plan lists a skipped member with its reason', plan.skipped.any? { |what, why| what == 'Game::Actor#level' && why == 'untyped' })
  check.call('a top-level interface is listed as not promoted, not dropped silently',
             plan.skipped.any? { |what, why| what.end_with?('Drawable.rbs') && why.include?('not promoted') } &&
             !text.include?('_Drawable'))

  puts 'fixture: refusals'
  Dir.mktmpdir('promote-candidates-base') do |dir|
    marked = write_candidates(dir, 'Game/Actor.rbs' => "# bc2cpp-native: base_fixture\nclass Game::Actor\n  def x: () -> Integer\nend\n")
    refused = begin
      PromoteCandidates.plan(File.read(target), marked, target_label: label)
      nil
    rescue PromoteCandidates::Refusal => e
      e.message
    end
    check.call('a candidate with a base-section line is refused and the message says so',
               refused.to_s.include?('base-section line') && refused.to_s.include?('base_section_check.rb'))
    out2, _err2, status2 = Open3.capture3(RbConfig.ruby, CLI, '--write', '--target', target, marked)
    check.call('the write is refused with exit 1 for a base-section candidate', status2.exitstatus == 1)
    check.call('the refused write leaves the target unchanged', File.read(target) == TARGET)
    check.call('the refused write prints nothing as a success', !out2.include?('wrote'))
  end

  Dir.mktmpdir('promote-candidates-noblock') do |dir|
    noblock = File.join(dir, 'declarations.rbs')
    File.write(noblock, "class Game::Actor\n  def existing: () -> Integer\nend\n")
    refused = begin
      PromoteCandidates.plan(File.read(noblock), candidates, target_label: noblock)
      nil
    rescue PromoteCandidates::Refusal => e
      e.message
    end
    check.call('a target without the block_types line is refused', refused.to_s.include?('block_types.rbs'))
  end

  Dir.mktmpdir('promote-candidates-broken') do |dir|
    broken = File.join(dir, 'declarations.rbs')
    broken_text = "# ---- block_types.rbs\nclass Broken\n  def x: (\nend\n"
    File.write(broken, broken_text)
    refused = begin
      PromoteCandidates.plan(broken_text, candidates, target_label: broken)
      nil
    rescue PromoteCandidates::Refusal => e
      e.message
    end
    check.call('a target that does not parse is refused and the message says it was not promoted',
               refused.to_s.include?('does not parse') && refused.to_s.include?('nothing was promoted'))
    out3, _err3, status3 = Open3.capture3(RbConfig.ruby, CLI, '--write', '--target', broken, candidates)
    check.call('the write into an unparseable target exits 1', status3.exitstatus == 1)
    check.call('the write into an unparseable target changes nothing', File.read(broken) == broken_text && !out3.include?('wrote'))
    check.call('the post-write check reports a file that does not parse and passes one that does',
               !PromoteCandidates.written_error(broken).nil? && PromoteCandidates.written_error(target).nil?)
  end

  puts 'fixture: write through the command line'
  out4, err4, status4 = Open3.capture3(RbConfig.ruby, CLI, '--write', '--target', target, candidates)
  check.call('the write exits 0', status4.success?)
  check.call('the write reports that the file parses', out4.include?('the file parses with RBS') && err4.empty?)
  written = File.read(target)
  check.call('the written file equals the planned text', written == text)
  check.call('the written file parses with RBS', PromoteCandidates.verify(written).nil?)
  check.call('the written base section is byte for byte the same', base_of(written) == base_of(TARGET))
  out5, _err5, status5 = Open3.capture3(RbConfig.ruby, CLI, '--write', '--target', target, candidates)
  check.call('a second write exits 0 and reports nothing to promote',
             status5.success? && out5.include?('nothing to promote; the target is unchanged'))
  check.call('a second write changes nothing', File.read(target) == written)
end

puts 'fixture: constant proofs (--proofs)'
PROOF_TARGET = "# ---- block_types.rbs\nclass Game::Actor\n  def existing: () -> Integer\nend\n"
PROOF_CANDIDATES = {
  'Game/Actor.rbs' => <<~RBS
    class Game::Actor
      LIMIT: Integer
      RATE: Integer
      SLOTS: Integer
      WIDE: Integer
      TITLE: String
      ITEMS: Array[Integer]
    end
  RBS
}.freeze
PROOF_VERDICTS = {
  'Game::Actor::LIMIT' => nil,
  'Game::Actor::WIDE' => nil,
  'Game::Actor::RATE' => 'Game::Actor::RATE: Integer (candidate.rbs:3): the assigned value is not a proven Fixnum expression'
}.freeze
Dir.mktmpdir('promote-candidates-proofs') do |root|
  target = File.join(root, 'declarations.rbs')
  File.write(target, PROOF_TARGET)
  candidates = write_candidates(root, PROOF_CANDIDATES)
  proofs_path = File.join(root, 'proofs.json')
  File.write(proofs_path, JSON.generate('version' => 1, 'candidates' => 'rbs-suggestions', 'verdicts' => PROOF_VERDICTS))
  label = target

  verdicts = PromoteCandidates.load_proofs(proofs_path, candidates)
  check.call('load_proofs returns the verdicts keyed by constant name', verdicts == PROOF_VERDICTS)

  bare = PromoteCandidates.plan(File.read(target), candidates, target_label: label)
  check.call('without proofs every absent constant is added as before (RATE: Integer, SLOTS: Integer)',
             bare.text.include?('  RATE: Integer') && bare.text.include?('  SLOTS: Integer'))

  plan = PromoteCandidates.plan(File.read(target), candidates, target_label: label, proofs: verdicts)
  text = plan.text
  check.call('a constant the check accepts is added (LIMIT: Integer, WIDE: Integer)',
             text.include?('  LIMIT: Integer') && text.include?('  WIDE: Integer'))
  check.call('a constant the check rejects (TC1011) is not written (RATE: Integer is absent)', !text.include?('RATE: Integer'))
  check.call('an Integer constant with no verdict is not written (SLOTS: Integer is absent)', !text.include?('SLOTS: Integer'))
  check.call('an Array constant with no verdict is not written (ITEMS is absent)', !text.include?('ITEMS'))
  check.call('a String constant is not gated by the proofs (TITLE: String is added)', text.include?('  TITLE: String'))
  check.call('the rejected constant is listed with its TC1011 reason',
             plan.skipped.any? { |what, why| what == 'Game::Actor::RATE' && why.start_with?('TC1011: ') && why.include?('not a proven Fixnum expression') })
  check.call('the unverdicted Integer constant is listed with a no-proof reason',
             plan.skipped.any? { |what, why| what == 'Game::Actor::SLOTS' && why.start_with?('no proof fact: Game::Actor::SLOTS') })
  check.call('the base section stays byte for byte the same', base_of(text) == base_of(PROOF_TARGET))

  Dir.mktmpdir('promote-candidates-proofs-bad') do |dir|
    wrong_dir = File.join(dir, 'proofs.json')
    File.write(wrong_dir, JSON.generate('version' => 1, 'candidates' => 'other-dir', 'verdicts' => PROOF_VERDICTS))
    refused = begin
      PromoteCandidates.load_proofs(wrong_dir, candidates)
      nil
    rescue PromoteCandidates::Refusal => e
      e.message
    end
    check.call('a proofs file written for another candidate directory is refused', refused.to_s.include?('was written for "other-dir"'))

    wrong_version = File.join(dir, 'version.json')
    File.write(wrong_version, JSON.generate('version' => 2, 'candidates' => 'rbs-suggestions', 'verdicts' => {}))
    refused = begin
      PromoteCandidates.load_proofs(wrong_version, candidates)
      nil
    rescue PromoteCandidates::Refusal => e
      e.message
    end
    check.call('a proofs file of another version is refused', refused.to_s.include?('not a version 1 constant proofs file'))

    not_json = File.join(dir, 'broken.json')
    File.write(not_json, '{ "verdicts": ')
    refused = begin
      PromoteCandidates.load_proofs(not_json, candidates)
      nil
    rescue PromoteCandidates::Refusal => e
      e.message
    end
    check.call('a proofs file that is not JSON is refused, not ignored', refused.to_s.include?('cannot be read as a constant proofs file'))

    bad_verdict = File.join(dir, 'bad-verdict.json')
    File.write(bad_verdict, JSON.generate('version' => 1, 'candidates' => 'rbs-suggestions', 'verdicts' => { 'A::B' => 3 }))
    refused = begin
      PromoteCandidates.load_proofs(bad_verdict, candidates)
      nil
    rescue PromoteCandidates::Refusal => e
      e.message
    end
    check.call('a verdict that is neither null nor a message is refused', refused.to_s.include?('not a version 1 constant proofs file'))
  end

  before_cli = snapshot(root)
  out, err, status = Open3.capture3(RbConfig.ruby, CLI, '--proofs', proofs_path, '--target', target, candidates)
  check.call('the dry run with --proofs exits 0 and prints no error', status.success? && err.empty?)
  check.call('the dry run with --proofs names the proofs file', out.include?("constants: checked against #{proofs_path} (TC1011)"))
  check.call('the dry run with --proofs lists the TC1011 skip', out.include?('skip  Game::Actor::RATE: TC1011: '))
  check.call('the dry run with --proofs writes nothing', snapshot(root) == before_cli)
  out_none, _err_none, _status_none = Open3.capture3(RbConfig.ruby, CLI, '--target', target, candidates)
  check.call('the dry run without --proofs says constants are not checked', out_none.include?('constants: not checked against TC1011 (no --proofs)'))

  before_bad = File.read(target)
  broken_proofs = File.join(root, 'broken-proofs.json')
  File.write(broken_proofs, '{ "verdicts": ')
  _bad_out, bad_err, bad_status = Open3.capture3(RbConfig.ruby, CLI, '--write', '--proofs', broken_proofs, '--target', target, candidates)
  check.call('a write with an unreadable proofs file exits 1 and says why', bad_status.exitstatus == 1 && bad_err.include?('promote_candidates: refused'))
  check.call('a refused proofs file leaves the target unchanged', File.read(target) == before_bad)

  _w_out, w_err, w_status = Open3.capture3(RbConfig.ruby, CLI, '--write', '--proofs', proofs_path, '--target', target, candidates)
  written = File.read(target)
  check.call('the write with --proofs exits 0 and the file parses', w_status.success? && w_err.empty? && PromoteCandidates.verify(written).nil?)
  check.call('the written file has the accepted constants and not the rejected one',
             written.include?('  LIMIT: Integer') && !written.include?('RATE: Integer') && !written.include?('SLOTS: Integer'))
end

if failures.empty?
  puts "promote_candidates: #{checks} checks passed"
else
  warn "promote_candidates: #{failures.size} of #{checks} checks failed"
  failures.each { |f| warn "  #{f}" }
  exit 1
end
