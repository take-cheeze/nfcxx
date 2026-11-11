# frozen_string_literal: true

# Checks tools/bc2cpp/native_core_candidates.rb (the clang-based direct-call candidates for mruby core natives): the
# ROM-table parse of a source, the symbol spelling, and the frame-free verdict on hand-built ASTs. No clang here; the
# real AST run is the generator's own step.
#
#   ruby scripts/bc2cpp/native_core_candidates_check.rb
require 'tmpdir'
require_relative '../../tools/bc2cpp/native_core_candidates'

FAILED = []
def check(what, ok)
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  FAILED << what unless ok
end

N = NativeCoreCandidates

puts '== the ROM table parse'
src = <<~C
  static const mrb_mt_entry demo_rom_entries[] = {
    MRB_MT_ENTRY(mrb_demo_plus,  MRB_OPSYM(add),  MRB_ARGS_REQ(1)),
    MRB_MT_ENTRY(mrb_demo_size,  MRB_SYM(size),   MRB_ARGS_NONE()),
    MRB_MT_ENTRY(mrb_demo_idx,   MRB_SYM_Q(empty), MRB_ARGS_ARG(1,1)),
  };
C
path = File.join(Dir.tmpdir, "native_core_candidates_check_#{Process.pid}.c")
File.write(path, src)
rows = N.entries(path)
File.delete(path)
check('three entries come from one table', rows.map(&:first).uniq == ['demo'] && rows.size == 3)
check('MRB_OPSYM(add) is "+", MRB_SYM is the name, MRB_SYM_Q adds ?',
      rows.map { |r| r[1] } == ['+', 'size', 'empty?'])
check('the aspec keeps nested parentheses', rows.last[3] == 'MRB_ARGS_ARG(1,1)')
check('the function name is the first argument', rows.map { |r| r[2] } == %w[mrb_demo_plus mrb_demo_size mrb_demo_idx])

puts '== the frame-free verdict on hand-built ASTs'
def fn(name, *calls, state_param: nil)
  body = calls.map do |c|
    { 'kind' => 'CallExpr', 'referencedDecl' => { 'kind' => 'FunctionDecl', 'name' => c,
                                                 'type' => { 'qualType' => "mrb_value (mrb_state *, mrb_value)" } },
      'inner' => [] }
  end
  { 'kind' => 'FunctionDecl', 'name' => name,
    'inner' => [{ 'kind' => 'CompoundStmt', 'inner' => body }] }
end
def unit(*fns) = { 'kind' => 'TranslationUnitDecl', 'inner' => fns }

leaf = fn('leaf', 'mrb_str_new')
reads = fn('reads', 'mrb_get_args')
through = fn('through', 'helper')
helper_reads = fn('helper', 'mrb_yield')
unknown = fn('unknown', 'some_outside_api')
frame_field = { 'kind' => 'FunctionDecl', 'name' => 'field',
                'inner' => [{ 'kind' => 'CompoundStmt', 'inner' => [
                  { 'kind' => 'MemberExpr', 'name' => 'ci', 'inner' => [] }] }] }
verdict = N.frame_free(unit(leaf, reads, through, helper_reads, unknown, frame_field))

check('a body that calls a unit-external mrb_state API outside MRB_API_ALLOW is not frame-free',
      verdict['unknown'] == false)
check('a body that calls a frame reader is not frame-free', verdict['reads'] == false)
check('a body that reaches a frame reader through a unit function is not frame-free', verdict['through'] == false)
check('a body that reads mrb->ci is not frame-free', verdict['field'] == false)
check('a body that calls only reviewed mruby APIs is frame-free', verdict['leaf'] == true)

puts
if FAILED.empty?
  puts 'native_core_candidates_check: all checks passed'
else
  puts "native_core_candidates_check: #{FAILED.size} failure(s)"
  exit 1
end
