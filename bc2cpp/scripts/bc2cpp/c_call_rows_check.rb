#!/usr/bin/env ruby
# frozen_string_literal: true

# C_CALL_ROWS (tools/bc2cpp/c_call_rows.rb, CoreNativeCandidates.reachable with +row_calls+, the core rows run): a C
# call that finds rows where their entries would be, or that looks nothing up, takes a name no entry must answer.
#
#   - the literal or presym name operand of each sink call is blanked; a computed name, a member call of the same
#     spelling, a Symbol argument and every other spelling of the name stay;
#   - a function or macro whose parameter reaches only sinks or comparisons is a sink in its turn, unless a definition
#     of its name is in C++ or cannot be read; a local `mrb_sym` assigned literals and used only by sinks is too;
#   - the rows run leaves out a name only such calls spell; the plain run still reads it;
#   - a macro redefinition of a base sink turns the rule off;
#   - the world's mruby looks the base sinks up through mrb_vm_find_method_rows, and the generated funcall helper is
#     mrb_funcall.
#
# Usage: ruby scripts/bc2cpp/c_call_rows_check.rb

require 'set'
require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

suite = FixtureCheck.new('c_call_rows_check')
base = CCallRows::BASE

src = <<~C
  a = mrb_funcall_id(mrb, self, MRB_SYM(to_enum), 1, mrb_symbol_value(MRB_SYM(index)));
  b = mrb_funcall(mrb, v, "inspect", 0); c = mrb_funcall_argv(mrb, v, mid, 0, NULL); d = o->mrb_funcall(m, v, "keep");
  e = mrb_method_memo(mrb, key, MRB_SYM_Q(eql), MRB_MEMO_EQL); f = ::mrb_funcall_with_block(M, v, MRB_OPSYM(cmp), 0, NULL, b);
  g = mrb_funcall_with_method(mrb, v, MRB_SYM(found), &m, o, 0, NULL, n); if (mid == MRB_SYM(compared)) h();
C
out = CCallRows.blank(src, base)
gone = %w[MRB_SYM(to_enum) "inspect" MRB_SYM_Q(eql) MRB_OPSYM(cmp) MRB_SYM(found) MRB_SYM(compared)]
suite.check("sink operands and compared names are blanked (left: #{gone.select { |t| out.include?(t) }.join(', ')})",
            gone.none? { |t| out.include?(t) })
suite.check('a computed name, a member call and a Symbol argument stay',
            out.include?('mid, 0') && out.include?('"keep"') && out.include?('MRB_SYM(index)'))
suite.check('the text keeps its length', out.size == src.size)

flow = <<~C
  static mrb_value
  send_it(mrb_state *mrb, mrb_value self, mrb_sym mid, int slot)
  {
    const struct mrb_cfunc_memo *memo = mrb_method_memo(mrb, self, mid, slot);
    if (MRB_METHOD_UNDEF_P(memo->m)) return mrb_funcall_argv(mrb, self, mid, 0, NULL);
    return memo->owner == NULL || mid == 0 ? mrb_nil_value() : self;
  }
  static mrb_value
  leak(mrb_state *mrb, mrb_value self, mrb_sym mid)
  {
    mrb_method_t m = mrb_method_search_vm(mrb, &c, mid);
    return mrb_funcall_argv(mrb, self, mid, 0, NULL);
  }
  #define SEND_IT(mrb, obj, mid) send_it(mrb, obj, mid, 0)
  static mrb_value
  user(mrb_state *mrb, mrb_value self)
  {
    mrb_sym local;
    mrb_sym other = MRB_SYM(stays);
    local = MRB_SYM(via_local);
    mrb_funcall_id(mrb, self, local, 0);
    mrb_method_search_vm(mrb, &c, other);
    send_it(mrb, self, MRB_SYM(via_wrapper), 1);
    SEND_IT(mrb, self, MRB_SYM(via_macro));
    return leak(mrb, self, MRB_SYM(via_leak));
  }
C
cxx = "static mrb_value g(mrb_state *M, mrb_value x) { send_it(M, x, MRB_SYM(from_cxx), 0); return mrb_funcall(M, x, \"cxx_base\", 0); }\n"
sinks = CCallRows.sinks({ 'a.c' => flow, 'b.cxx' => cxx })
suite.check("a wrapper and a macro of a sink are sinks, a parameter that leaks is not (#{(sinks.keys - base.keys).sort.join(', ')})",
            sinks['send_it'] == Set[2] && sinks['SEND_IT'] == Set[2] && !sinks.key?('leak'))
