# Usage: awk -f abi_sig.awk FILE.ptx. Used by run_struct_abi.sh.
# The ABI-visible part of a PTX module: each .func/.entry header and its parameter list, one line per parameter. A scalar
# return convention is dropped (only aggregate results are compared), and a scalar parameter is compared by its size.
function norm(l,    t) {
  for (t = 8; t <= 64; t *= 2) {
    gsub("\\.s" t " ", ".b" t " ", l); gsub("\\.u" t " ", ".b" t " ", l); gsub("\\.f" t " ", ".b" t " ", l)
    gsub("\\.s" t ",", ".b" t ",", l); gsub("\\.u" t ",", ".b" t ",", l)
  }
  return l
}
/^\.(func|visible \.entry)/ { inhdr = 1; l = $0; gsub(/[ \t]+/, " ", l)
  if (l !~ /func_retval0\[/) sub(/\(\.(reg|param) \.[bfsu][0-9]+ (%rv|func_retval0)\) /, "", l)
  print norm(l); next }
inhdr && /^\)/ { inhdr = 0; print ")"; next }
inhdr { l = $0; gsub(/^[ \t]+|,$/, "", l); gsub(/[ \t]+/, " ", l); print "  " norm(l) }
