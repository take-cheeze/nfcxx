#!/usr/bin/env ruby
# encoding: UTF-8
#
# Check NATIVE_OWNER_MAP (docs/adr/0397): a by-name send on a receiver of unknown class whose name has a
# Ruby definition on a class the owner map proves free of native definitions of the name gets one
# exact-class arm per such definition, calling its compiled body, ahead of the by-name else. The else
# stays for every other receiver.
#
#   1. positive world: the proven site gets the arm (exact class test, compiled body call) and keeps its
#      by-name else;
#   2. negative worlds, each one withdraws the arm for the same site: a native-or-Ruby definition of the name
#      on the candidate's own class (String#empty? is native), strict mode (BC2CPP_NATIVE_OWNER_MAP=strict,
#      which trusts no mruby core forwarder), a dynamic installer of the name, a definition repeated in the
#      same class, a prepend on the candidate, and an anonymous candidate class;
#   3. kill switch: BC2CPP_NATIVE_OWNER_MAP=0 is byte-identical to the output of the same tree at the merge
#      base with origin/master (a copy of tools/bc2cpp taken from `git archive`, inside the repository so
#      its closed world is the real one), and the positive world differs from it.
#
# Generated code only (no mruby build). Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/native_owner_map_check.rb
# CX_BASE overrides the base revision (default: the merge base of HEAD and origin/master).

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'

MRUBY = File.join(ROOT, '3rd/mruby')
MRBC_PATH = ENV['MRBC'] || 'mrbc'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def tool?(name)
  system(name, '--version', out: File::NULL, err: File::NULL)
end

FIXTURE = <<~'RUBY'
  class CxQueue
    def initialize; @n = 0; end
    def empty?; @n == 0; end
  end

  class CxHolder
    def probe(x); x.empty?; end
  end
RUBY

# The probed body: the send of `probe` on its argument, which nothing proves exact.
PROBE_FN = /^mrb_value CxHolder_probe_impl\(mrb_state\* M.*?(?=^mrb_value \w+\(mrb_state\* M|\z)/m
ARM = %r{// NATIVE_OWNER_MAP :empty\? -- [^\n]*\n\s*if \(bc2cpp_owner_class_\d+\(M\) == mrb_obj_class\(M, r\d+\)\) \{\n\s*r\d+ = CxQueue_empty\$3f_impl\(M, r\d+\);\n\s*\} else }
BY_NAME_ELSE = /bc2cpp_send\(M, r\d+, \d+, 0\)/

if tool?(MRBC_PATH)
  gems = NomethodReviewedProbe.wio_gems(ROOT)
  native_srcs = core_native_srcs(MRUBY) + external_gem_native_srcs(ROOT)
  core_srcs = core_compiled_mrblib_srcs(ROOT)
  foreign = foreign_mrblib_srcs(ROOT)

  # One bc2cpp run over the core, the foreign sources and `source`. `tool_dir` is the tools/bc2cpp copy to run.
  generate = lambda do |source, name, tool_dir: File.join(ROOT, 'tools/bc2cpp'), extra_env: {}|
    Dir.mktmpdir do |dir|
      path = File.join(dir, "#{name}.rb")
      File.write(path, source)
      env = { 'MRBC' => MRBC_PATH, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
              'NATIVE_SRCS' => Shellwords.join(native_srcs),
              'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign),
              'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + %w[CxQueue CxHolder CxWrap]).join(','),
              'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
              'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
              NomethodReviewed::ALLOW_ENV => 'allow' }
      out, err, status = Open3.capture3(env.merge(extra_env), RbConfig.ruby, File.join(tool_dir, 'bc2cpp.rb'), '--annotated',
                                        *(core_srcs + [path]))
      abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
      out
    end
  end

  body = ->(code) { code[PROBE_FN].to_s }

  puts 'generated code'
  positive = generate.call(FIXTURE, 'cx_pos')
  pb = body.call(positive)
  check.call('positive: the probed body is generated', pb.include?('CxHolder_probe_impl'))
  check.call('positive: a proven empty? site gets the exact-class arm calling CxQueue#empty?', pb.match?(ARM))
  check.call('positive: the by-name else stays in the arm\'s else', pb.match?(BY_NAME_ELSE))

  negatives = {
    'unproven: String defines empty? next to its native' => "#{FIXTURE}\nclass String\n  def empty?; false; end\nend\n",
    'overridden: CxQueue defines empty? twice' => "#{FIXTURE}\nclass CxQueue\n  def empty?; true; end\nend\n",
    'prepend: a module prepended to CxQueue' => "module CxWrap\n  def empty?; false; end\nend\n#{FIXTURE}\n" \
                                                "class CxQueue\n  prepend CxWrap\nend\n",
    'missing owner: an anonymous class defines empty?' => "#{FIXTURE}\nClass.new { def empty?; true; end }\n",
    'dynamic installer: a computed define_method of the name' => "#{FIXTURE}\nclass CxQueue\n" \
                                                                 "  def self.install(n); define_method(n) { 1 }; end\nend\n"
  }
  negatives.each do |what, source|
    code = generate.call(source, 'cx_neg')
    check.call("negative (#{what}): no arm for the probed site", !body.call(code).match?(ARM) && body.call(code).match?(BY_NAME_ELSE))
  end

  strict = generate.call(FIXTURE, 'cx_strict', extra_env: { 'BC2CPP_NATIVE_OWNER_MAP' => 'strict' })
  check.call('negative (strict mode withdraws core forwarders): no arm for the probed site',
             !body.call(strict).match?(ARM) && body.call(strict).match?(BY_NAME_ELSE))

  base_ref = ENV['CX_BASE'] || `git -C #{ROOT} merge-base HEAD origin/master 2>/dev/null`.strip
  if base_ref.empty?
    puts '-- SKIP kill switch identity: no base revision (set CX_BASE)'
    check.call('kill switch: base revision known', false)
  else
    # A flat copy at tools/bc2cpp-owner-base-<pid>: bc2cpp.rb takes the repository root as ../.. of its own
    # directory, so the copy must sit exactly one level under tools/ to see the same closed world.
    base_dir = File.join(ROOT, "tools/bc2cpp-owner-base-#{Process.pid}")
    Dir.mktmpdir do |scratch|
      archive = File.join(scratch, 'base.tar')
      system('git', '-C', ROOT, 'archive', '--format=tar', '-o', archive, base_ref, 'tools/bc2cpp') or abort 'git archive failed'
      system('tar', '-xf', archive, '-C', scratch) or abort 'tar failed'
      FileUtils.mv(File.join(scratch, 'tools/bc2cpp'), base_dir)
    end
    begin
      base = generate.call(FIXTURE, 'cx_pos', tool_dir: base_dir)
      off = generate.call(FIXTURE, 'cx_pos', extra_env: { 'BC2CPP_NATIVE_OWNER_MAP' => '0' })
      check.call('kill switch BC2CPP_NATIVE_OWNER_MAP=0 is byte-identical to the base revision', off == base)
      check.call('the positive world differs from the base revision (the arm is what changes)', positive != base)
    ensure
      FileUtils.rm_rf(base_dir)
    end
  end
else
  puts '-- SKIP generated code: needs a host mrbc (set MRBC)'
  check.call('mrbc available (MRBC)', false)
end

if failures.empty?
  puts 'bc2cpp native owner map check: PASS'
else
  warn "bc2cpp native owner map check: #{failures.size} failure(s)"
  failures.each { |f| warn "FAIL #{f}" }
  exit 1
end