c_out = CCallRows.blank(flow, sinks)
%w[via_local via_wrapper via_macro].each do |name|
  suite.check("#{name} is blanked", !c_out.include?("MRB_SYM(#{name})"))
end
suite.check('a local another lookup reads, and a leaking parameter, stay',
            c_out.include?('MRB_SYM(stays)') && c_out.include?('MRB_SYM(via_leak)'))
cxx_out = CCallRows.blank(cxx, sinks, cxx: true)
suite.check('a C++ source blanks base sinks only', cxx_out.include?('MRB_SYM(from_cxx)') && !cxx_out.include?('"cxx_base"'))
cxx_def = CCallRows.sinks({ 'a.c' => flow, 'c.cxx' => "static int send_it(int a, int b, int c) { return a; }\n" })
suite.check('a C++ definition of the name keeps it from being a sink', !cxx_def.key?('send_it'))
odd = CCallRows.sinks({ 'a.c' => flow, 'd.c' => "static int send_it(int (*f)(int), int b, int c) { return b; }\n" })
suite.check('an unreadable definition of the name keeps it from being a sink', !odd.key?('send_it'))
suite.check('a macro redefinition of a base sink turns the rule off',
            CCallRows.sinks({ 'a.c' => flow, 'w.h' => "#define mrb_funcall(mrb, v, name, ...) other(mrb, v, name)\n" }).nil?)
gen = "r1 = bc2cpp_funcall_keep(M, a, \"%\", 1, b); r2 = bc2cpp_owner_call(M, a, \"zero?\");\n"
g_out = CCallRows.blank_generated(gen)
suite.check('the generated funcall helper is a sink', !g_out.include?('"%"') && g_out.include?('"zero?"'))

Dir.mktmpdir('c-call-rows') do |dir|
  native = File.join(dir, 'widget.c')
  File.write(native, <<~C)
    static mrb_value f(mrb_state *mrb, mrb_value x) {
      if (mrb_respond_to(mrb, x, MRB_SYM(polish))) mrb_funcall_id(mrb, x, MRB_SYM(polish), 0);
      return mrb_funcall(mrb, x, "spin", 0);
    }
  C
  plain, = CoreNativeCandidates.reachable({}, [native], [])
  rows, = CoreNativeCandidates.reachable({}, [native], [], row_calls: true)
  suite.check("the plain run reads a funcall's name (#{plain.to_a.sort.join(', ')})", plain.include?('spin'))
  suite.check("the rows run does not (#{rows.to_a.sort.join(', ')})", !rows.include?('spin'))
  suite.check('a name spelled outside a sink too stays reached', rows.include?('polish'))
end

mruby = File.join(BC2CPP_WORLD_ROOT, '3rd/mruby')
vm = File.read(File.join(mruby, 'src/vm.c'))
kernel = File.read(File.join(mruby, 'src/kernel.c'))
class_c = File.read(File.join(mruby, 'src/class.c'))
body = ->(text, name) { text[/^#{name}\(.*?^\}/m].to_s }
other_lookup = /\bmrb_vm_find_method\(|mrb_method_search_vm\(/
%w[funcall_with_block_m].each do |name|
  b = body.call(vm, name)
  suite.check("#{name} looks up through mrb_vm_find_method_rows", b.include?('mrb_vm_find_method_rows(') && !b.match?(other_lookup))
end
%w[mrb_method_memo mrb_func_basic_p].each do |name|
  b = body.call(kernel, name)
  suite.check("#{name} looks up through mrb_vm_find_method_rows", b.include?('mrb_vm_find_method_rows(') && !b.match?(other_lookup))
end
rows = body.call(class_c, 'mrb_vm_find_method_rows')
suite.check('mrb_vm_find_method_rows searches with rows', rows.include?('mrb_vm_find_ctor(') && !rows.match?(other_lookup))
entry = %w[mrb_funcall mrb_funcall_id mrb_funcall_argv mrb_funcall_with_block mrb_funcall_send].all? do |name|
  b = body.call(vm, name)
  !b.empty? && !b.match?(other_lookup)
end
suite.check('the funcall entry points search nothing themselves', entry)
helper = File.read(File.join(__dir__, '../../tools/bc2cpp/bc2cpp.rb'))
suite.check('bc2cpp_funcall_keep is mrb_funcall',
            helper.include?('#define bc2cpp_funcall_keep(M, ...) bc2cpp_keep_call(M, [&] { return mrb_funcall(M, __VA_ARGS__); })'))

suite.finish!
