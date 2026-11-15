mod_is_module_src() {  # mod_is_module_src FILE: true when FILE declares a module or imports one (scripts/nfcxx-modscan.rb is-module)
  "${RUBY:-ruby}" "$root/scripts/nfcxx-modscan.rb" is-module "$1"
}
mod_decl_name() {  # mod_decl_name FILE: the source scans are scripts/nfcxx-modscan.rb (tests/nfcxx-modscan/run.sh checks them)
  "${RUBY:-ruby}" "$root/scripts/nfcxx-modscan.rb" decl-name "$1"
}
mod_imports() {
  "${RUBY:-ruby}" "$root/scripts/nfcxx-modscan.rb" imports "$1"
}
mod_check_src() {  # mod_check_src FILE: refuses the module features that are not built yet (exit 2, nfcxx's message)
  "${RUBY:-ruby}" "$root/scripts/nfcxx-modscan.rb" check "$1" || exit $?
}
