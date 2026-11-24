pre_opts=(); for f in ${preinc[@]+${preinc[@]+"${preinc[@]}"}}; do
  if [ $moves = 1 ] && [ -e "$f" ]; then f=$("${RUBY:-ruby}" "$root/scripts/host-sys.rb" abs_path "$f"); fi
  pre_opts+=(--preinclude "$f")
done
