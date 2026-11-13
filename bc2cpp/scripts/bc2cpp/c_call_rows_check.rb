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
#   - a local spelled as its own presym, an interned literal, and a generated local compared or passed to sinks only;
#   - under the literal-lookup proof, the literals of an exception message (MESSAGE_ARGS) and a frame's name
#     (FRAME_NAME);
#   - the runtime's own registration on a core class field and its send-count label name no lookup;
#   - a macro redefinition of a base sink or a message formatter turns the rule off;
#   - the world's mruby looks the base sinks up through mrb_vm_find_method_rows, and so its by-name call's
#     method_missing and mruby-io's found-then-called methods; the generated funcall helper is mrb_funcall.
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

# A local named as its own presym, and an interned literal, are read as the literal they hold.
own = <<~C
  static mrb_value
  inc(mrb_state *mrb, mrb_value mod, mrb_value m)
  {
    mrb_sym included = MRB_SYM(included);
    if (!mrb_func_basic_p(mrb, m, included, mrb_do_nothing)) mrb_funcall_argv(mrb, m, included, 1, &mod);
    mrb_sym kept = mrb_intern_lit(mrb, "kept_name");
    mrb_method_search_vm(mrb, &c, kept);
    return mrb_funcall(mrb, m, mrb_intern_lit(mrb, "interned_operand"), 0);
  }
C
own_out = CCallRows.blank(own, base)
suite.check('a local spelled as its own presym is blanked', !own_out.include?('MRB_SYM(included)'))
suite.check('an interned literal operand is blanked, one another lookup reads stays',
            !own_out.include?('"interned_operand"') && own_out.include?('"kept_name"'))
# The generated code's locals are read around their literal assignment, a static one compared included.
runtime = <<~C
  static bool is_ps(mrb_state* M, mrb_sym mid) {
    static mrb_state* st; static mrb_sym ps;
    if (st != M) { ps = mrb_intern_lit(M, "public_send"); st = M; }
    return mid == ps;
  }
  static void leaky(mrb_state* M, mrb_value r) {
    mrb_sym s = mrb_intern_lit(M, "leaks");
    other(M, r, s);
  }
C
rt_out = CCallRows.blank_generated(runtime)
suite.check('a generated static local only compared is blanked, one passed elsewhere stays',
            !rt_out.include?('"public_send"') && rt_out.include?('"leaks"') && rt_out.size == runtime.size)
# MESSAGE_ARGS: under the literal-lookup proof a message's literals are no names; the format's earlier operands stay.
msg = 'mrb_no_method_error(M, mid, args, "%s method", priv ? "private" : "protected", mid, recv); ' \
      'mrb_name_error(mrb, mrb_intern_lit(mrb, "named"), "no %s", "worded");' + "\n"
suite.check('message literals are blanked only under the proof',
            CCallRows.blank(msg, base).include?('"protected"') &&
              !CCallRows.blank(msg, base, proven: true).match?(/"protected"|"private"|"worded"/) &&
              CCallRows.blank(msg, base, proven: true).include?('"named"') &&
              !CCallRows.blank_generated(msg, proven: true).include?('"protected"'))
# FRAME_NAME: under the proof, the name a C caller gives a found method's frame is no lookup of it.
frame = <<~C
  static mrb_method_t
  missing_of(mrb_state *mrb, mrb_callinfo *ci, mrb_value recv)
  {
    mrb_sym missing = MRB_SYM(method_missing);
    mrb_method_t m = mrb_vm_find_method_rows(mrb, mrb_class(mrb, recv), &c, missing);
    ci->mid = missing;
    ci->mid = MRB_SYM(named_frame);
    return m;
  }
C
suite.check('a frame name is blanked only under the proof',
            CCallRows.blank(frame, base).include?('MRB_SYM(method_missing)') &&
              !CCallRows.blank(frame, base, proven: true).match?(/MRB_SYM\((?:method_missing|named_frame)\)/))
suite.check('a macro redefinition of a message formatter turns the rule off',
            CCallRows.sinks({ 'a.c' => flow, 'w.h' => "#define mrb_raisef(mrb, c, ...) other(mrb, c)\n" }).nil?)
