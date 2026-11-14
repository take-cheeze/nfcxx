mkdir -p 3rd/mruby-onig-regexp 3rd/mruby-json build/mruby-tool/src/.git
: > 3rd/mruby-onig-regexp/mrbgem.rake; : > 3rd/mruby-json/mrbgem.rake
cat > "$SB/stubs/ninja" <<'S'
mkdir -p "$2/host/bin" && echo bin > "$2/host/bin/mruby"
S
