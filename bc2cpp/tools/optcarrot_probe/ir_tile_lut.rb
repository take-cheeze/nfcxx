# frozen_string_literal: true

require 'tmpdir'
require_relative '../bc2cpp/bytecode_ir_tile_lut'

module OptcarrotIRTileLUT
  CORE_METHODS = { 'Array' => %w[map each transpose [] []=], 'Range' => %w[map each],
                   'Integer' => %w[* + - | >> & != ==] }.freeze

  def self.prepare(source, directory, mrbc: MRBC)
    path = File.join(directory, 'ir_lut_candidate.rb')
    File.write(path, source)
    candidates, = compile_ireps([path], 'ir_lut_candidate', directory, mrbc: mrbc)
    reference_path = File.expand_path('../bc2cpp/fixtures/tile_lut.rb', __dir__)
    reference_image = run_mrbc([reference_path], 'ir_lut_reference', directory, mrbc: mrbc)
    references, = load_ireps(reference_image)
    reference = references.values.find { |irep| irep.enter && irep.enter.enter_fields.first.zero? }
    matches = candidates.values.filter_map { |irep| BytecodeIR::TileLUT.build(irep, reference) }
    raise 'expected exactly one decoded tile LUT generator' unless matches.size == 1

    shim_path = File.join(directory, 'ir_lut_bitref.rb')
    File.write(shim_path, 'class Integer; def [](i); (self >> i) & 1; end; end')
    shim_image = run_mrbc([shim_path], 'ir_lut_bitref', directory, mrbc: mrbc)
    shim = RiteBinary.parse(shim_image.bytes).find { |irep| irep.rlen.zero? }
    raise 'unexpected bitref shim structure' unless shim.pool.empty? && shim.catch_handlers.empty?

    [matches.first.emit + runtime_tree(RiteBinary.parse(reference_image.bytes).drop(1)) + guards(shim), capture]
  end

  def self.capture
    guards = CORE_METHODS.flat_map { |klass, methods| methods.map { |name| [klass, name] } }
    guards.map.with_index do |(klass, name), index|
      "  optcarrot_lut_baseline[#{index}] = optcarrot_lut_lookup(M, mrb_class_get(M, #{klass.dump}), mrb_intern_lit(M, #{name.dump}));\n" \
        "  if (!MRB_METHOD_UNDEF_P(optcarrot_lut_baseline[#{index}]) && MRB_METHOD_PROC_P(optcarrot_lut_baseline[#{index}])) mrb_gc_register(M, mrb_obj_value(const_cast<RProc*>(MRB_METHOD_PROC(optcarrot_lut_baseline[#{index}]))));"
    end.join("\n") + "\n" + <<~CPP
      optcarrot_lut_bitref = optcarrot_lut_lookup(M, M->integer_class, mrb_intern_lit(M, "[]"));
      if (!MRB_METHOD_UNDEF_P(optcarrot_lut_bitref) && MRB_METHOD_PROC_P(optcarrot_lut_bitref)) mrb_gc_register(M, mrb_obj_value(const_cast<RProc*>(MRB_METHOD_PROC(optcarrot_lut_bitref))));
      mrb_define_module_function(M, mod, "install_tile_lut!", optcarrot_install_tile_lut, MRB_ARGS_REQ(1));
    CPP
  end

  def self.runtime_tree(nodes)
    definitions = nodes.each_with_index.to_a.reverse.map do |node, index|
      raise 'unexpected initializer pool or child shape' unless node.pool.empty? && node.rlen <= 1 && node.catch_handlers.empty?

      symbols = node.syms.map.with_index { |name, offset| "if (strcmp(mrb_sym_name(M, irep->syms[#{offset}]), #{name.dump})) return false;" }.join("\n")
      <<~CPP
        static bool optcarrot_lut_tree_#{index}(mrb_state* M, const mrb_irep* irep) {
          static const mrb_code expected[] = {#{node.iseq.bytes.join(', ')}};
          if (!irep || irep->nlocals != #{node.nlocals} || irep->nregs != #{node.nregs} || irep->ilen != sizeof(expected) ||
              irep->plen != 0 || irep->rlen != #{node.rlen} || irep->clen != 0 || irep->slen != #{node.syms.size}) return false;
          if (memcmp(irep->iseq, expected, sizeof(expected))) return false;
          #{symbols}
          return #{node.rlen.zero? ? 'true' : "optcarrot_lut_tree_#{index + 1}(M, irep->reps[0])"};
        }
      CPP
    end
    definitions.join("\n")
  end

  def self.guards(shim)
    methods = CORE_METHODS.flat_map { |klass, names| names.map { |name| [klass, name] } }
    checks = methods.map.with_index do |(klass, name), index|
      "if (!optcarrot_lut_same(optcarrot_lut_baseline[#{index}], optcarrot_lut_lookup(M, mrb_class_get(M, #{klass.dump}), mrb_intern_lit(M, #{name.dump})))) return false;"
    end.join("\n")
    symbols = shim.syms.map.with_index { |name, index| "if (strcmp(mrb_sym_name(M, irep->syms[#{index}]), #{name.dump})) return false;" }.join("\n")
    <<~CPP
      static mrb_method_t optcarrot_lut_baseline[#{methods.size}];
      static mrb_method_t optcarrot_lut_bitref;
      static mrb_method_t optcarrot_lut_lookup(mrb_state* M, struct RClass* klass, mrb_sym name) {
        return mrb_method_search_vm(M, &klass, name);
      }
      static bool optcarrot_lut_same(mrb_method_t a, mrb_method_t b) {
        if (MRB_METHOD_UNDEF_P(a) || MRB_METHOD_UNDEF_P(b)) return false;
        if (MRB_METHOD_CFUNC_P(a) != MRB_METHOD_CFUNC_P(b)) return false;
        return MRB_METHOD_CFUNC_P(a) ? MRB_METHOD_CFUNC(a) == MRB_METHOD_CFUNC(b) : MRB_METHOD_PROC(a) == MRB_METHOD_PROC(b);
      }
      static bool optcarrot_lut_shim(mrb_state* M, mrb_method_t method) {
        if (MRB_METHOD_UNDEF_P(method) || MRB_METHOD_CFUNC_P(method) || MRB_PROC_ALIAS_P(MRB_METHOD_PROC(method))) return false;
        const mrb_irep* irep = MRB_METHOD_PROC(method)->body.irep;
        static const mrb_code expected[] = {#{shim.iseq.bytes.join(', ')}};
        if (irep->nlocals != #{shim.nlocals} || irep->nregs != #{shim.nregs} || irep->ilen != sizeof(expected) ||
            irep->plen != 0 || irep->rlen != 0 || irep->clen != 0 || irep->slen != #{shim.syms.size}) return false;
        if (memcmp(irep->iseq, expected, sizeof(expected))) return false;
        #{symbols}
        return true;
      }
      static bool optcarrot_lut_valid(mrb_state* M) {
        #{checks}
        mrb_method_t bitref = optcarrot_lut_lookup(M, M->integer_class, mrb_intern_lit(M, "[]"));
        if (!optcarrot_lut_same(bitref, optcarrot_lut_bitref) && !optcarrot_lut_shim(M, bitref)) return false;
        return true;
      }
      static mrb_value optcarrot_ir_tile_lut(mrb_state* M, mrb_value self) {
        if (!optcarrot_lut_valid(M)) return mrb_funcall(M, self, "__bc2cpp_tile_lut_fallback", 0);
        return optcarrot_ir_tile_lut_build(M, self);
      }
      static mrb_value optcarrot_install_tile_lut(mrb_state* M, mrb_value) {
        struct RClass* target;
        mrb_get_args(M, "C", &target);
        if (!optcarrot_lut_valid(M)) return mrb_false_value();
        if (target != mrb_class_get_under(M, mrb_module_get(M, "Optcarrot"), "PPU")) return mrb_false_value();
        struct RClass* singleton = mrb_singleton_class_ptr(M, mrb_obj_value(target));
        mrb_sym fallback = mrb_intern_lit(M, "__bc2cpp_tile_lut_fallback");
        if (!MRB_METHOD_UNDEF_P(optcarrot_lut_lookup(M, singleton, fallback))) return mrb_false_value();
        mrb_sym helper = mrb_intern_lit(M, "__bc2cpp_tile_lut");
        mrb_method_t original = optcarrot_lut_lookup(M, singleton, helper);
        if (MRB_METHOD_UNDEF_P(original) || MRB_METHOD_CFUNC_P(original) || MRB_PROC_ALIAS_P(MRB_METHOD_PROC(original)) ||
            !optcarrot_lut_tree_0(M, MRB_METHOD_PROC(original)->body.irep)) return mrb_false_value();
        mrb_alias_method(M, singleton, fallback, helper);
        mrb_define_class_method(M, target, "__bc2cpp_tile_lut", optcarrot_ir_tile_lut, MRB_ARGS_NONE());
        return mrb_true_value();
      }
    CPP
  end
end
