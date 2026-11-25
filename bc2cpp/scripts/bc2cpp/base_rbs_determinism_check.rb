#!/usr/bin/env ruby
# frozen_string_literal: true

# The base RBS generators write the same bytes whatever surrounds the run: scripts/bc2cpp/base_rbs.rb over the world's
# mrblib, and scripts/bc2cpp/base_rbs_native.rb over a fixture (when clang or the nfcxx front end is available), each run
# twice in child processes that differ in locale, TZ, TMPDIR, the source and output directories and the native workers.
# The writer's half (the section layout depends on the generator output only) is base_section_regen_check.rb. Host only.
#
#   ruby scripts/bc2cpp/base_rbs_determinism_check.rb

require_relative '../../tools/bc2cpp/world_root'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/bc2cpp/native_ast_source'
require_relative 'base_rbs_all'

ROOT = BC2CPP_WORLD_ROOT
failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# Two runs' surroundings. The second directory names hold a space and a non-ASCII byte, and sort apart from the first.
VARIANTS = [
  { dir: 'a', jobs: 1, env: { 'LC_ALL' => 'C', 'LANG' => 'C', 'TZ' => 'UTC' } },
  { dir: "z run/ü", jobs: 3, env: { 'LC_ALL' => 'ja_JP.UTF-8', 'LANG' => 'ja_JP.UTF-8', 'TZ' => 'Asia/Tokyo' } }
].freeze

# { relative path => bytes } of every file under +dir+.
def tree(dir)
  Dir.glob('**/*', base: dir).sort.select { |rel| File.file?(File.join(dir, rel)) }.to_h { |rel| [rel, File.binread(File.join(dir, rel))] }
end

# Copies +rels+ (relative to +from+) under +to+, so a run reads the same sources at another path.
def copy_sources(from, rels, to)
  rels.map do |rel|
    dest = File.join(to, rel)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(File.join(from, rel), dest)
    dest
  end
end

# Runs +args+ (after the Ruby interpreter) in a child under +variant+, with its own TMPDIR below +base+.
def run_variant(variant, base, *args)
  tmp = File.join(base, variant[:dir], 'tmp')
  FileUtils.mkdir_p(tmp)
  Open3.capture3(variant[:env].merge('TMPDIR' => tmp), RbConfig.ruby, *args)
end

abort 'base rbs determinism check: 3rd/mruby is missing; the gem list needs it' unless File.directory?(File.join(ROOT, '3rd/mruby'))

puts '== base_rbs.rb: every gem\'s mrblib, at two paths, under two locales'
gems = BaseRbsAll.gems.filter_map do |gem_dir|
  rels = BaseRbsAll.ruby_sources(gem_dir).map { |path| path.delete_prefix("#{gem_dir}/") }
  [File.basename(gem_dir), gem_dir, rels] unless rels.empty?
end
driver = <<~RUBY
  require #{File.join(__dir__, 'base_rbs').dump}
  out, src = ARGV
  Dir.children(src).sort.each do |gem|
    paths = Dir.glob('**/*.rb', base: File.join(src, gem)).sort.map { |rel| File.join(src, gem, rel) }
    BaseRbs.run(File.join(out, gem), paths)
  end
RUBY
Dir.mktmpdir('base-rbs-determinism') do |base|
  outputs = VARIANTS.map do |variant|
    src = File.join(base, variant[:dir], 'src')
    gems.each { |name, gem_dir, rels| copy_sources(gem_dir, rels, File.join(src, name)) }
    out = File.join(base, variant[:dir], 'out')
    _o, err, status = run_variant(variant, base, '-e', driver, out, src)
    warn err unless status.success?
    [status.success?, tree(out)]
  end
  check.call('both runs succeed', outputs.all?(&:first))
  check.call("#{gems.size} gems give some output", outputs.first.last.size >= gems.size)
  check.call('the two runs write the same files, byte for byte', outputs.map(&:last).uniq.size == 1)
end

puts '== base_rbs_native.rb: a fixture at two paths, under two locales, serial and with three workers'
if NativeAstSource.available?(NativeAstSource.producer)
  header = <<~CPP
    struct mrb_state {};
    struct RClass {};
    struct mrb_value { int v; };
    mrb_value mrb_fixnum_value(int);
    mrb_value mrb_nil_value();
    RClass *mrb_define_class(mrb_state*, const char*, RClass*);
    RClass *mrb_define_module(mrb_state*, const char*);
    void mrb_define_method(mrb_state*, RClass*, const char*, mrb_value (*)(mrb_state*, mrb_value), int);
    void mrb_define_class_method(mrb_state*, RClass*, const char*, mrb_value (*)(mrb_state*, mrb_value), int);
  CPP
  # Two files reopen one class, one with a superclass and one without, and register one name twice: the merge order shows
  # in the output.
  sources = {
    'b/zeta.cxx' => <<~CPP,
      static mrb_value one(mrb_state *mrb, mrb_value self) { return mrb_fixnum_value(1); }
      void install_zeta(mrb_state *mrb) {
        RClass *shared = mrb_define_class(mrb, "Shared", 0);
        mrb_define_method(mrb, shared, "zeta", one, 0);
        mrb_define_method(mrb, shared, "both", one, 0);
      }
    CPP
    'a/alpha.cxx' => <<~CPP,
      static mrb_value none(mrb_state *mrb, mrb_value self) { return mrb_nil_value(); }
      void install_alpha(mrb_state *mrb) {
        RClass *base = mrb_define_class(mrb, "Base", 0);
        RClass *shared = mrb_define_class(mrb, "Shared", base);
        mrb_define_method(mrb, shared, "alpha", none, 0);
        mrb_define_method(mrb, shared, "both", none, 0);
        RClass *tool = mrb_define_module(mrb, "Tool");
        mrb_define_class_method(mrb, tool, "make", none, 0);
      }
    CPP
    'c/omega.cxx' => <<~CPP
      static mrb_value two(mrb_state *mrb, mrb_value self) { return mrb_fixnum_value(2); }
      void install_omega(mrb_state *mrb) {
        RClass *omega = mrb_define_class(mrb, "Omega", 0);
        mrb_define_method(mrb, omega, "value", two, 0);
      }
    CPP
  }
  Dir.mktmpdir('base-rbs-determinism') do |base|
    texts = VARIANTS.map do |variant|
      src = File.join(base, variant[:dir], 'src')
      paths = sources.keys.sort.map do |rel|
        FileUtils.mkdir_p(File.dirname(File.join(src, rel)))
        File.write(File.join(src, rel), header + sources[rel])
        File.join(src, rel)
      end
      out = File.join(base, variant[:dir], 'out')
      _o, err, status = run_variant(variant, base, File.join(__dir__, 'base_rbs_native.rb'), '--jobs', variant[:jobs].to_s,
                                    out, *paths)
      warn err unless status.success?
      status.success? ? File.binread(File.join(out, 'native.rbs')) : nil
    end
    check.call('both runs succeed', texts.none?(&:nil?))
    check.call('the fixture classes are written', texts.first.to_s.include?('class Shared') && texts.first.to_s.include?('module Tool'))
    check.call('the two runs write the same native.rbs, byte for byte', texts.uniq.size == 1)
  end
else
  puts '  SKIP native runs: neither the nfcxx front end (scripts/setup-libclang-edg.sh) nor clang is available'
end

if failures.empty?
  puts "base rbs determinism check: #{checks} checks passed"
else
  abort "base rbs determinism check: #{failures.size} of #{checks} failed"
end
