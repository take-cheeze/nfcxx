#!/usr/bin/env bash
# scripts/mrustc-borrowck.sh against scripts/mrustc-borrowck.rb. mrustc is a stub ($RB_WORK/bin/mrustc, via MRUSTC):
# it writes the dump (the source itself) and fails as the source's "// STUB:" line says. scripts/monomir-to-pathb.rb
# and scripts/mrb are stubs in the tree. The checker's verdict is the source's "// VERDICT:" line (as in the
# pathb-borrowck-tally test). A stub mrustc killed by a signal is not compared: the shell reports that itself.
NAME=mrustc-borrowck
. "$(dirname "$0")/../lib.sh"

mkdir -p "$RB_WORK/std"
: > "$RB_WORK/std/libstd.rlib.o"
export MRUSTC="$RB_WORK/bin/mrustc" MRUSTC_STD="$RB_WORK/std"
cat > "$RB_WORK/bin/mrustc" <<'EOS'
#!/usr/bin/env bash
# stub mrustc SRC flags...: writes OUT.mir (the source), OUT_1_ast.rs, OUT_2_hir.rs; prints the flags after dump-ast
src=$1; shift
args=("$@"); out=
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[i]}" = -o ] && out=${args[i+1]}; done
after=0
for a in "$@"; do
  [ $after = 1 ] && echo "extra flag: $a"
  [ "$a" = dump-ast ] && after=1
done
case $(sed -n 's|^// STUB: ||p' "$src" | head -1) in
  mrustc-fail) echo "mrustc: internal error" >&2; exit 101 ;;
  mir-validation) echo "MIR ERROR: Use of non-valid lvalue _3 in main"; echo "MIR ERROR: second"; exit 1 ;;
  lifetime) echo "src/main.rs:4 error:0: Lifetime bound 'a failed in foo"; echo "unrelated"; exit 1 ;;
  lifetime-no-text) echo "error:0: Lifetime bound x failed"; exit 1 ;;
  many-lines) for i in $(seq 1 25); do echo "log line $i"; done >&2; exit 101 ;;
esac
cp "$src" "$out.mir"; echo ast > "${out}_1_ast.rs"; echo hir > "${out}_2_hir.rs"
EOS
chmod +x "$RB_WORK/bin/mrustc"

populate() {
  mkdir -p "$1/scripts" "$1/sub"
  cat > "$1/scripts/mrb" <<'EOS'
#!/usr/bin/env bash
# stub: mrb SCRIPT ARGS... IR: the verdict is the IR's VERDICT line
ir=${@: -1}
verdict=$(sed -n 's|^// VERDICT: ||p' "$ir" | head -1)
echo "inferred: 2 summaries" >&2
case $verdict in
  accept) echo accepted ;;
  error) echo "error: borrow of x at line 3" >&2; exit 1 ;;
  malformed) echo "malformed ir" >&2; exit 2 ;;
  refuse*) echo "refused: ${verdict#refuse } (limit 42)" >&2; exit 3 ;;
  *) echo "no verdict" >&2; exit 5 ;;
esac
EOS
  cat > "$1/scripts/monomir-to-pathb.rb" <<'EOS'
#!/usr/bin/env ruby
# stub: the last two arguments are the MIR and the IR; the IR copies the MIR unless it asks to fail
mir, ir = ARGV[-2], ARGV[-1]
text = File.read(mir)
if text.include?("// STUB: monomir-fail")
  warn "monomir: cannot translate"
  exit 1
end
File.write(ir, text)
EOS
  chmod +x "$1/scripts/mrb" "$1/scripts/monomir-to-pathb.rb"
}

rb_case "accepted" "printf '%s\n' '// VERDICT: accept' > prog.rs" prog.rs
rb_case "refused" "printf '%s\n' '// VERDICT: refuse closure capturing a reference' > prog.rs" prog.rs
rb_case "checker error" "printf '%s\n' '// VERDICT: error' > prog.rs" prog.rs
rb_case "malformed IR" "printf '%s\n' '// VERDICT: malformed' > prog.rs" prog.rs
rb_case "no verdict from the checker" "printf '%s\n' 'fn main() {}' > prog.rs" prog.rs
rb_case "source in a subdirectory" "printf '%s\n' '// VERDICT: accept' > sub/prog.rs" sub/prog.rs
rb_case "mrustc's MIR validation is the verdict" "printf '%s\n' '// STUB: mir-validation' > prog.rs" prog.rs
rb_case "mrustc's lifetime check is the verdict" "printf '%s\n' '// STUB: lifetime' > prog.rs" prog.rs
rb_case "lifetime failure with no text" "printf '%s\n' '// STUB: lifetime-no-text' > prog.rs" prog.rs
rb_case "mrustc fails: its log tail, status 4" "printf '%s\n' '// STUB: mrustc-fail' > prog.rs" prog.rs
rb_case "mrustc fails after many lines: last 20 kept" "printf '%s\n' '// STUB: many-lines' > prog.rs" prog.rs
rb_case "extra flags are passed to mrustc" "printf '%s\n' '// STUB: mrustc-fail' > prog.rs" prog.rs --cfg 'feature="x"' -C opt-level=0
rb_case "translator fails: status 4" "printf '%s\n' '// VERDICT: accept' '// STUB: monomir-fail' > prog.rs" prog.rs
rb_case "no .rs argument: usage" "" --cfg x
MRUSTC= rb_case "no mrustc under the tree: status 4" "printf '%s\n' '// VERDICT: accept' > prog.rs" prog.rs
MRUSTC=/nonexistent/mrustc rb_case "MRUSTC names a missing file" "printf '%s\n' '// VERDICT: accept' > prog.rs" prog.rs
MRUSTC_BORROWCK_KEEP=keep rb_case "kept dump and checker input" "printf '%s\n' '// VERDICT: accept' > prog.rs" prog.rs
MRUSTC_TARGET_VER=1.91 rb_case "target version from the environment" "printf '%s\n' '// VERDICT: accept' > prog.rs" prog.rs
rb_done
