#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_NATIVE_CANDIDATES (tools/bc2cpp/core_native_candidates.rb): which core ROM method-table entries the closed
# build may leave out of its tables, and the exclusion header it gets.
#
#   entries
#     - an entry's key is its table's MRB_MT_CLASS and its Ruby name (SYM_Q/B/E add ?/!/=);
#     - a table installed into another class than MRB_MT_CLASS, or into two classes, is no candidate's;
#   reachable
#     - an irep symbol, an identifier pool string, a native literal or presym use, a generated literal all count;
#     - a table entry's or registration's own name operand does not, nor a name only a DEF names;
#     - ALWAYS_DYNAMIC seeds nothing; MRB_OPSYM(x) is an operator, not the name x; a literal handed straight to a verified
#       message formatter (mrb_int_overflow, mrb_sys_fail), or the Symbol of a to_enum call while no Enumerator is made, is
#       no lookup;
#     - LIVE_CORE: a core method body's sends count once its name is reachable (an operator opcode reaches its
#       operator), or compiled code calls its `_impl`;
#       an ALIAS keeps both names without making unrelated definitions live;
#   candidates
#     - an operator name, a name some table of the class keeps, or a fragment-built name stays (a protocol name
#       such as inspect is not kept by default in the closed build);
#   header
#     - one MRB_MT_EXCLUDE_<Class>_<presym C name> 1 per listed entry;
#   ram_candidates
#     - an unreachable run-time registration or native alias is listed; a reachable one, or one a ROM entry shares, is not;
#     - an alias source still counts as a lookup; computed owners/names and fragment-built alias names stay.
#   ruby_candidates
#     - unreachable Ruby definitions, including singletons, are candidates;
#     - lookups, direct compiled calls, aliases, fragments and ROM-shared keys keep their definitions.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/core_native_candidates_check.rb

require 'set'
require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('core_native_candidates_check')
suite.require_mrbc!

NATIVE = <<~'C'
  #define MRB_MT_CLASS Widget
  static const mrb_mt_entry widget_rom_entries[] = {
    MRB_MT_ENTRY(w_spin, MRB_SYM(spin), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_empty, MRB_SYM_Q(empty), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_size, MRB_SYM_E(size), MRB_ARGS_REQ(1))
    MRB_MT_ENTRY(w_add, MRB_OPSYM(add), MRB_ARGS_REQ(1))
    MRB_MT_ENTRY(w_called, MRB_SYM(called), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_literal, MRB_SYM(literal), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_shared, MRB_SYM(shared), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_built_x, MRB_SYM(built_x), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_inspect, MRB_SYM(inspect), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_live, MRB_SYM(live_send), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_dead, MRB_SYM(dead_send), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_impl, MRB_SYM(impl_send), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_alias, MRB_SYM(alias_old), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_def, MRB_SYM(defined_only), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_alias_def, MRB_SYM(defined_beside_alias), MRB_ARGS_NONE())
    MRB_MT_ENTRY(w_alias_body, MRB_SYM(alias_body_send), MRB_ARGS_NONE())
  };
  static const mrb_mt_entry widget_class_rom_entries[] = {
    MRB_MT_ENTRY(w_shared_s, MRB_SYM(shared), MRB_ARGS_NONE())
  };
  #undef MRB_MT_CLASS
  #define MRB_MT_CLASS Gadget
  static const mrb_mt_entry gadget_rom_entries[] = {
    MRB_MT_ENTRY(g_two, MRB_SYM(two), MRB_ARGS_NONE())
  };
  #undef MRB_MT_CLASS

  void
  mrb_init_widget(mrb_state *mrb)
  {
    struct RClass *w = mrb_define_class_id(mrb, MRB_SYM(Widget), mrb->object_class);
    MRB_MT_INIT_ROM(mrb, w, widget_rom_entries);
    MRB_MT_INIT_ROM(mrb, mrb_class_ptr(mrb_singleton_class(mrb, mrb_obj_value(w))), widget_class_rom_entries);
    struct RClass *g = mrb_define_class_id(mrb, MRB_SYM(Gadget), mrb->object_class);
    struct RClass *h = mrb_define_class_id(mrb, MRB_SYM(Holder), mrb->object_class);
    MRB_MT_INIT_ROM(mrb, g, gadget_rom_entries);
    MRB_MT_INIT_ROM(mrb, h, gadget_rom_entries);
    mrb_funcall_id(mrb, mrb_obj_value(w), MRB_SYM(called), 0);
    mrb_define_method(mrb, w, "lonely", w_spin, MRB_ARGS_NONE());
    mrb_define_method(mrb, w, "spin", w_spin, MRB_ARGS_NONE());
    mrb_define_method(mrb, w, "string_name", w_spin, MRB_ARGS_NONE());
    mrb_define_alias(mrb, w, "unused_alias", "called");
    mrb_define_alias_id(mrb, w, MRB_SYM(id_alias), MRB_SYM(called));
    mrb_define_alias(mrb, w, "used_alias", "called");
    mrb_define_alias(mrb, w, "chain_source", "called");
    mrb_define_alias(mrb, w, "chain_tail", "chain_source");
    mrb_define_alias(mrb, w, "spin", "called");
    mrb_define_alias(mrb, w, "built_alias", "called");
    mrb_define_alias(mrb, w, "opaque_alias", runtime_name);
    mrb_define_alias(mrb, g, "computed_owner_alias", "called");
    mrb_define_method(mrb, g, runtime_name, w_spin, MRB_ARGS_NONE());
  }
