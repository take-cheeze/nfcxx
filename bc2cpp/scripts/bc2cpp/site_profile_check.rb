#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check SITE_PROFILE (docs/adr/0298), the opt-in executed-count profile of the
# by-name dispatch bc2cpp leaves in generated C++:
#
#   - a hand-written miniature of the generated shape is instrumented, built
#     with g++, run, and its hit file ranked (needs only g++);
#   - bc2cpp on a small world emits the same C++ with and without
#     BC2CPP_SITE_PROFILE once the counters are peeled off (needs MRBC).
#
#   [MRBC=path/to/host/mrbc] ruby scripts/bc2cpp/site_profile_check.rb

require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require_relative '../../tools/bc2cpp/site_rank'
require_relative 'cxx'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The shapes the census reads: a name table, a helper, then `*_impl` bodies.
MINI = <<~'CPP'
  #include <stdarg.h>
  typedef int mrb_value;
  typedef int mrb_state;
  static const char* const bc2cpp_sym_names[2] = {
    "speak",
    "walk",
  };
  static mrb_value bc2cpp_send(mrb_state* M, mrb_value recv, int i, long argc, ...) { return recv + i; }
  static mrb_value mrb_funcall_id(mrb_state* M, mrb_value recv, int sym, long argc, ...) { return recv + sym; }
  static mrb_value Pet_talk_impl(mrb_state* M, mrb_value self) {
    mrb_value r1 = self;
    // POLY_SMALL_N: kept
    r1 = bc2cpp_send(M, r1, 0, 0);
    return r1;
  }
  static mrb_value Pet_go_impl(mrb_state* M, mrb_value self) {
    mrb_value r1 = self;
    r1 = bc2cpp_send(M, r1, 1, 0);
    // a comment mentioning bc2cpp_send(M, r1, 1, 0) is not a site
    r1 = mrb_funcall_id(M, r1, 7, 0);
    return r1;
  }
  int main() {
    mrb_state M = 0;
    for (int k = 0; k < 5; k++) Pet_talk_impl(&M, k);
    for (int k = 0; k < 2; k++) Pet_go_impl(&M, k);
    return 0;
  }
CPP

