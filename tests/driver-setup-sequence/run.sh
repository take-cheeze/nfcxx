#!/bin/bash
# The setup steps run in the order of ./nfcxx (scripts/nfcxx-setup.rb sequence): the Path B override (bash line 539) comes after
# the sanitizer, host-cflags, gnu opts, k1om and target steps, so they see the default's backend; only the backend environment
# sees the override. Also checks that the freestanding step hands its gnu value on. cosmo is not run here: it needs cosmocc
# (scripts/setup-cosmo.sh), which CI builds.
#   bash tests/driver-setup-sequence/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
ruby -e '
  require File.join(ARGV[0], "scripts", "nfcxx-setup")
  base = {"backend"=>"","backend_explicit"=>"0","freestanding"=>"0","cosmo"=>"0","emit_c"=>"0","target"=>"","preprocess"=>"0",
          "depmode"=>"","shared"=>"0","path_b"=>"0","host"=>"Linux x86_64","asan"=>"0","asanopts"=>"","instantiate"=>"used",
          "sys"=>"Linux","gnu"=>"","root"=>ARGV[0],"dialect"=>"g++","mach"=>"x86_64","gnu_opts"=>""}
  seen = ->(o) { NfcxxSetup.sequence(o, {})[:steps].to_h { |n, _, b| [n, b] } }
  ok = true
  check = ->(name, cond) { puts(cond ? "ok   #{name}" : "FAIL #{name}"); ok &&= cond }

  # 1. the override: shared makes the default gcc, path_b then makes the final backend pathb
  o = base.merge("shared"=>"1", "path_b"=>"1")
  r = NfcxxSetup.sequence(o, {})
  s = r[:steps].to_h { |n, _, b| [n, b] }
  %w[asan instantiate freestanding host_cflags gnu_opts k1om target].each { |n| check.("#{n} sees gcc before the override", s[n] == "gcc") }
  check.("backend_env sees pathb after the override", s["backend_env"] == "pathb")
  check.("final backend is pathb", r[:state]["backend"] == "pathb")

  # 2. no override: the default is used everywhere
  o = base.merge("shared"=>"1")
  s = seen.(o)
  check.("without path_b, backend_env sees gcc too", s["backend_env"] == "gcc" && s["host_cflags"] == "gcc")

  # 3. the default pathb (no reason for gcc): every step sees pathb
  o = base
  s = seen.(o)
  check.("default pathb: every step after default sees pathb", s.reject { |n, _| n == "default" }.values.all? { |b| b == "pathb" })

  # 4. the freestanding step hands its gnu on
  r = NfcxxSetup.sequence(base.merge("freestanding"=>"1"), {})
  check.("freestanding sets gnu", r[:state]["gnu"].to_s.match?(/\A\d+\z/))
  check.("gnu opts take the gnu value", r[:state]["gnu_opts"].to_s == "--gnu_version=130000")
  exit(ok ? 0 : 1)
' "$repo"
st=$?
[ $st = 0 ] && pass=1 || fail=1
echo "driver-setup-sequence: $pass passed, $fail failed"
exit $st
