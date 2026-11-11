#!/usr/bin/env bash
# The mruby gems vendored under 3rd/ (JSON: mattn/mruby-json; regexp: mattn/mruby-onig-regexp, Onigmo bundled by the
# gem) are in the scripts/mrb interpreter. Checks their basic behaviour; exits 1 on a wrong result.
cd "$(dirname "$0")/../.."
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'RB'
ok = true
check = lambda { |name, got, want| (puts "FAIL #{name}: got #{got.inspect}, want #{want.inspect}"; ok = false) unless got == want }
check.call('json parse', JSON.parse('{"a": [1, 2.5, "x", null, true]}'), {"a" => [1, 2.5, "x", nil, true]})
check.call('json generate', JSON.generate({"k" => [1, "two"]}), '{"k":[1,"two"]}')
m = OnigRegexp.compile('(\w+)@(\w+)').match('mail bob@example now')
check.call('onig groups', [m[0], m[1], m[2]], ['bob@example', 'bob', 'example'])
check.call('onig anchors', OnigRegexp.compile('^a.c$').match('abc') ? :yes : :no, :yes)
puts(ok ? 'mruby gems: ok' : 'mruby gems: FAILED')
exit(ok ? 0 : 1)
RB
scripts/mrb "$tmp"