# The runtime's own registration names the method it defines; a send-count label is a counter key.
unit = 'mrb_define_method(M, M->proc_class, "arity", f, MRB_ARGS_NONE());'
suite.check("the runtime's own registration is a definition",
            !unit.gsub(StaticDispatchRegistrations::RUNTIME_REGISTRATION_STMT, '').include?('"arity"'))
suite.check('a send-count label is inert',
            !StaticDispatchRegistrations.blank_inert_string_args('BC2CPP_SEND_HIT(M, "send", mid);').include?('"send"'))

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
# The C lookups made for a by-name call that misses, and the find-then-call sites, find rows too.
%w[prepare_missing send_method].each do |name|
  b = body.call(vm, name)
  suite.check("#{name} looks method_missing up through mrb_vm_find_method_rows",
              b.match?(/mrb_vm_find_method_rows\([^;]*(?:missing|MRB_SYM\(method_missing\))\)/) &&
                !b.match?(/mrb_vm_find_method\([^;]*(?:\bmissing|MRB_SYM\(method_missing\))\)/))
end
io_c = File.read(File.join(mruby, 'mrbgems/mruby-io/src/io.c'))
file_c = File.read(File.join(mruby, 'mrbgems/mruby-io/src/file.c'))
suite.check("mruby-io's found-then-called methods are found through mrb_vm_find_method_rows",
            [[file_c, 'sysopen'], [file_c, 'initialize'], [io_c, 'puts']].all? do |text, name|
              text.include?("mrb_vm_find_method_rows(mrb, ") && !text.match?(/mrb_method_search_vm\([^;]*MRB_SYM\(#{name}\)/)
            end)
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

# The closed (VM-free) build links its own funcall, so the rows lookup must be there too: a by-name call that does not
# find a row where its entry would be raises NoMethodError for a name the proof let go.
frames = File.read(File.join(__dir__, '../../tools/bc2cpp/runtime/vm_frames.cxx'))
suite.check("the closed runtime's funcall looks up and falls back to method_missing through mrb_vm_find_method_rows",
            frames.scan(/\bmrb_vm_find_method_rows\(/).size == 2 && !frames.match?(/\bmrb_vm_find_method\(/))

# TERNARY_NAMES: a condition picking one of two literals names both as lookups; a computed arm or a literal in the
# condition leaves the operand in place.
pick = <<~C
  mrb_funcall(M, input, e.press ? "press" : "release", 1, key);
  mrb_funcall(M, input, tap.frame == frame ? "tap" : "hold", 1, key);
  mrb_funcall(M, o, ready ? "go" : name, 0);
  mrb_funcall(M, o, kind == "x" ? "left" : "right", 0);
C
picked = CCallRows.blank(pick, base, cxx: true)
suite.check("a condition's two literals are blanked (left: #{%w[press release tap hold].select { |t| picked.include?("\"#{t}\"") }.join(', ')})",
            %w[press release tap hold].none? { |t| picked.include?("\"#{t}\"") })
suite.check('a computed arm and a literal in the condition stay',
            picked.include?('"go"') && picked.include?('"left"') && picked.include?('"right"'))
suite.check('the ternary text keeps its length', picked.size == pick.size)

# ENGINE_NATIVES_ROWS_RUN: a native outside 3rd/ is read by the rows run itself, under its own rules, so its names
# reach the rows run's engine names only through that reading; the plain tokens still hold every name.
Dir.mktmpdir('engine-native-rows') do |dir|
  native = File.join(dir, 'mruby-rgss/src/probe.cxx')
  FileUtils.mkdir_p(File.dirname(native))
  File.write(native, 'void f(mrb_state* M, V o) { mrb_funcall(M, o, "probe_name", 0); }')
  old = StaticDispatchRegistrations.method(:outside_world_files)
  StaticDispatchRegistrations.define_singleton_method(:outside_world_files) { |*_args, **_kw| [[], [native]] }
  begin
    engine = Set.new
    tokens = StaticDispatchRegistrations.outside_world_tokens(dir, closed_only: true, engine_tokens: engine)
    suite.check('a native outside 3rd/ keeps its names in the plain tokens', tokens.include?('probe_name'))
    suite.check('and leaves them to the rows run in the engine tokens', !engine.include?('probe_name'))
  ensure
    StaticDispatchRegistrations.define_singleton_method(:outside_world_files, old)
  end
end

suite.finish!
