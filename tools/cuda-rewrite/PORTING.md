# Porting scripts/cuda-rewrite.rb to C++

The Ruby script is the reference. The C++ tool must give byte-identical stdout, stderr and exit codes on every input
the differential script covers (`tools/cuda-rewrite/diff-ruby-cxx.sh`), before the driver switches to it.

## Status

Ported: the lexical layer (`text_before`, `white?`, `ident_char?`, `refuse`, `skip_literal`, `matching_paren`,
`split_config`, `split_top`, `index_code`, `sanitize`, `wrapper_name`, `piece_at`).

Not ported (Ruby line numbers as of origin/main, 3,409 lines, 107 functions):
- Template launches and instances: `split_top` users, `kernel_template*`, `substitute`, `template_site`,
  `dependent_on_template`, `angle_index`, `matching_angle`, `directive_spans`, `directive_ends`, `template_launches`,
  `matching_brace`, `template_bodies`, `enclosing_template`, `local_constant*`, `member_qualifier`, `member_instances`,
  `call_sites`, `plain_call_sites`, `caller_arg_type`, `template_head_of`, `deduce_call_targs`, `template_instances`,
  `line_col`, `line_start`, `dependent_launches`, `dependent_decls`, `rewrite` (lines 1037-1190).
- Launch macros and argument types: `launch_macros`, `define_name_at?`, `expand_launch_macros`, `launch_arguments`,
  `targs_span`, `type_tokens`, `type_before`, `comma_declaration_type`, `argument_type`, `match_type`, `deduce_types`,
  `plain_launches`, `deduce_launch_targs`, `launch_prepare`.
- Device prelude and builtins (embedded text, must match byte for byte): `DEVICE_BUILTINS`, `DEVICE_PRELUDE`,
  `vector_defs`/`VECTOR_DEFS`, `SHFL_DEFS`, `HALF_CORE`/`HALF_LANE`, `HMAXL`, `BUILTIN_DEFS`, `COOP_DEF`,
  `rewrite_builtins`, `device_decls`.
- Tokens and top-level pieces: `tokens_of`, `code_text`, `code_only?`, `brace_is_initializer?`, `top_pieces`,
  `remove_words`, `function_name`.
- Includes and conditionals: `system_path?`, `find_include`, `expand_includes`, `cond_*`, `resolve_conditionals`.
- Device unit and host unit: `tag_after`, `enum_enumerators`, `blank_comments`, `function_head?`,
  `device_constant_decl?`, `linkage_block`, `namespace_opened?`, `flatten_linkage`, `device_tu`, `rewrite_is_same_v`,
  `strip_launch_bounds`, `dynamic_shared_rewrite`, `refuse_shared_align`, `refuse_unlowered_cccl`, `enclosing_block*`,
  `block_index`, `static_shared_names`, `shadowed_by_static?`, `token_positions`, `declares_name?`,
  `declaration_scope`, `replace_dynamic_uses`, `host_storage`, `in_class_body?`, `host_linkage`.
- The CLI (`main` section at the end of the Ruby script: flags, `--device`, `--kernels=FILE`, `--edg-launches`, `-I`).

Ruby semantics to keep: `s[i]` is a byte (nil past the end, see `ch()`); `s.index` is a byte index; `String#strip`;
`gsub` with a string pattern replaces left to right, without overlap; `split("\n")` drops trailing empty fields
(check each use); `lstrip`/`start_with?` as used by the include filter.
