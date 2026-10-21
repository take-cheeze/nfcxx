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
#   2. unrelated classes do not withdraw it: a reopened String defining empty? is another class's method;
#   3. negative worlds, each one withdraws the arm for the same site: a definition repeated in the same
#      class, a prepend on the candidate, an anonymous candidate class, a dynamic installer of the name, and
#      strict mode (BC2CPP_NATIVE_OWNER_MAP=strict, which trusts no mruby core forwarder);
#   4. kill switch: BC2CPP_NATIVE_OWNER_MAP=0 gives the by-name form for the same site, and the positive world
#      differs from it.
#
# Generated code only (no mruby build). Needs a host mrbc: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/native_owner_map_check.rb
# Without MRBC the generated-code part is skipped (ADR 0397's runtime tier, as native_result_facts_check.rb).

require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack. Set before
# the bc2cpp subprocesses start: they inherit ENV, so every compile here runs without sig/bc2cpp.
ENV['BC2CPP_SIG_DIRS'] = ''
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/closed_world_env'

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
ARM = %r{(?:// NATIVE_OWNER_MAP :empty\? -- [^\n]*\n\s*)?if \(bc2cpp_owner_class_\d+\(M\) == mrb_obj_class\(M, r\d+\)\) \{\n\s*r\d+ = CxQueue_empty\$3f_impl\(M, r\d+\);\n\s*\} else }
# The by-name else: a plain send, or with the owner map on, the closed-world owner call over the same owners.
BY_NAME_ELSE = /bc2cpp_send\(M, r\d+, \d+, 0\)|bc2cpp_owner_call\(M, r\d+, \d+, \d+, BC2CPP_OWNERS\(.*?\), mrb_nil_value\(\), 0\)/

if tool?(MRBC_PATH)
  gems = NomethodReviewedProbe.closed_gems(ROOT)
  native_srcs = core_native_srcs(MRUBY) + external_gem_native_srcs(ROOT)
  core_srcs = core_compiled_mrblib_srcs(ROOT)
  foreign = foreign_mrblib_srcs(ROOT)

  # One bc2cpp run over the core, the foreign sources and `source`.
  generate = lambda do |source, name, extra_env: {}|
    Dir.mktmpdir do |dir|
      path = File.join(dir, "#{name}.rb")
      File.write(path, source)
      env = { 'MRBC' => MRBC_PATH, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
              'NATIVE_SRCS' => Shellwords.join(native_srcs),
              'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign),
              'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + %w[CxQueue CxHolder CxWrap String]).join(','),
              'BC2CPP_BUILD_NAME' => 'closed',
              'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }) }
      out, err, status = Open3.capture3(bc2cpp_closed_world_probe_env(env.merge(extra_env)), RbConfig.ruby,
                                        File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), *(core_srcs + [path]))
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
  check.call("positive: the by-name else stays in the arm's else", pb.match?(BY_NAME_ELSE))

  unrelated = generate.call("#{FIXTURE}\nclass String\n  def empty?; false; end\nend\n", 'cx_unrelated')
  check.call('unrelated: a reopened String#empty? does not withdraw the CxQueue arm',
             body.call(unrelated).match?(ARM))

  negatives = {
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

  # Kill switch: the same tree with the owner map off gives the by-name form, and the positive world differs.
  off = generate.call(FIXTURE, 'cx_pos', extra_env: { 'BC2CPP_NATIVE_OWNER_MAP' => '0' })
  check.call('kill switch BC2CPP_NATIVE_OWNER_MAP=0: no arm, the by-name send only',
             !body.call(off).match?(ARM) && body.call(off).match?(BY_NAME_ELSE))
  check.call('the positive world differs from the kill-switch world (the arm is what changes)', positive != off)
else
  puts '-- SKIP generated code: set MRBC to a host mrbc'
end

if failures.empty?
  puts 'bc2cpp native owner map check: PASS'
else
  warn "bc2cpp native owner map check: #{failures.size} failure(s)"
  failures.each { |f| warn "FAIL #{f}" }
  exit 1
end