C

# The engine: every irep counts. `defined_only` is only defined.
ENGINE = <<~'RUBY'
  class Thing
    def go
      from_ruby
      @names = ['string_name', 'built_']
      @sum = @a + @b
      used
      used_alias
      @receiver.public_lookup
      send(:reflected)
    end

    def defined_only; end
  end
RUBY

# A core file: `used` is sent by the engine, `unused` by nothing, `direct?` only called through its `_impl`, `+` by
# the engine's ADD opcode.
CORE = <<~'RUBY'
  class Widget
    def used
      live_send
    end

    def unused
      dead_send
    end

    def direct?
      impl_send
    end

    def public_lookup
      public_dependency
    end

    def generated_public; end

    def reflected; end
    def built_public; end
    def defined_only; end

    def +(other)
      op_send
    end
  end

  class Gadget
    def self.unused_singleton; end
    def defined_beside_alias
      alias_body_send
    end

    def alias_old
      alias_source_send
    end

    def [](key)
      alias_operator_source_send
    end

    alias alias_new alias_old
    alias alias_index []
  end
RUBY

GENERATED = ['f("literal")', 'v = Widget_direct$3f_impl(M, self);', <<~'CPP'].freeze
  static const char* const bc2cpp_sym_names[1] = {
    "generated_public",
  };
  bc2cpp_funcall_argv(M, r1, bc2cpp_sym(M, 0), 0, nullptr);
CPP

