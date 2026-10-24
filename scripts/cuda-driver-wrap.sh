# Sourced by nfcxx and nfcc: how a link that names the CUDA driver library is done (docs/notes/cuda-driver.md).
# libcuda is named by -lcuda, -l:libcuda.so[.1], or a path ending in libcuda.so[.1] (what CMake passes for
# CUDA::cuda_driver: $CUDA_HOME/lib64/stubs/libcuda.so or the system's libcuda.so; libtorch's caffe2::cuda and
# llama.cpp's ggml-cuda link it).
#   --cuda-driver=auto     the default: the driver API goes through libcudart (the shim of scripts/cuda-driver-shim
#                          and libcudart in place of libcuda), so the program needs no libcuda.so.1 to link or start and
#                          cudart loads the driver when it is first used; falls back to linking libcuda, with a note,
#                          when the shim cannot be made (no cuda.h and cudaTypedefs.h, libcudart before 12.5, not x86-64)
#   --cuda-driver=cudart   the same, and an error when the shim cannot be made
#   --cuda-driver=libcuda  libcuda is linked as named
#   NFCXX_CUDA_DRIVER=auto|cudart|libcuda  the same for every command (a CMake or make build)
# The toolkit (headers for the shim, lib64 for libcudart) is $CUDA_HOME, else the one the libcuda path is in
# (<root>/lib64/stubs/libcuda.so, <root>/targets/<arch>/lib/stubs/libcuda.so), else /usr/local/cuda. When the link
# already has the static runtime (libcudart_static, CMake's default for CUDA targets) the shim binds to that one;
# otherwise -lcudart is added, with the toolkit's lib64 as a run path.
# cuda_driver_wrap DRIVER ARGS...: when libcuda is to be replaced, DRIVER runs again on ARGS with it replaced, then this
# exits; otherwise it returns and the caller goes on with cuda_driver_args (ARGS without --cuda-driver=*).
cuda_driver_wrap() {
  local driver=$1; shift
  local mode=${NFCXX_CUDA_DRIVER:-auto} a found="" args=() home="" shim rtv static="" why=""
  cuda_driver_args=()
  for a in "$@"; do
    case $a in
      --cuda-driver=*) mode=${a#*=} ;;
      -lcuda|-l:libcuda.so|-l:libcuda.so.1|*/libcuda.so|*/libcuda.so.1) found=$a; cuda_driver_args+=("$a") ;;
      -lcudart_static|*/libcudart_static.a) static=$a; cuda_driver_args+=("$a") ;;
      *) cuda_driver_args+=("$a") ;;
    esac
  done
  case $mode in
    auto|cudart|libcuda) ;;
    *) echo "$(basename "$driver"): --cuda-driver=$mode: auto, cudart or libcuda" >&2; exit 2 ;;
  esac
  [ -n "$found" ] && [ $mode != libcuda ] || return 0
  if [ -n "${CUDA_HOME:-}" ]; then home=$CUDA_HOME
  else
    case $found in
      */lib64/stubs/libcuda.so*|*/lib64/libcuda.so*) home=${found%/lib64/*} ;;
      */targets/*/lib/stubs/libcuda.so*) home=${found%/lib/stubs/*} ;;
    esac
    [ -n "$home" ] && [ -f "$home/include/cuda.h" ] || home=/usr/local/cuda
  fi
  rtv=$(sed -nE 's/^#define[ \t]+CUDART_VERSION[ \t]+([0-9]+).*/\1/p' "$home/include/cuda_runtime_api.h" 2>/dev/null | head -1)
  if [ "$(uname -m)" != x86_64 ]; then why="the shim is x86-64 only"
  elif [ ! -f "$home/include/cuda.h" ] || [ ! -f "$home/include/cudaTypedefs.h" ]; then why="no cuda.h and cudaTypedefs.h in $home/include"
  elif [ -z "$rtv" ] || [ "$rtv" -lt 12050 ]; then why="libcudart ${rtv:-of unknown version} is older than 12.5"
  elif ! shim=$("$root/scripts/cuda-driver-shim" "$home/include" 2>&1); then why="the shim did not build: $shim"
  fi
  if [ -n "$why" ]; then
    if [ $mode = cudart ]; then echo "$(basename "$driver"): --cuda-driver=cudart: $why" >&2; exit 1; fi
    echo "$(basename "$driver"): note: linking the CUDA driver library $found as named ($why; docs/notes/cuda-driver.md)" >&2
    return 0
  fi
  local done_=0
  for a in ${cuda_driver_args[@]+"${cuda_driver_args[@]}"}; do
    case $a in
      -lcuda|-l:libcuda.so|-l:libcuda.so.1|*/libcuda.so|*/libcuda.so.1)  # every mention goes; the first becomes the shim
        [ $done_ = 0 ] || continue
        done_=1
        args+=("$shim")
        if [ -n "$static" ]; then args+=("$static")
        else
          # The run path too, as nfcxx gives -lcudart from a CUDA_HOME: libcuda came by absolute path or from the system,
          # libcudart has to be found where the toolkit is.
          [ ! -d "$home/lib64" ] || args+=("-L$home/lib64" "-Wl,-rpath,$home/lib64")
          args+=(-lcudart)
        fi ;;
      *) args+=("$a") ;;
    esac
  done
  NFCXX_CUDA_DRIVER=libcuda exec "$driver" ${args[@]+"${args[@]}"}
}
