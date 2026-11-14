# Differential harness for the Ruby ports of the fetch and build scripts (tests/rb-migration/<name>/run.sh sources this).
# A case runs scripts/$RBM_NAME.sh (the bash original) and scripts/$RBM_NAME.rb (the port) in a fresh sandbox each, with the
# same arguments, environment, fixtures and stubs (stub.sh, linked under the command names it logs: curl, wget, tar, git,
# cmake, make, rake, cc, c++, g++, gcc, ar, unzip, python3 for -m pip, and the repository's nfcc and setup-mruby.sh). Then it
# compares stdout, stderr, the exit status, the stub log and the sandbox's files (type, mode, link target, sha256).
# Temporary paths are TMP in the log. The stderr of a bash-internal error (an unbound variable, a failing [) is not the
# port's to reproduce; no case reaches one.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$here/../../.." && pwd -P)
SB=$(mktemp -d); RBM_OUT=$(mktemp -d)
if [ -n "$RBM_KEEP" ]; then echo "outputs: $RBM_OUT (sandbox $SB)" >&2; else trap 'rm -rf "$SB" "$RBM_OUT"' EXIT; fi
REAL_PY=$(command -v python3)
pass=0; fail=0
RBM_ORIG_REV=510ac2f9      # origin/main when the ports were written
# the variables the stub logs when they are set (the ones the scripts pass to commands, or export)
RBM_STUB_ENV="NFCXX_BACKEND CC CXX NFCXX_CXX NFCXX_CC NFCXX_SYS_INCLUDES LIBCLANG_EDG_IN_PROCESS LIBCLANG_EDG_LDFLAGS RUSTC_VERSION MRUSTC_TARGET_VER OUTDIR_SUF MINICARGO_DEFER_CODEGEN PARLEVEL MRUBY_CONFIG MRUBY_BUILD_DIR FORCE JOBS"

# rbm_reset: a fresh sandbox: the repository's scripts, the stubs, empty work and home directories
rbm_reset() {
  rm -rf "$SB"/* "$SB"/.[!.]* 2>/dev/null
  mkdir -p "$SB/repo/scripts" "$SB/bin" "$SB/hooks" "$SB/fix" "$SB/work" "$SB/home" "$SB/tmp" "$SB/state"
  cp -r "$REPO/scripts/." "$SB/repo/scripts/"
  # the bash original is read from the commit the ports were written against: the .sh files are removed once a port matches
  git -C "$REPO" show "$RBM_ORIG_REV:scripts/$RBM_NAME.sh" > "$SB/repo/scripts/$RBM_NAME.sh" && chmod +x "$SB/repo/scripts/$RBM_NAME.sh"
  : > "$SB/log"
  for c in curl wget tar git cmake make rake cc c++ g++ gcc ar unzip python3 emcc; do ln -s "$here/stub.sh" "$SB/bin/$c"; done
  ln -s "$here/stub.sh" "$SB/repo/nfcc"
  ln -sf "$here/stub.sh" "$SB/repo/scripts/setup-mruby.sh"
}

# rbm_tree: the sandbox's files, without the stubs, the fixtures, the hooks and the log
rbm_tree() {
  cd "$SB" || return 1
  local prune=( \( -path ./bin -o -path ./hooks -o -path ./fix -o -path ./tmp -o -path ./state -o -path ./log
                  -o -path ./repo/scripts -o -path ./repo/nfcc \) -prune -o )
  find . -mindepth 1 "${prune[@]}" -printf '%y %m %p -> %l\n' | sort
  find . -mindepth 1 "${prune[@]}" -type f -print0 | sort -z | xargs -0 -r sha256sum
}

# rbm_exec ARGS...: the variant's command (RBM_CMD) in the sandbox's work directory, with the case's environment (envs)
rbm_exec() {
  (cd "$SB/work" && env -i LANG=C LC_ALL=C PATH="$SB/bin:/usr/local/bin:/usr/bin:/bin" HOME="$SB/home" TMPDIR="$SB/tmp" \
     NFCXX_STUB_LOG="$SB/log" NFCXX_STUB_TMP="$SB/tmp" NFCXX_STUB_HOOKS="$SB/hooks" NFCXX_STUB_FIX="$SB/fix" \
     NFCXX_STUB_REAL_PY="$REAL_PY" NFCXX_STUB_ENV="$RBM_STUB_ENV" $envs "$RBM_CMD" "$@")
}

# rbm_run DIR SETUP ENVSTR CMD ARGS...: one variant's run; its results go to DIR. With RBM_WARM set, the command runs once
# before the measured run (the state it leaves is the one measured: the up-to-date check).
rbm_run() {
  local dir=$1 setup=$2 envs=$3; RBM_CMD=$4; shift 4
  rbm_reset
  [ "$setup" = - ] || "$setup"
  if [ -n "$RBM_WARM" ]; then rbm_exec "$@" >/dev/null 2>&1; : > "$SB/log"; fi
  rbm_exec "$@" > "$dir/stdout" 2> "$dir/stderr"
  echo $? > "$dir/status"
  # the temporary directories have random names: shown as TMP in the output
  sed -i "s#$SB/tmp/[^ /:'\"]*#TMP#g" "$dir/stdout" "$dir/stderr"
  cp "$SB/log" "$dir/log"
  rbm_tree > "$dir/tree"
}

# rbm_case LABEL SETUP ENVSTR ARGS...: runs both variants and compares them (SETUP is a function that writes the case's
# fixtures and hooks into the sandbox, or -; ENVSTR is extra NAME=value words, or empty)
rbm_case() {
  local label=$1 setup=$2 envs=$3; shift 3
  local v dir bad="" f
  for v in bash rb; do
    dir=$RBM_OUT/$label.$v; mkdir -p "$dir"
    if [ $v = bash ]; then rbm_run "$dir" "$setup" "$envs" "$SB/repo/scripts/$RBM_NAME.sh" "$@"
    else rbm_run "$dir" "$setup" "$envs" "$SB/repo/scripts/$RBM_NAME.rb" "$@"; fi
  done
  for f in stdout stderr status log tree; do
    cmp -s "$RBM_OUT/$label.bash/$f" "$RBM_OUT/$label.rb/$f" || bad="$bad $f"
  done
  if [ -z "$bad" ]; then pass=$((pass + 1)); echo "ok    $label (status $(cat "$RBM_OUT/$label.bash/status"))"
  else
    fail=$((fail + 1)); echo "FAIL  $label:$bad"
    for f in $bad; do diff "$RBM_OUT/$label.bash/$f" "$RBM_OUT/$label.rb/$f" | head -20 | sed 's/^/      /'; done
  fi
}

# rbm_summary: the counts; the exit status is 1 when a case failed
rbm_summary() {
  echo "$RBM_NAME: $pass passed, $fail failed"
  [ "$fail" = 0 ]
}