Dir.mktmpdir('core-native') do |dir|
  path = File.join(dir, 'widget.c')
  File.write(path, NATIVE)
  entries = CoreNativeCandidates.entries([path])
  keys = entries.to_h { |e| ["#{e[:mt_class]}##{e[:name] || e[:cname]}", e[:installed]] }
  suite.check('Ruby names from the presym kind',
              keys.key?('Widget#spin') && keys.key?('Widget#empty?') && keys.key?('Widget#size='))
  suite.check('a table installed into its MRB_MT_CLASS is installed; a singleton or two-class table is not',
              keys['Widget#spin'] == 'Widget' && entries.count { |e| e[:name] == 'shared' && e[:installed].nil? } == 1 &&
              keys['Gadget#two'].nil?)

  engine = suite.compile(ENGINE) { |ireps, _root| ireps }
  core = suite.compile(CORE) do |ireps, root|
    body_of = {}
    registry = build_registry(ireps, root)[0]
    registry.each { |name, defs| defs.each { |d| body_of[d.irep] = name if d.irep } }
    owner_of = registry.values.flatten.filter_map { |d| [d.irep, d.owner] if d.irep }.to_h
    [{ ireps: ireps, body_of: body_of, owner_of: owner_of, registry: registry }]
  end
  names, fragments = CoreNativeCandidates.reachable(engine, [path], GENERATED, core: core)
  suite.check('irep symbols, pool identifiers, native lookups and generated literals count',
              %w[from_ruby string_name called literal used].all? { |n| names.include?(n) })
  suite.check("an entry's or registration's own name operand does not, nor a name only a DEF names",
              !names.include?('spin') && !names.include?('lonely') && !names.include?('two') &&
              !names.include?('defined_only'))
  suite.check("a core body's sends count once its name is reachable or its _impl is called, not before",
              names.include?('live_send') && names.include?('impl_send') && names.include?('op_send') &&
              !names.include?('dead_send') &&
              !names.include?('unused'))
  suite.check('an alias keeps its source live without making its destination a lookup',
              %w[alias_old alias_source_send [] alias_operator_source_send].all? { |name| names.include?(name) } &&
              !names.include?('alias_new') && !names.include?('alias_index'))
  suite.check('an alias does not make unrelated definitions or their bodies live',
              !names.include?('defined_beside_alias') && !names.include?('alias_body_send'))
  generated = ['mrb_define_method(M, c, "unused", Widget_unused, MRB_ARGS_NONE()); void Widget_unused_impl();']
  exact, = CoreNativeCandidates.reachable({}, [], generated, core: core, exact_impls: true,
                                           strip_generated: ->(src) { src.gsub(StaticDispatchRegistrations::REGISTRATION_CALL, '') })
  suite.check('a generated registration is a definition and a direct implementation retains only body dependencies',
              !exact.include?('unused') && exact.include?('dead_send'))
  looked_up, = CoreNativeCandidates.reachable({}, [], generated + ['mrb_funcall(M, self, "unused", 0);'], core: core,
                                                exact_impls: true,
                                                strip_generated: ->(src) { src.gsub(StaticDispatchRegistrations::REGISTRATION_CALL, '') })
  suite.check('a generated by-name lookup still retains its table entry', looked_up.include?('unused'))
  body = core[0][:ireps].values.find { |irep| irep.instructions.any? { |insn| insn.op == :ALIAS } }
  unresolved = Irep.new(**body.to_h.merge(instructions: body.instructions.map do |insn|
    next insn unless insn.op == :ALIAS

    insn.dup.tap { |copy| copy.typed = insn.typed.reject { |operand| operand.kind == :name } }
  end))
  conservative = Set.new
  CoreNativeCandidates.lookup_names(unresolved, nil, conservative, Set.new)
  suite.check('an unresolved alias operand conservatively keeps every symbol',
              body.syms.all? { |name| conservative.include?(name.to_s) })

  listed = CoreNativeCandidates.candidates(entries, names, fragments)
  suite.check("only unreachable entries of their own class's tables are listed (#{listed.join(', ')})",
              listed == %w[Widget#alias_body_send Widget#dead_send Widget#defined_beside_alias Widget#defined_only
                           Widget#empty? Widget#inspect Widget#size= Widget#spin])
  header = CoreNativeCandidates.header(%w[Widget#empty? Widget#size= Widget#spin], entries)
  suite.check('the header names each listed entry by its presym C name',
              header.lines.grep(/\A#define/).sort ==
                ["#define MRB_MT_EXCLUDE_Widget_SYM_E__size 1\n", "#define MRB_MT_EXCLUDE_Widget_SYM_Q__empty 1\n",
                 "#define MRB_MT_EXCLUDE_Widget_SYM__spin 1\n"])
  ram = CoreNativeCandidates.ram_candidates(NativeOwnerMap.build([path]), names, fragments, entries)
  suite.check("run-time registrations and aliases: only unreachable keys no ROM entry shares (#{ram.join(', ')})",
              ram == %w[Widget#chain_tail Widget#id_alias Widget#lonely Widget#unused_alias])
  suite.check('an alias source and an intermediate alias still count as native lookups',
              names.include?('called') && names.include?('chain_source'))
  ruby = CoreNativeCandidates.ruby_candidates(core, names, fragments, entries)
  suite.check("unreachable core Ruby definitions, including singletons, are candidates (#{ruby.join(', ')})",
              ruby == %w[Gadget#alias_index Gadget#alias_new Gadget#defined_beside_alias Gadget.singleton#unused_singleton Widget#unused])
  suite.check('an explicit public send still reaches its core body', names.include?('public_dependency'))
  private_names, = CoreNativeCandidates.reachable(engine, [path], GENERATED, core: core,
                                                  strip_generated: CorePrivateRuby.method(:strip_generated))
  suite.check('public pruning keeps generated explicit-receiver lookups exempted only by the private proof',
              names.include?('generated_public') && !private_names.include?('generated_public'))
  unsupported = [{ registry: {
    'opaque' => [MethodDef.new(owner: '<dynamic>', name: 'opaque', irep: 'body')],
    'repeated' => [MethodDef.new(owner: 'Widget::Widget.singleton', name: 'repeated', irep: 'body')],
    'accessor' => [MethodDef.new(owner: 'Widget', name: 'accessor', kind: :ivar_accessor)]
  } }]
  suite.check('unknown or repeated owners and non-Ruby definitions are not Ruby-removal candidates',
              CoreNativeCandidates.ruby_candidates(unsupported, Set.new, Set.new, []).empty?)
end

Dir.mktmpdir('math-diagnostics') do |dir|
  path = File.join(dir, 'mruby-math', 'src', 'math.c')
  FileUtils.mkdir_p(File.dirname(path))
  source = <<~'C'
    static void domain_error(mrb_state *mrb, const char *func) {
      struct RClass *math = mrb_module_get_id(mrb, MRB_SYM(Math));
      struct RClass *domainerror = mrb_class_get_under_id(mrb, math, MRB_SYM(DomainError));
      mrb_raisef(mrb, domainerror, "Numerical argument is out of domain - %s", func);
    }
    static mrb_value math_acos(mrb_state *mrb, mrb_value self) {
      domain_error(mrb, "acos");
    }
    void init(mrb_state *mrb) {
      struct RClass *math = mrb_define_module_id(mrb, MRB_SYM(Math));
      mrb_define_module_function_id(mrb, math, MRB_SYM(acos), math_acos, MRB_ARGS_REQ(1));
    }
  C
  scan = lambda do |text, enabled: true, ireps: {}, generated: []|
    File.write(path, text)
    CoreNativeCandidates.reachable(ireps, [path], generated, diagnostic_literals: enabled)[0]
  end
  suite.check('without the literal-lookup guarantee diagnostic labels stay', scan.call(source, enabled: false).include?('acos'))
  names = scan.call(source)
  suite.check('a verified diagnostic label does not retain a Math entry', !names.include?('acos'))
  suite.check('both module-function entries become removable',
              CoreNativeCandidates.ram_candidates(NativeOwnerMap.build([path]), names, Set.new, []) ==
                %w[Math#acos Math.singleton#acos])
  live = suite.compile('Math.acos(1.0)') { |ireps, _root| ireps }
  suite.check('an actual Ruby call still retains the Math entry', scan.call(source, ireps: live).include?('acos'))
  suite.check('an actual native lookup still counts',
              scan.call(source + 'void use(mrb_state *mrb) { mrb_funcall_id(mrb, value, MRB_SYM(acos), 0); }').include?('acos'))
  suite.check('generated lookup literals still count', scan.call(source, generated: ['f("acos")']).include?('acos'))
  unsafe = {
    'changed helper body' => source.sub('mrb_raisef(mrb, domainerror,', 'mrb_funcall(mrb, value, func, 0); mrb_raisef(mrb, domainerror,'),
    'escaping function reference' => source + 'void *callback = &domain_error;',
    'nonliteral call' => source + 'void use(mrb_state *mrb) { domain_error(mrb, label); }',
    'shadowing macro' => "#define mrb_raisef other_function\n" + source,
    'spliced macro' => "#define mrb_rai\\\nsef other_function\n" + source,
    'spliced comment' => "// continued comment \\\n" + source,
    'alternative directive' => "%:define mrb_raisef other_function\n" + source,
    'scoped call' => source + 'void use(mrb_state *mrb) { other.domain_error(mrb, "other"); }'
  }
  unsafe.each do |why, text|
    suite.check("#{why} disables diagnostic exemptions", scan.call(text).include?('acos'))
  end
  other = File.join(dir, 'other.c')
  File.write(other, source)
  suite.check('an identically named helper outside mruby-math is not exempted',
              CoreNativeCandidates.reachable({}, [other], [], diagnostic_literals: true)[0].include?('acos'))
end

Dir.mktmpdir('operator-names') do |dir|
  path = File.join(dir, 'vm.c')
  scan = lambda do |text|
    File.write(path, text)
    CoreNativeCandidates.reachable({}, [path], [])[0]
  end
  suite.check('MRB_OPSYM(div) is the operator, not the name div', !scan.call('mid = MRB_OPSYM(div);').include?('div'))
  suite.check('a cdump operator row names no method', !scan.call('OPERATOR_SYMBOL("/", "div"),').include?('div'))
  suite.check('the implicit-protocol list seeds nothing', CoreNativeCandidates.reachable({}, [], [])[0].empty?)
  suite.check('MRB_SYM(div) is still a lookup', scan.call('mid = MRB_SYM(div);').include?('div'))
  suite.check('a "div" literal is still a lookup', scan.call('mrb_funcall(mrb, x, "div", 0);').include?('div'))
end

Dir.mktmpdir('label-helpers') do |dir|
  numeric = File.join(dir, '3rd', 'mruby', 'src', 'numeric.c')
  FileUtils.mkdir_p(File.dirname(numeric))
  definition = <<~'C'
    mrb_noreturn void
    mrb_int_overflow(mrb_state *mrb, const char *reason)
    {
      mrb_raisef(mrb, E_RANGE_ERROR, "integer overflow in %s", reason);
    }
  C
  caller_path = File.join(dir, 'numeric_ext.c')
  scan = lambda do |defining, calling, enabled: true|
    File.write(numeric, defining)
    File.write(caller_path, calling)
    CoreNativeCandidates.reachable({}, [numeric, caller_path], [], diagnostic_literals: enabled)[0]
  end
  call = 'void f(mrb_state *mrb) { mrb_int_overflow(mrb, "lcm"); }'
  suite.check('without the literal-lookup guarantee an overflow label stays', scan.call(definition, call, enabled: false).include?('lcm'))
  suite.check('a label passed to the verified formatter is no lookup', !scan.call(definition, call).include?('lcm'))
  suite.check('a lookup elsewhere still counts',
              scan.call(definition, "#{call} void g(mrb_state *mrb) { mrb_funcall_id(mrb, v, MRB_SYM(lcm), 0); }").include?('lcm'))
  suite.check('a label passed to another function stays', scan.call(definition, 'void f(mrb_state *mrb) { other(mrb, "lcm"); }').include?('lcm'))
  suite.check('a non-literal call keeps the literal that builds it',
              scan.call(definition, 'const char *label = "lcm"; void f(mrb_state *mrb) { mrb_int_overflow(mrb, label); }').include?('lcm'))
  unsafe = {
    'changed body' => definition.sub('mrb_raisef(', 'mrb_funcall(mrb, v, reason, 0); mrb_raisef('),
    'another definition' => "#{definition}\n#{definition}",
    'shadowing macro' => "#define mrb_int_overflow(mrb, s) mrb_funcall(mrb, v, s, 0)\n#{definition}",
    'missing definition' => 'int x;'
  }
  unsafe.each do |why, text|
    suite.check("#{why} disables the overflow-label exemption", scan.call(text, call).include?('lcm'))
  end
  File.write(numeric, definition)
  other = File.join(dir, 'other.c')
  File.write(other, definition)
  File.write(caller_path, call)
  suite.check('the formatter defined in another file is not verified',
              CoreNativeCandidates.reachable({}, [other, caller_path], [], diagnostic_literals: true)[0].include?('lcm'))
end

Dir.mktmpdir('sys-fail-labels') do |dir|
  error = File.join(dir, '3rd', 'mruby', 'src', 'error.c')
  FileUtils.mkdir_p(File.dirname(error))
  definition = <<~'C'
    MRB_API mrb_noreturn void
    mrb_sys_fail(mrb_state *mrb, const char *mesg)
    {
      if (mrb_class_defined_id(mrb, MRB_SYM(SystemCallError))) {
        struct RClass *sce = mrb_class_get_id(mrb, MRB_SYM(SystemCallError));
        mrb_int no = (mrb_int)errno;
        if (mesg != NULL) {
          mrb_funcall_id(mrb, mrb_obj_value(sce), MRB_SYM(_sys_fail), 2, mrb_fixnum_value(no), mrb_str_new_cstr(mrb, mesg));
        }
        else {
          mrb_funcall_id(mrb, mrb_obj_value(sce), MRB_SYM(_sys_fail), 1, mrb_fixnum_value(no));
        }
      }

      mrb_raise(mrb, E_RUNTIME_ERROR, mesg);
    }
  C
  file = File.join(dir, 'file.c')
  call = 'void f(mrb_state *mrb) { mrb_sys_fail(mrb, "flock"); }'
  scan = lambda do |defining = definition, calling = call, ireps: {}, generated: []|
    File.write(error, defining)
    File.write(file, calling)
    CoreNativeCandidates.reachable(ireps, [error, file], generated, diagnostic_literals: true)[0]
  end
  suite.check('a label passed to mrb_sys_fail is no lookup while no source names SystemCallError', !scan.call.include?('flock'))
  suite.check('a native that only looks SystemCallError up leaves the label no lookup',
              !scan.call(definition, "#{call} int g(mrb_state *mrb) { return mrb_class_defined(mrb, \"SystemCallError\"); }").include?('flock'))
  suite.check('a native making SystemCallError keeps the label',
              scan.call(definition, "#{call} void g(mrb_state *m) { mrb_define_class(m, \"SystemCallError\", c); }").include?('flock'))
  defined = suite.compile('class SystemCallError; end') { |ireps, _root| ireps }
  suite.check('Ruby naming SystemCallError keeps the label', scan.call(ireps: defined).include?('flock'))
  suite.check('generated code naming SystemCallError keeps the label', scan.call(generated: ['f("SystemCallError")']).include?('flock'))
  suite.check('a changed body keeps the label', scan.call(definition.sub('mrb_raise(', 'mrb_funcall(mrb, v, mesg, 0); mrb_raise(')).include?('flock'))
end

Dir.mktmpdir('enumerator-symbols') do |dir|
  path = File.join(dir, 'array.c')
  File.write(path, 'return mrb_funcall_id(mrb, self, MRB_SYM(to_enum), 1, mrb_symbol_value(MRB_SYM(rindex)));')
  scan = ->(free) { CoreNativeCandidates.reachable({}, [path], [], enumerator_free: free)[0] }
  suite.check('a to_enum Symbol stays while an Enumerator can be made', scan.call(false).include?('rindex'))
  suite.check('a to_enum Symbol is no lookup once no Enumerator is made', !scan.call(true).include?('rindex'))
  suite.check('the proof is asked when a native has a to_enum Symbol', !scan.call(-> { true }).include?('rindex'))
  suite.check('a failed proof keeps the Symbol', scan.call(-> { false }).include?('rindex'))
  suite.check('to_enum itself stays a lookup', scan.call(true).include?('to_enum'))
  File.write(path, 'mrb_funcall_id(mrb, self, MRB_SYM(to_enum), 2, mrb_symbol_value(MRB_SYM(rindex)), x);')
  suite.check('another to_enum call shape keeps the Symbol', scan.call(true).include?('rindex'))
  asked = false
  File.write(path, 'int x;')
  CoreNativeCandidates.reachable({}, [path], [], enumerator_free: -> { asked = true })
  suite.check('the proof is not made when no native has a to_enum Symbol', !asked)
end

suite.finish!
