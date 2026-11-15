# The bash originals of nfcxx's link argument loop and of its ecp_arg, verbatim from the bash driver before the port
# (git 62c7501c, nfcxx). Sourced by tests/nfcxx-linkargs/run.sh, which runs them against scripts/nfcxx-linkargs.rb and the
# batched ecp_args of nfcxx. oracle_link_loop reads the globals files, compile_only, moves, root and RUBY, and sets eflist
# and userinc, as the driver's loop did.
ecp_arg() {  # ecp_arg ARG: ARG as eccp receives it (its paths absolute when eccp runs in the temporary directory)
  if [ $moves = 0 ]; then printf '%s\n' "$1"; return 0; fi
  "${RUBY:-ruby}" "$root/scripts/ecp-arg.rb" "$1"   # the port (tests/nfcxx-ecp-arg/run.sh checks it against the bash original)
}
oracle_link_loop() {
eflist=(); userinc=(); no_as_needed=0; as_needed=0
for f in ${files[@]+${files[@]+"${files[@]}"}}; do
  case $f in
    # User -I dirs go before the host's --sys_include dirs: eccp searches them in command-line order, and GCC
    # searches -I before the system directories, so "error.h" from a file outside EDG's src/ must not pick
    # glibc's <error.h> (ifc_modules_templ.c, docs/notes/cxx-driver.md).
    -I?*) userinc+=("$(ecp_arg "$f")") ;;
    # -lcudart from a CUDA_HOME (the toolkit's or a PyPI-wheel directory): the binary records that directory's lib64 as
    # its runpath, so it loads the same libcudart it was linked against (not whichever one the loader finds first).
    -lcudart)
      [ -n "${CUDA_HOME:-}" ] && [ -d "$CUDA_HOME/lib64" ] && eflist+=(--c_to_obj_option "-Wl,-rpath,$CUDA_HOME/lib64")
      # The device-wide CUB algorithms behind lib/cuda/host/cub/cub.cuh (scripts/cuda-cub.rb): an archive, ahead of
      # libcudart, so only a program that calls them links them.
      if [ $compile_only = 0 ]; then
        cub_lib=$("$root/scripts/cuda-cub.rb") || cub_lib=""
        [ -z "$cub_lib" ] || eflist+=("$cub_lib")
      fi
      eflist+=("--c_to_obj_lib=cudart") ;;
    -l?*) eflist+=("--c_to_obj_lib=${f#-l}") ;;
    # --no-as-needed keeps the libraries after it in DT_NEEDED; find_package(Torch) links libtorch_cpu, libtorch_cuda and
    # libtorch as -Wl,--no-as-needed,LIB ... -Wl,--as-needed. eccp puts its --c_to_obj_option items before every
    # input, so the option cannot be kept where it is: one --no-as-needed for the whole link stands for every such
    # span (every library is then kept, which only adds DT_NEEDED entries), and the items given with the option stay
    # inputs in place. The --as-needed that closes a span is dropped then; alone, it applies to the whole link.
    -Wl,--no-as-needed|-Wl,--no-as-needed,*)
      no_as_needed=1
      if [ "$f" != -Wl,--no-as-needed ]; then
        IFS=, read -r -a nan_items <<< "${f#-Wl,--no-as-needed,}"
        for item in ${nan_items[@]+"${nan_items[@]}"}; do
          case $item in
            -l?*) eflist+=("--c_to_obj_lib=${item#-l}") ;;
            -*) eflist+=(--c_to_obj_option "$(ecp_arg "-Wl,$item")") ;;
            *) eflist+=("$(ecp_arg "$item")") ;;
          esac
        done
      fi ;;
    -Wl,--as-needed) as_needed=1 ;;
    # eccp puts its --c_to_obj_option items before every object and archive, so a link option that acts on the
    # arguments after it would act on the wrong ones. Refused rather than moved (docs/notes/cxx-driver.md).
    -Wl,--whole-archive|-Wl,--whole-archive,*|-Wl,--no-whole-archive|-Wl,--no-whole-archive,*|\
-Wl,--start-group|-Wl,--start-group,*|-Wl,--end-group|-Wl,--end-group,*|-Wl,--as-needed,*|\
-Wl,-Bstatic|-Wl,-Bstatic,*|-Wl,-Bdynamic|-Wl,-Bdynamic,*)
      echo "nfcxx: $f: an order-dependent link option cannot be kept with C++ inputs (docs/notes/cxx-driver.md)" >&2
      exit 2 ;;
    -Wl,*) eflist+=(--c_to_obj_option "$(ecp_arg "$f")") ;;   # -Wl,-rpath,DIR, -Wl,-E, ...: the host link (eccp's C compile options)
    *) eflist+=("$(ecp_arg "$f")") ;;
  esac
done
if [ $no_as_needed = 1 ]; then eflist+=(--c_to_obj_option -Wl,--no-as-needed)
elif [ $as_needed = 1 ]; then eflist+=(--c_to_obj_option -Wl,--as-needed); fi
}
