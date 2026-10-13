#!/usr/bin/env bash
# Compile and run real SYCL programs through lib/sycl: the host path (g++) and the WebGPU path (scripts/sycl-build.sh with nfcxx).
#   tests/sycl/compat/run-samples.sh DIR LIST OUTDIR
# DIR is a source tree (untrusted: read the programs before running them), LIST a file of paths relative to DIR (for
# example the "ok" rows of the sweep.sh results.tsv), each optionally followed by the program's arguments. Writes
# OUTDIR/samples.tsv. SKIP_HOST=1 leaves out the host path; SAMPLE_TIMEOUT is the seconds each run may take (default 90);
# SAMPLE_BACKEND=vulkan runs the device side on Vulkan instead of WebGPU.
#   file, host g++ (build/run status), host output head, WebGPU (build/run status), WebGPU output head
# Statuses: ok, fail(code), timeout, build-fail, refused(first reason).
set -uo pipefail
dir=$(cd "$1" && pwd); list=$2; out=${3:-$(mktemp -d)}
mkdir -p "$out"
root=$(cd "$(dirname "$0")/../../.." && pwd)
tmo=${SAMPLE_TIMEOUT:-90}
: > "$out/samples.tsv"
inc() { local d=$1; echo -I"$d" -I"$d/.." -I"$d/../.." -I"$d/../include" -I"$d/../../common" -I"$d/../../../common"; }
while read -r rel args; do
  [ -n "$rel" ] || continue
  f=$dir/$rel; d=$(dirname "$f"); n=$(echo "$rel" | tr / _)
  h_status=; h_out=; w_status=; w_out=
  # host path
  if [ "${SKIP_HOST:-0}" = 1 ]; then
    h_status=skipped
  elif "$root/scripts/sycl-build.sh" --cpu $(inc "$d") "$f" -o "$out/$n.host" > "$out/$n.host.log" 2>&1; then
    (cd "$out" && timeout "$tmo" "./$n.host" $args < /dev/null > "$n.host.out" 2>&1); rc=$?
    if [ $rc = 124 ]; then h_status=timeout; elif [ $rc = 0 ]; then h_status=ok; else h_status="fail($rc)"; fi
    h_out=$(head -c 300 "$out/$n.host.out" | tr '\n\t' '  ')
  else
    h_status=build-fail; h_out=$(grep -m1 -E 'error' "$out/$n.host.log" | cut -c1-200 | tr '\t' ' ')
  fi
  # WebGPU path
  rc=0
  "$root/scripts/sycl-build.sh" --backend="${SAMPLE_BACKEND:-webgpu}" --cxx="$root/nfcxx" $(inc "$d") "$f" -o "$out/$n.gpu" > "$out/$n.gpu.log" 2>&1 || rc=$?
  if [ $rc = 0 ]; then
    (cd "$out" && timeout "$tmo" "./$n.gpu" $args < /dev/null > "$n.gpu.out" 2> "$n.gpu.err"); rc=$?
    if [ $rc = 124 ]; then w_status=timeout; elif [ $rc = 0 ]; then w_status=ok; else w_status="fail($rc)"; fi
    w_out=$(head -c 300 "$out/$n.gpu.out" | tr '\n\t' '  ')
    [ "$w_status" = ok ] || w_out="$w_out | $(grep -m1 -v '^$' "$out/$n.gpu.err" | cut -c1-200 | tr '\t' ' ')"
  elif [ $rc = 3 ]; then
    w_status=refused; w_out=$(grep -m1 '^refused' "$out/$n.gpu.log" | cut -c1-220 | tr '\t' ' ')
  else
    w_status=build-fail; w_out=$(grep -v prelinker "$out/$n.gpu.log" | grep -m1 -E 'error' | cut -c1-200 | tr '\t' ' ')
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$h_status" "$h_out" "$w_status" "$w_out" >> "$out/samples.tsv"
  echo "$rel: host=$h_status gpu=$w_status"
done < "$list"
