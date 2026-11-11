#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/html/cpp/language" "$tmp/out"
cat > "$tmp/html/cpp/language/example.html" <<'EOF'
<pre>not an example</pre>
<div class="t-example"><div class="cpp source-cpp"><pre><span>int</span> main() { return 2 &lt; 3 ? 0 : 1; }&#160;// &amp; &#x41;</pre></div><div class="text source-text"><pre>&quot;OK&quot;</pre></div></div>
<div class="t-example"><div class="cpp source-cpp"><pre>static_assert(true);</pre></div></div>
EOF
scripts/mrb tests/upstream/cppreference-extract.rb "$tmp/html" "$tmp/out" cpp/language/example.html > "$tmp/inventory.tsv"
[ "$(wc -l < "$tmp/inventory.tsv")" -eq 3 ]
printf 'int main() { return 2 < 3 ? 0 : 1; } // & A\n' > "$tmp/expected.cpp"
cmp "$tmp/out/example-1.cpp" "$tmp/expected.cpp"
printf '"OK"\n' > "$tmp/expected.output"
cmp "$tmp/out/example-1.output" "$tmp/expected.output"
test ! -f "$tmp/out/example-2.output"
cp "$tmp/html/cpp/language/example.html" "$tmp/html/cpp/language/sizeof.html"
cp "$tmp/html/cpp/language/example.html" "$tmp/html/cpp/language/sizeof....html"
scripts/mrb tests/upstream/cppreference-extract.rb "$tmp/html" "$tmp/out" \
  cpp/language/sizeof.html cpp/language/sizeof....html > "$tmp/sizeof.tsv"
test -f "$tmp/out/sizeof-1.cpp"
test -f "$tmp/out/sizeof...-1.cpp"
if scripts/mrb tests/upstream/cppreference-extract.rb "$tmp/html" "$tmp/out" \
  cpp/language/sizeof.html cpp/language/sizeof.html > /dev/null 2>&1; then
  echo 'duplicate example ID accepted' >&2; exit 1
fi
if scripts/mrb tests/upstream/cppreference-extract.rb "$tmp/html" "$tmp/out" ../escape.html > /dev/null 2>&1; then
  echo 'unsafe page path accepted' >&2; exit 1
fi
printf '<div class="t-example"><pre>broken' > "$tmp/html/broken.html"
if scripts/mrb tests/upstream/cppreference-extract.rb "$tmp/html" "$tmp/out" broken.html > /dev/null 2>&1; then
  echo 'truncated example accepted' >&2; exit 1
fi
mkdir -p "$tmp/jp/lang/cpp14" "$tmp/jp-out"
cat > "$tmp/jp/lang/cpp14/lambda.md" <<'EOF'
```cpp
not a runnable example;
```
```cpp example
int main() { return 0; }
```
```text
illustrative output
```
EOF
scripts/mrb tests/upstream/cpprefjp-extract.rb "$tmp/jp" "$tmp/jp-out" lang/cpp14/lambda.md > "$tmp/jp.tsv"
[ "$(wc -l < "$tmp/jp.tsv")" -eq 2 ]
grep -q 'int main() { return 0; }' "$tmp/jp-out/lang--cpp14--lambda-1.cpp"
! grep -q 'not a runnable' "$tmp/jp-out/lang--cpp14--lambda-1.cpp"
scripts/mrb tests/upstream/reference-manifest.rb cpprefjp "$tmp/jp.tsv" > "$tmp/jp-manifest.tsv"
grep -q $'\tc++14\t' "$tmp/jp-manifest.tsv"
mkdir -p "$tmp/modes/feature"
printf 'eccp: unknown option: --c++29\n' > "$tmp/modes/feature/gcc.log"
printf 'suite\tid\tpage\tstandard\troute\tstatus\texit\ncpprefjp\tfeature\tp.md\tc++29\tgcc\trejected\t2\n' > "$tmp/modes.tsv"
scripts/mrb tests/upstream/normalize-survey.rb "$tmp/modes" "$tmp/modes.tsv" > "$tmp/normalized.tsv"
grep -q $'\tmode-unavailable\t' "$tmp/normalized.tsv"
echo 'reference extraction, collision, manifest and mode checks passed'