puts '== instrument, build, run and rank a miniature of the generated shape'
Dir.mktmpdir do |dir|
  text, rows = SiteProfile.instrument(MINI, 'mini')
  check.call('three call sites are found, the commented one is not', rows.map { |r| r[:kind] } == %w[bc2cpp_send bc2cpp_send mrb_funcall_id])
  check.call('each site keeps its enclosing function and generated line',
             rows.map { |r| [r[:fn], r[:line]] } == [['Pet_talk_impl', 13], ['Pet_go_impl', 18], ['Pet_go_impl', 20]])
  check.call('a send is named from the symbol table', rows.first[:name] == 'speak')
  SiteProfile.write_sites(File.join(dir, 'sites', 'mini.sites.tsv'), rows)
  source = File.join(dir, 'mini.cpp')
  File.write(source, text)
  binary = File.join(dir, 'mini')
  _out, err, status = Bc2cppCxx.capture3('-std=gnu++17', source, '-o', binary)
  if !status.success?
    check.call("the instrumented miniature compiles\n#{err}", false)
  else
    hits = File.join(dir, 'hits')
    Dir.mkdir(hits)
    _out, _err, status = Open3.capture3({ 'BC2CPP_SITE_PROFILE_OUT' => hits }, binary)
    check.call('the instrumented miniature runs', status.success?)
    check.call('a run without an output directory writes nothing', Dir[File.join(dir, '*.hits')].empty? && Open3.capture3(binary)[2].success?)
    by_symbol = SiteRank.load_sites(File.join(dir, 'sites'))
    SiteRank.add_hits(by_symbol, 'mini', hits)
    io = StringIO.new
    ranked = SiteRank.report(by_symbol, ['mini'], 30, io: io)
    check.call('sites rank by executed count: 5 talk, 2 walk, 2 funcall', ranked.map { |s| s.hits['mini'] } == [5, 2, 2])
    check.call('the report lists the hottest site first, with its method and the funcall kind',
               io.string[/^\s+1 .*/].to_s.include?('speak') && io.string.include?('mrb_funcall_id:?'))
    census = File.join(root, 'scripts/bc2cpp/dynamic_site_census.rb')
    out, _err, st = Open3.capture3(RbConfig.ruby, census, '--rank', File.join(dir, 'sites'), '--workload', "mini=#{hits}", '--top', '2',
                                   '--tsv', File.join(dir, 'ranked.tsv'))
    check.call('the census CLI ranks from the site and hit directories', st.success? && out.include?('TOP 2 dynamic sites') &&
               File.read(File.join(dir, 'ranked.tsv')).lines.size == 4)
    File.write(File.join(dir, 'plain.cxx'), MINI)
    out, _err, st = Open3.capture3(RbConfig.ruby, census, File.join(dir, 'plain.cxx'))
    check.call('the static census still reads the same text', st.success? && out.include?('bc2cpp_send call sites:'))

    # The text walk labels a receiver by its nearest assignment; across a label, or an arm that reassigns it, that is
    # one path's value, so the label is `join` (straight-line sites keep their label).
    require_relative '../../tools/bc2cpp/site_census'
    walk = lambda do |body, recv = 'r1'|
      lines = body.lines
      SiteCensus.receiver_origin(lines, lines.index { |l| l.include?('bc2cpp_send') } + 1, recv)
    end
    check.call('a straight-line fresh receiver keeps literal_or_fresh', walk.call("  r1 = mrb_ary_new(M);\nif (r9) {\n    r9 = 1;\n  }\n  r2 = bc2cpp_send(M, r1, 0, 0);\n") == 'literal_or_fresh')
    check.call('a receiver across a jump label is join', walk.call("  r1 = mrb_ary_new(M);\nL5:;\nif (r9) {\n    r9 = 1;\n  }\n  r2 = bc2cpp_send(M, r1, 0, 0);\n") == 'join')
    check.call('a receiver set in an inline fast-path arm is join',
               walk.call("  r1 = mrb_nil_value();\nif (fast) {\n    r1 = mrb_fixnum_value(1);\n  } else {\n    r1 = bc2cpp_send(M, r1, 0, 0);\n  }\n") == 'join')
    stamp = File.read(Dir[File.join(hits, 'mini.*.hits')].first)[/\A# sites \h+/]
    refused = lambda do |body|
      File.write(File.join(hits, 'mini.1.hits'), body)
      SiteRank.add_hits(SiteRank.load_sites(File.join(dir, 'sites')), 'mini', hits)
      nil
    rescue RuntimeError => e
      e.message
    end
    check.call('a hit file stamped for another site table is refused', refused.call("# sites 000000000000\n0\t1\n").to_s.include?('different build'))
    check.call('an id past the end of the site table is refused', refused.call("#{stamp}\n99\t1\n").to_s.include?('out of range'))
  end
end

mrbc = ENV['MRBC'] || 'mrbc'
if !system(mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP bc2cpp identity check: no mrbc (set MRBC)'
else
  puts '== bc2cpp output with the profile switch, counters peeled off'
  WORLD = <<~'RUBY'
    class SpPet
      def sp_speak; 1; end
    end
    class SpRobot
      def sp_speak; 2; end
    end
    class SpCaller
      def talk(x); x.sp_speak; end
    end
  RUBY
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'sp.rb')
    File.write(path, WORLD)
    run = lambda do |extra|
      env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => 'sp', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1' }.merge(extra)
      Open3.capture3(env, RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', path)
    end
    plain, _e, st = run.call({})
    check.call('bc2cpp runs without the switch and emits no SITE_PROFILE code', st.success? && !plain.include?('SITE_PROFILE'))
    profiled, _e, st2 = run.call('BC2CPP_SITE_PROFILE' => File.join(dir, 'sites'))
    check.call('bc2cpp runs with the switch', st2.success? && profiled.include?('SITE_PROFILE'))
    peeled = profiled.sub(/\A.*?(?=#include <mruby\.h>)/m, '').gsub(/\(bc2cpp_site_hit_\w+\(\d+\), (\w+)\)\(/, '\1(')
    check.call('peeling the header and the hit calls gives back the plain output byte for byte', peeled == plain)
    sites = File.join(dir, 'sites', 'sp.sites.tsv')
    check.call('the site table lists a by-name send of the polymorphic name',
               File.exist?(sites) && File.read(sites).lines.any? { |l| l.include?("\tbc2cpp_send\t") && l.include?("\tsp_speak\t") })
  end
end

if failures.empty?
  puts 'bc2cpp_site_profile_check: ok'
else
  abort "bc2cpp_site_profile_check: #{failures.size} failure(s)"
end
