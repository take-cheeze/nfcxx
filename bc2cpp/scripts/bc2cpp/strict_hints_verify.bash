#!/usr/bin/env bash

# Run the real RPG2000/2003 workloads against a strict-hint verify engine and fail on any violation
# (docs/bc2cpp-strict-hints.md, ADR 0428). The engine is the sealed desktop host built with
# RPGMAKER_BC2CPP_CLOSED_WORLD_HOST=1 BC2CPP_STRICT_HINTS=all BC2CPP_NOMETHOD_VERIFY=1
# BC2CPP_HINT_VIOLATION_LOG=1: a wrong hint prints `bc2cpp: HINT_VIOLATION_LOG: <Class>#<name> at <site>`
# and the run goes on, a dead by-name arm that is reached aborts with `NOMETHOD_VERIFY`.
#
# Workloads (each skipped when its game directory is missing; at least one game must be present):
#   boot to the map, a battle, a battle played to the end, map previews, the map and chipset editors,
#   battle animations. Games: the repo's test beds (scripts/download/nepheshel.bash and
#   mtf-meido-action.bash).
#
# Usage: ENGINE=build-strict/rpg_maker_clone scripts/bc2cpp/strict_hints_verify.bash [server_num] [outdir]
#   RPG2K_VERIFY_QUICK=1  one map, one troop and the editors per game (a few minutes)
#   RPG2K_VERIFY_ALLOW_ABORT=<regex>  runs whose log matches are reported but do not fail the check
#                          (the known game bug of ADR 0428: `NilClass#evasion_up`)

set -u -o pipefail
cd "$(dirname "$0")/../.."

NUM="${1:-170}"
OUT="${2:-strict-hints-verify}"
ENGINE="${ENGINE:-./build-strict/rpg_maker_clone}"
ALLOW="${RPG2K_VERIFY_ALLOW_ABORT:-}"
mkdir -p "${OUT}"
: >"${OUT}/summary.txt"

if [ ! -x "${ENGINE}" ] ; then
    echo "error: ${ENGINE} not built (see docs/bc2cpp-strict-hints.md)" >&2
    exit 1
fi

checked=0
failed=0
run() {
    local name="$1" ; shift
    local log="${OUT}/${name}.log" rc viol abort
    NUM=$((NUM + 1))
    xvfb-run --server-num="${NUM}" timeout 120 "${ENGINE}" --test_play "$@" >"${log}" 2>&1
    rc=$?
    viol="$(grep -c 'HINT_VIOLATION_LOG\|hint violation' "${log}")"
    abort="$(grep -c 'NOMETHOD_VERIFY' "${log}")"
    echo "${name} rc=${rc} violations=${viol} aborts=${abort}" >>"${OUT}/summary.txt"
    checked=$((checked + 1))
    if grep -q 'Xvfb failed' "${log}" ; then
        # A display collision with another job says nothing about the hints: run it again once.
        NUM=$((NUM + 7))
        xvfb-run --server-num="${NUM}" timeout 120 "${ENGINE}" --test_play "$@" >"${log}" 2>&1
        rc=$?
        viol="$(grep -c 'HINT_VIOLATION_LOG\|hint violation' "${log}")"
        abort="$(grep -c 'NOMETHOD_VERIFY' "${log}")"
        echo "${name} (again) rc=${rc} violations=${viol} aborts=${abort}" >>"${OUT}/summary.txt"
    fi
    if [ "${viol}" -ne 0 ] || [ "${abort}" -ne 0 ] ; then
        if [ -n "${ALLOW}" ] && grep -q -E "${ALLOW}" "${log}" ; then
            echo "known: ${name}: matches ${ALLOW}" >>"${OUT}/summary.txt"
        else
            failed=$((failed + 1))
            echo "FAILED: ${name}: ${viol} violation(s), ${abort} abort(s)" >&2
            grep -h 'HINT_VIOLATION_LOG\|hint violation\|NOMETHOD_VERIFY' "${log}" | sort -u >&2
        fi
    elif [ "${rc}" -ne 0 ] ; then
        failed=$((failed + 1))
        echo "FAILED: ${name}: the engine exited ${rc}" >&2
    fi
}

sweep() {
    local tag="$1" game="$2" maps="$3" troops="$4" anims="$5"
    if [ ! -f "${game}/RPG_RT.ldb" ] ; then
        echo "skip ${tag}: no RPG_RT.ldb (run scripts/download/*.bash first)"
        return
    fi
    run "${tag}-new" --game_dir "${game}" --rpg2k_new_game --timeout_ms=20000
    local m t a
    for m in ${maps} ; do
        run "${tag}-map${m}" --game_dir "${game}" --rpg2k_preview_map="${m}" --timeout_ms=5000
    done
    for t in ${troops} ; do
        run "${tag}-troop${t}" --game_dir "${game}" --rpg2k_battle_troop="${t}" --rpg2k_battle_play --timeout_ms=20000
    done
    run "${tag}-mapeditor" --game_dir "${game}" --rpg2k_new_game --rpg2k_map_editor --timeout_ms=8000
    run "${tag}-chipset" --game_dir "${game}" --rpg2k_new_game --rpg2k_chipset_editor --timeout_ms=8000
    for a in ${anims} ; do
        run "${tag}-anim${a}" --game_dir "${game}" --rpg2k_new_game --rpg2k_preview_animation="${a}" --timeout_ms=6000
    done
}

if [ "${RPG2K_VERIFY_QUICK:-0}" = 1 ] ; then
    sweep nephe data/Nepheshel206beta/Nepheshel206Rbeta "371" "6" "1"
    sweep mtf data/mtf-meido-action/Debug "7" "14" ""
else
    sweep nephe data/Nepheshel206beta/Nepheshel206Rbeta \
        "1 5 20 50 80 120 160 200 240 280 320 371 400 450 500 540" \
        "1 2 3 4 5 6 7 8 9 10 12 15 20 25 30 40 50 60" "1 5 10 20 40"
    sweep mtf data/mtf-meido-action/Debug "1 2 3 4 5 6 7 8 9 10 11 12 13" \
        "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20" ""
fi

if [ "${checked}" -eq 0 ] ; then
    echo "FAILED: no game directory is present, so nothing was checked" >&2
    exit 1
fi
if [ "${failed}" -ne 0 ] ; then
    echo "strict hints verify: ${failed} of ${checked} run(s) FAILED (logs in ${OUT}/)" >&2
    exit 1
fi
echo "strict hints verify: ${checked} run(s), no violation (logs in ${OUT}/)"
