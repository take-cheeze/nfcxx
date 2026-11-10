#!/usr/bin/env bash
# bc2cpp world: optcarrot compiled by this repository's bc2cpp (bc2cpp/, docs/notes/bc2cpp-migration.md). The world is
# the rpg-maker-clone checkout tests/bc2cpp/fetch.sh pins (its mruby fork and 3rd/optcarrot); the runner is the probe's,
# bc2cpp/tools/optcarrot_probe/compiled_run.rb: optcarrot on CRuby, on the mruby interpreter, and as a sealed mruby
# build whose Ruby bc2cpp compiled to C++, with the host C/C++ compiler.
# The check is the video checksum of the 180-frame run on examples/Lan_Master.nes: 59662, the same on every runtime
# (the runner also fails when the runtimes disagree). Prints the frames per second of each run and the speedup of
# the compiled build over the mruby interpreter (hot-path fps, which leaves out start-up and warm-up).
#   OPTCARROT_FRAMES=N        frames to run (default 180; the checksum is checked only for 180)
#   OPTCARROT_MIN_VS_YJIT=X   also fail when the compiled build's hot-path fps is under X times CRuby + YJIT's (off by default)
#   OPTCARROT_MIN_SPEEDUP=X   also fail when the compiled build's hot-path fps is under X times the interpreter's
#   BC2CPP_RPG_DIR=dir        an existing rpg-maker-clone checkout instead of the pinned one (tests/bc2cpp/fetch.sh)
# Needs Ruby 4.0 (bc2cpp reads Prism 1.x and RBS 4.x; Ruby 4.0 ships both), rake, a C/C++ compiler, bison, and make
# with a shell for Onigmo's ./configure. Without Ruby 4.0 it prints a skip.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
want=59662; frames=${OPTCARROT_FRAMES:-180}
command -v ruby >/dev/null || { echo "SKIP bc2cpp optcarrot: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp optcarrot: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp optcarrot: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp optcarrot: rake not installed"; exit 0; }

bc2cpp_fetch; status=$?
[ "$status" = 2 ] && exit 0 # a fetch failure is a network fault, not a result (fetch.sh printed why)
[ "$status" = 0 ] || exit 1
echo "bc2cpp: this tree, world rpg-maker-clone $(git -C "$bc2cpp_root" rev-parse --short HEAD), mruby fork $(git -C "$bc2cpp_root/3rd/mruby" rev-parse --short HEAD)"
# The two roots (bc2cpp/tools/bc2cpp/world_root.rb): bc2cpp is this tree, the program is the pinned world.
tree=$root/bc2cpp
export BC2CPP_TREE_ROOT=$tree BC2CPP_WORLD_ROOT=$bc2cpp_root

log=$root/build/bc2cpp/optcarrot.log
jobs=$(nproc 2>/dev/null || echo 4)
# The probe's host mrbc (3rd/mruby/bin/mrbc), from the probe's own build config (tools/optcarrot_probe/README.md); rake
# rebuilds only what changed.
(cd "$bc2cpp_root/3rd/mruby" && env -u LD MRUBY_CONFIG="$tree/tools/optcarrot_probe/mruby_build_config.rb" \
  rake -j"$jobs") > "$root/build/bc2cpp/mrbc.log" 2>&1 ||
  { tail -20 "$root/build/bc2cpp/mrbc.log"; echo "FAIL bc2cpp optcarrot: building the probe mrbc failed"; exit 1; }
