# The bash mod_is_module_src as nfcxx had it before scripts/nfcxx-modscan.rb is-module (copied verbatim from nfcxx at 62c7501c).
# tests/nfcxx-modscan/run.sh compares the port with this function: the same status (grep's 0, 1 or 2) for each source.
mod_is_module_src() {  # mod_is_module_src FILE: true when FILE declares a module or imports one
  grep -Eq '^[[:space:]]*(export[[:space:]]+)?(module|import)[[:space:]]+[A-Za-z_<"]' "$1"
}
