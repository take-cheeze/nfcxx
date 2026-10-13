# SYCL on Vulkan (SPIR-V)

Status: **working** for the SYCL subset of `docs/notes/sycl-webgpu.md`, checked on lavapipe (Mesa's CPU Vulkan driver) with
`tests/sycl/run.sh`: the same 14 programs as the WebGPU path, plus `double` (which WebGPU refuses), with the trap and
the refusals behaving the same. Not yet run on a real GPU; the Intel Arc B60 is the next target (see "Next").

```
scripts/sycl-build.sh --backend=vulkan prog.cpp -o prog   # the device pass -> SPIR-V (checked by spirv-val), host side with nfcxx
./prog                                                    # loads prog.spv / prog.man next to it
```

Needs `spirv-tools` (spirv-val) at build time and the Vulkan loader at run time. `tests/sycl/run.sh` runs both backends and
skips the Vulkan part without a device.

## Why SPIR-V is simpler than the WGSL path

The WebGPU path (`docs/notes/sycl-webgpu.md`) fits pointers, closures and work-group memory into WGSL's restrictions: 32-bit
addresses in one storage buffer, a uniform buffer for the closure, a shadow memory per address space, and a uniformity analysis
that rejects some barriers. Vulkan's compute model has none of those limits:

| | WGSL (WebGPU) | SPIR-V (Vulkan) |
| --- | --- | --- |
| pointers | `u32` offsets in address-space shadows | 64-bit physical addresses (`PhysicalStorageBuffer64`) |
| closure | uniform buffer (4 KB) | a region of the heap, address in a push constant |
| 64-bit integers, `double` | refused | `Int64`, `Float64` |
| barriers | must be provably uniform | no such rule |
| per-invocation stack | a `private` array in the shader | a slice of a stack region in the heap |

The emitter keeps the same structure as `scripts/pathb-wgsl-emit.rb`: the same kernel discovery (`__nfcxx_sycl_entry_*`), the
same reachable-function walk, the same static-object handling (which is shared code, copied), the same checks and intrinsics.

## The module

One SPIR-V module per program (`scripts/pathb-spirv-emit.rb`), SPIR-V 1.5, Vulkan memory model with device-scope atomics:

- an entry point `k<N>` per kernel. The entry is a small wrapper: it points this invocation's stack at its slot in the
  stack region (by its index in the dispatched grid), clears the dead flag, and calls the kernel's IR function;
- the local size is a `WorkgroupSize` built-in on a composite of three specialization constants (Vulkan does not accept
  `LocalSizeId`), set per pipeline;
- the built-ins `GlobalInvocationId`, `LocalInvocationId` and `WorkgroupId` are `Input` variables;
- the push constant block (`PUSH_MEMBERS`, 80 bytes) carries: the closure address, the statics address, the stack and
  work-group region addresses, the flag address, the SYCL global range, the number of work-groups, the stack bytes per
  invocation, the local stride, and the bytes of `local_accessor` storage.

Memory. An IR pointer is a `u64`. Each load or store is an `OpLoad`/`OpStore` through an `OpConvertUToPtr` pointer of the
`PhysicalStorageBuffer` class with the alignment the IR gives. Bytes and halfwords are read and written as aligned 32-bit words
(a store is an atomic AND and an atomic OR on the word). A scalar slot whose address is never taken is a `Function` variable;
every other slot is in the invocation's frame, which lives in the stack region: `sp` is a `Private` variable, a function
saves it and sets it to its frame on entry, and restores it on each return.

Dead invocations. A failed check (division by zero, a shift count out of range, an index out of bounds, a null pointer, a
trap, a float-to-integer overflow) does an atomic max of its code into the flag word, sets the `dead` variable, and returns
from the current function with zero results. Every call site returns in turn while `dead` is set, so a failed invocation
never touches memory again. Loops are arranged so this is legal SPIR-V: the loop's step runs at the top of each iteration
(the first iteration skips it), so the continue construct is an empty block and no return sits inside it.

## The runtime

`lib/sycl/include/sycl/rt_vulkan.hpp`: one compute queue, one host-visible coherent heap of 512 MB with
`VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT` (the buffer device address is in Vulkan 1.2 core), mapped once.

- The heap holds the flag (offset 0), the closure (offset 256, up to 4 KB), the static objects, the SYCL buffers and the USM
  allocations, and each dispatch's stacks and work-group memory (freed after the dispatch).
- Each dispatch is submitted and waited for before the next. The queue is in order by construction, which is what SYCL
  promises; the cost is one fence per launch.
- After each dispatch the flag is read; a non-zero flag exits with status 71 and the reason, as on WebGPU.
- The device address and the mapping's address are compared once at start-up. On lavapipe they are the same number, so a
  USM pointer is the same on the host and in a kernel, and kernels may capture it (the `usm` test does). Where they differ,
  USM allocation throws `feature_not_supported`; SYCL buffers and accessors work everywhere (they need only device addresses).
- Limits are checked against the device's properties before a launch, with the message naming the limit.

## Tests

`tests/sycl/run.sh` runs each program on both backends. On Vulkan: `vecadd`, `saxpy2d`, `reduce`, `bytes`, `chain`,
`matmul`, `usm`, `tables`, `libm`, `groups`, `barvar`, `atomics`, `redcustom`, `double`, and `trap_div` (exit 71). The
WGSL-only refusal (`refuse_double`) is a WebGPU check; Vulkan accepts `double`.

Checked by mutation: changing the `OpFAdd` of `vecadd` to `OpFSub` in the emitted module fails the program (`vecadd FAIL
1000`), so the results come from the module.

Bugs the tests found and their fixes, for the next person: `crem` emitted the quotient (`OpUDiv`) instead of the remainder;
narrow unsigned loads were sign-extended (the canonical form of a narrow integer must follow the signedness of its type);
a loop's merge block was used as a selection merge, and a continue construct that returned, or branched out of a selection,
both failed `spirv-val`. The loop step restructuring above is the fix for the last one.

## Next

- **Intel Arc B60.** The same module should run on ANV (Intel's Vulkan driver): it needs `bufferDeviceAddress`, `shaderInt64`,
  `shaderFloat64` and the Vulkan memory model, which Arc supports. On a real GPU the device address will not equal the mapping
  address, so USM is refused there and the buffer/accessor tests are the ones that apply. To check: `tests/sycl/run.sh` on the
  B60 box with the Vulkan loader and ANV installed. Expect `double` to be slow (FP64 is emulated on some Arc parts).
- **Level Zero / OpenCL** for Intel XPU: a Kernel-capability variant of the same module (physical addresses are the same
  idea; the memory model and the built-ins differ). Not started.
- USM on drivers without identity addressing: device pointers would have to be translated when the closure is copied, which
  needs the closure's pointer fields listed in the manifest. Not started.
- Work-group sizes above 256 are fine here (lavapipe allows 1024); the WebGPU path keeps its 256 limit.