# LD is the linker *driver* in the probe's rake build (it links C++); a Nix shell exports LD=ld, which cannot.
(cd "$bc2cpp_root" && env -u LD ruby "$tree/tools/optcarrot_probe/compiled_run.rb" "$frames") 2>&1 | tee "$log"
if [ "${PIPESTATUS[0]}" != 0 ]; then
  # A crash of the compiled build (signal 4 has been seen on CI runners only) says nothing by itself: when gdb is
  # there, run the sealed binary once more under it and print where it stopped.
  sealed=$(ls -d "$bc2cpp_root"/3rd/mruby/build/optcarrotcompiled*sealed/bin/optcarrot 2>/dev/null | head -1)
  if [ -n "$sealed" ] && command -v gdb >/dev/null; then
    echo "== gdb: $sealed"
    (cd "$bc2cpp_root" && gdb -q -batch -ex run -ex 'info signals SIGILL' -ex bt -ex 'x/6i $pc-12' \
      --args "$sealed" 3rd/optcarrot/examples/Lan_Master.nes "$frames") 2>&1 | grep -v -E '^\[(New|Thread) ' | tail -60
  fi
  echo "FAIL bc2cpp optcarrot: the runner failed"; exit 1
fi

compiled=$(grep -E '^mruby \+ bc2cpp \(sealed\): [0-9.]+ s' "$log" | head -1)
[ -n "$compiled" ] || { echo "FAIL bc2cpp optcarrot: no compiled result"; exit 1; }
if [ "$frames" = 180 ] && ! echo "$compiled" | grep -q "checksum=$want\$"; then
  echo "FAIL bc2cpp optcarrot: want checksum $want: $compiled"; exit 1
fi
hot_compiled=$(sed -nE 's/^mruby \+ bc2cpp \(sealed\): hot-path ([0-9.]+) frames\/s$/\1/p' "$log" | head -1)
hot_interp=$(sed -nE 's/^mruby interpreter: hot-path ([0-9.]+) frames\/s$/\1/p' "$log" | head -1)
if [ -n "$hot_compiled" ] && [ -n "$hot_interp" ]; then
  speedup=$(awk -v c="$hot_compiled" -v i="$hot_interp" 'BEGIN { printf "%.1f", c / i }')
  echo "bc2cpp optcarrot: compiled ${hot_compiled} fps, interpreter ${hot_interp} fps (hot path): ${speedup}x"
  # CRuby's own interpreter and YJIT (the probe runs YJIT when this Ruby has it), for the same 180 frames.
  hot_cruby=$(sed -nE 's/^CRuby \(interpreter\): hot-path ([0-9.]+) frames\/s$/\1/p' "$log" | head -1)
  hot_yjit=$(sed -nE 's/^CRuby \+ YJIT: hot-path ([0-9.]+) frames\/s$/\1/p' "$log" | head -1)
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "optcarrot, 180 frames, hot-path frames per second (checksum $want on every runtime)"
      echo
      echo "| runtime | fps | compiled build over it |"
      echo "| --- | ---: | ---: |"
      for row in "mruby + bc2cpp (sealed)|$hot_compiled" "mruby interpreter|$hot_interp" "CRuby interpreter|$hot_cruby" "CRuby + YJIT|$hot_yjit"; do
        [ -n "${row#*|}" ] && awk -v n="${row%|*}" -v f="${row#*|}" -v c="$hot_compiled" 'BEGIN { printf "| %s | %.1f | %.1fx |\n", n, f, c / f }'
      done
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ -n "$hot_yjit" ]; then
    echo "bc2cpp optcarrot: CRuby + YJIT ${hot_yjit} fps (hot path): compiled is $(awk -v c="$hot_compiled" -v y="$hot_yjit" 'BEGIN { printf "%.2f", c / y }')x of it"
    if [ -n "${OPTCARROT_MIN_VS_YJIT:-}" ] &&
       awk -v c="$hot_compiled" -v y="$hot_yjit" -v m="$OPTCARROT_MIN_VS_YJIT" 'BEGIN { exit !(c / y < m) }'; then
      echo "FAIL bc2cpp optcarrot: compiled build is under OPTCARROT_MIN_VS_YJIT=${OPTCARROT_MIN_VS_YJIT} of CRuby + YJIT"; exit 1
    fi
  fi
  if [ -n "${OPTCARROT_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$OPTCARROT_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp optcarrot: speedup ${speedup}x is under OPTCARROT_MIN_SPEEDUP=${OPTCARROT_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp optcarrot"
