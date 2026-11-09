# frozen_string_literal: true

require 'set'

# ENTRY_SEEDS: the engine's entry points as seeds of the call-graph argument inference (IrCallGraphTypes).
#
# A native entry builds a maker with exactly one argument, an Array it declared itself:
#
#   src/main.cxx (desktop and browser):
#     const mrb_value args = mrb_ary_new_capa(M, argc - 1);   # ARGV, stored as em_args on the browser path
#     game_obj = mrb_obj_new(M, mrb_class_get(M, "<Maker>"), 1, &em_args | &args);
#   app/wio/src/maix_game_main.cxx (the wio closed world the type check analyses):
#     mrb_value args = mrb_ary_new(g_mrb);
#     g_game = mrb_obj_new(g_mrb, mrb_class_get(g_mrb, "RPG2k"), 1, &args);
#
# So a maker's `initialize` has a caller bc2cpp cannot see by name, and its argument is an Array. The seed is
# admitted only when that native construction is the whole of the maker's entry: every native source that spells the
# name is one of ENTRIES, each spelled mention there is a construction call, the Array is declared once and not
# reassigned, and no foreign Ruby source spells the name. Ruby `new` / `super` sites that could reach the body are
# checked by the caller (CodeGen#entry_seed_ctor_admitted?), which refuses the seed when any of them exists.
#
# The `start` receiver is not seeded here: each maker's `start` is defined in its own class, which has no subclass,
# so the closed-world self model already gives exactly that class (docs/bc2cpp-ir-call-graph.md).
#
# BC2CPP_ENTRY_SEEDS=0 turns the seeds off.
module IrEntrySeeds
  # The classes a native entry constructs with the Array (its switch on the detected GameKind, or the wio boot).
  MAKERS = %w[RPG2k RPGVX RPGXP MZ MV WolfRPG].freeze
  # Each entry file and the declarations that make its constructed argument an Array.
  ENTRIES = {
    'src/main.cxx' => ['const mrb_value args = mrb_ary_new_capa(M, argc - 1);', 'em_args = args;'],
    'app/wio/src/maix_game_main.cxx' => ['mrb_value args = mrb_ary_new(g_mrb);']
  }.freeze
  # The argument class of a construction: the Array the entry declared.
  CTOR_ARG_CLASSES = Set[:Array].freeze
  # Code tokens for construction_only?: a string literal, a comment, or an identifier. Strings and comments are
  # consumed whole, so a name inside "[RPG2k-MAP]" or after `//` is not a bare name.
  CODE_TOKEN = %r{"(?:\\.|[^"\\\n])*"|/\*.*?\*/|//[^\n]*|\b[A-Za-z_]\w*\b}m

  module_function

  # The ENTRIES key a native source path names (paths come from NATIVE_SRCS, relative or absolute), or nil.
  def entry_key(path)
    ENTRIES.keys.find { |rel| path == rel || path.end_with?("/#{rel}") }
  end

  # The construction calls of +klass+: one per build path, with the state variable and the Array argument named.
  def construction_pattern(klass)
    /mrb_obj_new\(\w+, mrb_class_get\(\w+, "#{Regexp.escape(klass)}"\), 1, &(?:em_args|args)\)/
  end

  # The entry declares its Array once and does not reassign it, so the construction passes an Array.
  def declared_array?(text, rel)
    ENTRIES.fetch(rel).all? { |declaration| text.include?(declaration) } && text.scan(/\bargs\s*=(?!=)/).size == 1
  end

  # The name reaches the entry's code only through its construction calls: no bare identifier and no string literal
  # equal to the name, outside them. A comment or a longer string that merely contains the name is inert.
  def construction_only?(text, klass)
    return false unless text.scan(construction_pattern(klass)).size.positive?

    rest = text.gsub(construction_pattern(klass), '')
    rest.scan(CODE_TOKEN).none? { |token| token == klass || token == %("#{klass}") }
  end

  # The makers whose every native spelling is a construction call in a declared-Array entry.
  #   native_files: { path => Set of identifier tokens } of the native sources the closed world scanned
  #   ruby_files:   { path => Set of identifier tokens } of the foreign Ruby sources
  #   entry_texts:  { path => text } of the native entry sources among native_files
  def admitted_makers(native_files, ruby_files, entry_texts)
    MAKERS.select do |klass|
      spelled = native_files.select { |_path, tokens| tokens.include?(klass) }.keys
      next false if spelled.empty?
      next false if ruby_files.any? { |_path, tokens| tokens.include?(klass) }

      spelled.all? do |path|
        rel = entry_key(path)
        text = entry_texts[path]
        rel && text && declared_array?(text, rel) && construction_only?(text, klass)
      end
    end.to_set
  end
end
