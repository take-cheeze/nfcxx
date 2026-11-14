#!/usr/bin/env bash
# scripts/pathb-gen-names.sh against scripts/pathb-gen-names.rb on a fixture il_def.h: the generated be/nfcxx_names.h
# and the script's output. The EDG sources are not in the checkout, so the fixture stands in for il_def.h.
NAME=pathb-gen-names
. "$(dirname "$0")/../lib.sh"

populate() {
  mkdir -p "$1/3rd/edg/src" "$1/be"
  cat > "$1/3rd/edg/src/il_def.h" <<'EOF2'
/* fixture: the shape of EDG's il_def.h */
typedef int an_expr_operator_kind;
enum an_expr_operator_kind {
	eok_none,
	eok_add,            /* a comment */
	eok_sub , eok_mul,
	eok_alias = eok_add,
	   eok_indented,
	eok_Upper,
	eok_with_digits2,
};
enum an_expr_node_kind {
	enk_lowered_eh_construct,
	enk_call,
	enk_ident
};
enum a_statement_kind {
	stmk_return,
	stmk_expr
};
enum a_dynamic_init_kind {
	dik_static,
	dik_dynamic
};
enum a_constant_repr_kind {
	ck_int,
	ck_stack_offset,
	ck_float,
};
enum an_expr_operator_kind {
	eok_duplicate_later,
};
EOF2
  echo "stale" > "$1/be/nfcxx_names.h"
}

rb_case "fixture il_def.h" ""
rb_case "enum tag not found: the script stops" "sed -i 's/^enum a_statement_kind /enum a_statement_kind_gone /' 3rd/edg/src/il_def.h"
rb_case "enum brace on its own line: not found, stops" "sed -i 's/^enum a_statement_kind {\$/enum a_statement_kind\n{/' 3rd/edg/src/il_def.h"
rb_case "no enumerator with a prefix: stops" "printf 'enum an_expr_operator_kind {\n};\n' > 3rd/edg/src/il_def.h"
rb_case "all enumerators skipped: stops" "printf 'enum an_expr_operator_kind {\n\teok_add,\n};\nenum an_expr_node_kind {\n\tenk_lowered_eh_construct,\n};\n' > 3rd/edg/src/il_def.h"
rb_case "argument is ignored" "" extra arguments
rb_case "no il_def.h" "rm 3rd/edg/src/il_def.h"
rb_done
