# frozen_string_literal: true

# The probe gem's register.cxx (OptcarrotProbe.install_prelude! / install! / install_hoisted!), written from bc2cpp's
# diagnostics. A file of its own so scripts/optcarrot/register_split_check.rb can run it without the ROM or a build.

require_relative 'class_body_hoist'

module OptcarrotRegister
  module_function

  def section_lines(text, header)
    start = text.index("== #{header} ==")
    raise "missing bc2cpp diagnostic section: #{header}" unless start

    rest = text[start..]
    stop = rest.index("\n==", 1)
    body = stop ? rest[0...stop] : rest
    body.lines.drop(1).map(&:strip).reject(&:empty?)
  end

  def owner_class_expr(owner)
    singleton = owner.end_with?('.singleton')
    parts = owner.sub(/\.singleton\z/, '').split('::')
    raise "unexpected optcarrot owner: #{owner}" unless parts.all? { |part| part.match?(/\A[A-Z]\w*\z/) }

    parent = 'M->object_class'
    parts.each do |part|
      parent = "mrb_class_ptr(mrb_const_get(M, mrb_obj_value(#{parent}), " \
               "mrb_intern_cstr(M, #{part.dump})))"
    end
    [parent, singleton]
  end

  def emit_register(diagnostics, out_dir)
    # A class in `embeds` keeps its ivars in a DATA struct (MRB_SET_INSTANCE_TT) that only compiled methods read, so
    # every one of its compiled methods must be installed; installing every entry point covers that too.
    embeds = section_lines(diagnostics, 'classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)')
    rows = section_lines(diagnostics, 'compiled entry points').filter_map do |line|
      match = line.match(/^\s*(\w+) \/ \w+\s+\(([^#]+)#([^,]+), arity \d+\)(.*)$/)
      next unless match

      entry, owner, name, extra = match.captures
      raise "cannot register protected method #{owner}##{name}" if extra.include?('[protected')

      [entry, owner, name]
    end
    hoisted = rows.select do |_entry, owner, name|
      owner.end_with?('.singleton') && name.start_with?(ClassBodyHoist::PREFIX)
    end

    File.open(File.join(out_dir, 'register.cxx'), 'w') do |file|
      file.puts '#include <cstring>'
      file.puts '#include <mruby.h>'
      file.puts '#include "optcarrot_probe_decls.h"'
      file.puts '#include "optcarrot_probe_gen.cpp"'
      file.puts 'static mrb_value optcarrot_install(mrb_state* M, mrb_value) {'
      embeds.each do |owner|
        klass, = owner_class_expr(owner)
        file.puts "  MRB_SET_INSTANCE_TT(#{klass}, MRB_TT_DATA);"
      end
      # REGISTRATION_SPLIT (emit_owner_registrations): the program half resolves the Optcarrot classes by name, so
      # it waits until the bundle has defined them.
      file.puts '  bc2cpp_register_program_owner_methods(M);'
      file.puts '  return mrb_nil_value();'
      file.puts '}'
      # CORE_PRELUDE_INSTALL (sealed_build.rb): bc2cpp's core-owner half, which saves each guarded method's bytecode
      # before replacing it and registers the CORE_ALIASES names (Enumerable#map) too.
      file.puts 'static mrb_value optcarrot_install_prelude(mrb_state* M, mrb_value) {'
      file.puts '  bc2cpp_register_core_owner_methods(M);'
      file.puts '  return mrb_nil_value();'
      file.puts '}'
      # CLASS_BODY_HOIST (class_body_hoist.rb): a hoisted initializer's compiled body, put in while its class body
      # runs. False (and the interpreted method stays) when bc2cpp did not compile it.
      file.puts 'static mrb_value optcarrot_install_hoisted(mrb_state* M, mrb_value) {'
      file.puts '  mrb_value klass;'
      file.puts '  mrb_sym name;'
      file.puts '  mrb_get_args(M, "Cn", &klass, &name);'
      file.puts '  struct RClass* c = mrb_class_ptr(klass);'
      file.puts '  const char* path = mrb_class_name(M, c);'
      file.puts '  const char* method = mrb_sym_name(M, name);'
      file.puts '  static const struct { const char* owner; const char* name; mrb_func_t entry; } hoisted[] = {'
      hoisted.each do |entry, owner, name|
        file.puts "    {#{owner.delete_suffix('.singleton').dump}, #{name.dump}, #{entry}},"
      end
      file.puts '    {nullptr, nullptr, nullptr},'
      file.puts '  };'
      file.puts '  for (int i = 0; hoisted[i].owner; ++i) {'
      file.puts '    if (path && std::strcmp(hoisted[i].owner, path) == 0 && std::strcmp(hoisted[i].name, method) == 0) {'
      file.puts '      mrb_define_class_method(M, c, method, hoisted[i].entry, MRB_ARGS_ANY());'
      file.puts '      return mrb_true_value();'
      file.puts '    }'
      file.puts '  }'
      file.puts '  return mrb_false_value();'
      file.puts '}'
      file.puts 'extern "C" void mrb_optcarrot_compiled_gem_init(mrb_state* M) {'
      file.puts '  struct RClass* mod = mrb_define_module(M, "OptcarrotProbe");'
      file.puts '  mrb_define_module_function(M, mod, "install!", optcarrot_install, MRB_ARGS_NONE());'
      file.puts '  mrb_define_module_function(M, mod, "install_prelude!", optcarrot_install_prelude, MRB_ARGS_NONE());'
      file.puts '  mrb_define_module_function(M, mod, "install_hoisted!", optcarrot_install_hoisted, MRB_ARGS_REQ(2));'
      file.puts '}'
      file.puts 'extern "C" void mrb_optcarrot_compiled_gem_final(mrb_state*) {}'
    end
    rows.size
  end
end
