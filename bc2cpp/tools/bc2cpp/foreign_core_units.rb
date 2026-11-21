# frozen_string_literal: true

# FOREIGN_CORE_UNITS: with MRB_CORE_CLASS_UNITS no core mrblib is loaded, so a core file kept out of the compiled world
# (BC2CPP_CORE_MRBLIB_EXCLUDED: 10error.rb) would never run. Its top-level classes become units straight from the source
# when each body statement is one a unit can make without the registry: an attr_* call, or a def a program file defines
# again on the same class (registered there). Anything else leaves the class out, and the residual warning names it.

require 'prism'

module ForeignCoreUnits
  ATTRS = { 'attr_accessor' => [true, true], 'attr_reader' => [true, false], 'attr' => [true, false],
            'attr_writer' => [false, true] }.freeze

  module_function

  # The excluded files mrb_init_mrblib would have loaded (mruby's own mrblib/*.rb), in load order.
  def files(world_root)
    BC2CPP_CORE_MRBLIB_EXCLUDED.select { |tail| tail.start_with?('mrblib/') }
                               .map { |tail| File.join(world_root, '3rd/mruby', tail) }.select { |p| File.file?(p) }.sort
  end

  # Units in compile_top_class_units' shape ({path:, name:, file:, code:}). `redefined` answers whether a program file
  # defines owner#name, so a def here is registered by that definition.
  def units(paths, redefined)
    paths.flat_map do |file|
      (Prism.parse(File.binread(file)).value.statements&.body || []).filter_map.with_index do |stmt, index|
        unit(stmt, file, index, redefined)
      end
    end
  end

  def unit(stmt, file, index, redefined)
    return nil unless stmt.is_a?(Prism::ClassNode) && stmt.constant_path.is_a?(Prism::ConstantReadNode)

    path = stmt.constant_path.name.to_s
    superclass = case stmt.superclass
                 when nil then 'mrb_nil_value()'
                 when Prism::ConstantReadNode
                   "mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, \"#{stmt.superclass.name}\"))"
                 end
    return nil unless superclass

    lines = (stmt.body&.body || []).map { |node| body_line(node, path, redefined) }
    return nil if lines.any?(&:nil?)

    name = "#{path}_x#{index}"
    code = "#{CodeGen::CLASS_UNIT_DECLS}static void bc2cpp_top_unit_#{name}(mrb_state* M) {\n" \
           "  mrb_value self = mrb_obj_value(mrb_vm_define_class(M, mrb_obj_value(M->object_class), #{superclass}, " \
           "mrb_intern_cstr(M, \"#{path}\")));\n  (void)self;\n#{lines.join}}\n"
    { path: path, name: name, file: file, code: code }
  end

  def body_line(node, path, redefined)
    case node
    when Prism::CallNode
      reader, writer = ATTRS[node.name.to_s]
      args = node.arguments&.arguments || []
      return nil unless node.receiver.nil? && !reader.nil? && !args.empty? && args.all?(Prism::SymbolNode)

      syms = args.map { |sym| "mrb_symbol_value(mrb_intern_cstr(M, \"#{sym.unescaped}\"))" }
      "  (void)bc2cpp_mod_attr(M, self, #{reader}, #{writer}, {#{syms.join(', ')}});\n"
    when Prism::DefNode
      return nil unless node.receiver.nil? && redefined.call(path, node.name.to_s)

      "  // #{path}##{node.name} registered by its program definition\n"
    end
  end
end
