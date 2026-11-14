#!/usr/bin/env bash
# scripts/pathb-borrowck-tally.sh against scripts/pathb-borrowck-tally.rb. The fixture is a tree with the programs
# the default file list finds. scripts/pathb-dump and scripts/mrb are stubs in the tree: a program's first line
# "// VERDICT: WORD [TEXT]" picks what the checker stub does with it (accept, error, malformed, refuse TEXT,
# refuse-infer: refused unless --infer-loan-ends, crash: exit 7), and "nolower" in a file name makes lowering fail.
NAME=pathb-borrowck-tally
. "$(dirname "$0")/../lib.sh"

populate() {
  mkdir -p "$1/tests/pathb-ir/borrow" "$1/tests/cases" "$1/tests/cpp-features/x" "$1/tests/cpp2/y" \
           "$1/tests/pathb-borrow/cpp" "$1/tests/pathb-borrow/contracts" "$1/tests/cpp-features/z"
  printf '// VERDICT: accept\nint a;\n' > "$1/tests/pathb-ir/a.cpp"
  printf '// VERDICT: refuse-infer\nint b;\n' > "$1/tests/pathb-ir/borrow/b.cpp"
  printf '// VERDICT: error\nint c;\n' > "$1/tests/cases/c.cpp"
  printf '// VERDICT: refuse closure at line 12 kind 3\n' > "$1/tests/cpp-features/x/d.cpp"
  printf '// VERDICT: refuse closure at line 7 kind 9\n' > "$1/tests/cpp-features/x/e.cpp"
  printf '// VERDICT: accept\n' > "$1/tests/cpp-features/z/nolower.cpp"
  printf '// VERDICT: malformed\n' > "$1/tests/cpp2/y/f.cpp"
  printf '// VERDICT: refuse-infer\n' > "$1/tests/pathb-borrow/cpp/g.cpp"
  printf '// VERDICT: crash\n' > "$1/tests/pathb-borrow/contracts/h.cpp"
  printf '// VERDICT: refuse uses a union member\n' > "$1/tests/pathb-borrow/contracts/i.cpp"
  printf '// VERDICT: accept\n' > "$1/tests/pathb-ir/h.cpp"
  printf 'no verdict line at all\n' > "$1/tests/cases/k.cpp"
  cat > "$1/scripts/pathb-dump" <<'EOS'
#!/usr/bin/env bash
# stub: pathb-dump --ir FILE prints the program with the lowering note, or fails for "nolower" programs
[ "$1" = --ir ] || exit 9
case $2 in *nolower*) exit 1 ;; esac
echo "// lowered with NFCXX_PATHB_BORROW=$NFCXX_PATHB_BORROW"
cat "$2"
EOS
  cat > "$1/scripts/mrb" <<'EOS'
#!/usr/bin/env bash
# stub: mrb SCRIPT ARGS... IR: the checker's verdict for the IR's VERDICT line; stderr gets an inferred: line too
ir=${@: -1}
verdict=$(sed -n 's|^// VERDICT: ||p' "$ir" | head -1)
echo "inferred: 2 summaries" >&2
case $verdict in
  accept) echo accepted ;;
  error) echo "error: borrow of x at line 3" >&2; exit 1 ;;
  malformed) echo "malformed ir" >&2; exit 2 ;;
  refuse-infer)
    case " $* " in
      *" --infer-loan-ends "*) echo "accepted after inference" ;;
      *) echo "refused: loan 9 needs inference" >&2; exit 3 ;;
    esac ;;
  refuse*) echo "refused: ${verdict#refuse } (limit 42)" >&2; exit 3 ;;
  crash) exit 7 ;;
  *) echo "no verdict" >&2; exit 5 ;;
esac
EOS
  chmod +x "$1/scripts/pathb-dump" "$1/scripts/mrb"
}

rb_case "default file list" ""
rb_case "explicit files, one missing and one not lowered" "" tests/pathb-ir/a.cpp tests/cases/c.cpp nope.cpp tests/cpp-features/z/nolower.cpp
rb_case "explicit files with -o keeps the IR and the tables" "" -o keep tests/pathb-ir/a.cpp tests/pathb-ir/borrow/b.cpp tests/cpp2/y/f.cpp
rb_case "default list with -o keeps everything" "" -o keep
rb_case "-o with an empty directory name uses a temporary one" "" -o ""
rb_case "no verdict line and a crash" "" tests/cases/k.cpp tests/pathb-borrow/contracts/h.cpp
rb_done
