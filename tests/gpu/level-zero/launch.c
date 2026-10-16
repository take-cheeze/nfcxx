/* Loads a SPIR-V kernel (argv[1]) with Level Zero on the first Intel GPU (else the first GPU of any vendor) and runs it as
 * vecAdd (argv[2]): the kernel takes (float *A, float *B, float *C, int vectorLength). The arrays are shared USM
 * (zeMemAllocShared), the group size is set with zeKernelSetGroupSize, and the launch covers the rounded-up range in groups
 * of 128 on an immediate command list. Checks every element of C against A + B and that the 64 floats past C are untouched.
 * Exit 0 when all match, 1 on a wrong result, 2 when the runtime or the device is missing or a call fails. */
#include <level_zero/ze_api.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N 50000
#define GUARD 64
#define LOCAL 128

static void check(ze_result_t r, const char *what) {
  if (r != ZE_RESULT_SUCCESS) {
    fprintf(stderr, "%s: Level Zero error 0x%x\n", what, (unsigned)r);
    exit(2);
  }
}

static unsigned char *read_file(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(2); }
  fseek(f, 0, SEEK_END);
  *len = (size_t)ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *buf = malloc(*len);
  if (fread(buf, 1, *len, f) != *len) { fprintf(stderr, "short read\n"); exit(2); }
  fclose(f);
  return buf;
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: launch FILE.spv KERNEL\n"); return 2; }
  size_t il_len;
  unsigned char *il = read_file(argv[1], &il_len);

  check(zeInit(0), "zeInit");
  uint32_t ndrv = 0;
  check(zeDriverGet(&ndrv, NULL), "zeDriverGet");
  ze_driver_handle_t drv[8];
  if (ndrv > 8) ndrv = 8;
  check(zeDriverGet(&ndrv, drv), "zeDriverGet");

  /* the first GPU of an Intel vendor, else the first GPU */
  ze_device_handle_t dev = NULL, any = NULL;
  ze_driver_handle_t dev_drv = NULL, any_drv = NULL;
  for (uint32_t i = 0; i < ndrv && !dev; i++) {
    uint32_t nd = 0;
    if (zeDeviceGet(drv[i], &nd, NULL) != ZE_RESULT_SUCCESS || nd == 0) continue;
    ze_device_handle_t ds[16];
    if (nd > 16) nd = 16;
    zeDeviceGet(drv[i], &nd, ds);
    for (uint32_t j = 0; j < nd && !dev; j++) {
      ze_device_properties_t p = {.stype = ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES};
      zeDeviceGetProperties(ds[j], &p);
      if (p.type != ZE_DEVICE_TYPE_GPU) continue;
      if (!any) { any = ds[j]; any_drv = drv[i]; }
      if (p.vendorId == 0x8086) { dev = ds[j]; dev_drv = drv[i]; }
    }
  }
  if (!dev) { dev = any; dev_drv = any_drv; }
  if (!dev) { fprintf(stderr, "no Level Zero GPU device\n"); return 2; }
  ze_device_properties_t props = {.stype = ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES};
  check(zeDeviceGetProperties(dev, &props), "zeDeviceGetProperties");
  printf("device: %s\n", props.name);

  /* shared USM with atomics: the heap of the runtime needs it, check it here too */
  ze_device_memory_access_properties_t mem = {.stype = ZE_STRUCTURE_TYPE_DEVICE_MEMORY_ACCESS_PROPERTIES};
  check(zeDeviceGetMemoryAccessProperties(dev, &mem), "zeDeviceGetMemoryAccessProperties");
  const ze_memory_access_cap_flags_t need = ZE_MEMORY_ACCESS_CAP_FLAG_RW | ZE_MEMORY_ACCESS_CAP_FLAG_ATOMIC;
  if ((mem.sharedSingleDeviceAllocCapabilities & need) != need) {
    fprintf(stderr, "%s has no shared USM with atomic access\n", props.name);
    return 2;
  }

  ze_context_desc_t cdesc = {.stype = ZE_STRUCTURE_TYPE_CONTEXT_DESC};
  ze_context_handle_t ctx = NULL;
  check(zeContextCreate(dev_drv, &cdesc, &ctx), "zeContextCreate");

  /* the compute queue group */
  uint32_t ngroups = 0;
  check(zeDeviceGetCommandQueueGroupProperties(dev, &ngroups, NULL), "zeDeviceGetCommandQueueGroupProperties");
  ze_command_queue_group_properties_t *groups = calloc(ngroups, sizeof *groups);
  for (uint32_t i = 0; i < ngroups; i++) groups[i].stype = ZE_STRUCTURE_TYPE_COMMAND_QUEUE_GROUP_PROPERTIES;
  check(zeDeviceGetCommandQueueGroupProperties(dev, &ngroups, groups), "zeDeviceGetCommandQueueGroupProperties");
  uint32_t ordinal = ngroups;
  for (uint32_t i = 0; i < ngroups && ordinal == ngroups; i++)
    if (groups[i].flags & ZE_COMMAND_QUEUE_GROUP_PROPERTY_FLAG_COMPUTE) ordinal = i;
  if (ordinal == ngroups) { fprintf(stderr, "no compute queue group\n"); return 2; }
  free(groups);

  ze_command_queue_desc_t qdesc = {.stype = ZE_STRUCTURE_TYPE_COMMAND_QUEUE_DESC, .ordinal = ordinal, .index = 0,
                                   .flags = 0, .mode = ZE_COMMAND_QUEUE_MODE_SYNCHRONOUS,
                                   .priority = ZE_COMMAND_QUEUE_PRIORITY_NORMAL};
  ze_command_list_handle_t cl = NULL;
  check(zeCommandListCreateImmediate(ctx, dev, &qdesc, &cl), "zeCommandListCreateImmediate");

  ze_module_desc_t mdesc = {.stype = ZE_STRUCTURE_TYPE_MODULE_DESC, .format = ZE_MODULE_FORMAT_IL_SPIRV,
                            .inputSize = il_len, .pInputModule = il, .pBuildFlags = "", .pConstants = NULL};
  ze_module_handle_t mod = NULL;
  ze_module_build_log_handle_t blog = NULL;
  ze_result_t r = zeModuleCreate(ctx, dev, &mdesc, &mod, &blog);
  if (r != ZE_RESULT_SUCCESS) {
    size_t logn = 0;
    if (blog) {
      zeModuleBuildLogGetString(blog, &logn, NULL);
      char *log = malloc(logn + 1);
      zeModuleBuildLogGetString(blog, &logn, log);
      fprintf(stderr, "module build failed (0x%x):\n%s\n", (unsigned)r, log);
      free(log);
    } else {
      fprintf(stderr, "zeModuleCreate failed (0x%x)\n", (unsigned)r);
    }
    return 2;
  }
  ze_kernel_desc_t kdesc = {.stype = ZE_STRUCTURE_TYPE_KERNEL_DESC, .pKernelName = argv[2]};
  ze_kernel_handle_t k = NULL;
  check(zeKernelCreate(mod, &kdesc, &k), "zeKernelCreate");
  check(zeKernelSetGroupSize(k, LOCAL, 1, 1), "zeKernelSetGroupSize");

  ze_device_mem_alloc_desc_t dmem = {.stype = ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC};
  ze_host_mem_alloc_desc_t hmem = {.stype = ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC};
  float *a = NULL, *b = NULL, *c = NULL;
  check(zeMemAllocShared(ctx, &dmem, &hmem, N * sizeof(float), 64, dev, (void **)&a), "zeMemAllocShared a");
  check(zeMemAllocShared(ctx, &dmem, &hmem, N * sizeof(float), 64, dev, (void **)&b), "zeMemAllocShared b");
  check(zeMemAllocShared(ctx, &dmem, &hmem, (N + GUARD) * sizeof(float), 64, dev, (void **)&c), "zeMemAllocShared c");
  for (int i = 0; i < N; i++) { a[i] = (float)i; b[i] = 2.0f * (float)i; }
  for (int i = 0; i < N + GUARD; i++) c[i] = -1.0f;

  int n = N;
  check(zeKernelSetArgumentValue(k, 0, sizeof a, &a), "arg 0");
  check(zeKernelSetArgumentValue(k, 1, sizeof b, &b), "arg 1");
  check(zeKernelSetArgumentValue(k, 2, sizeof c, &c), "arg 2");
  check(zeKernelSetArgumentValue(k, 3, sizeof n, &n), "arg 3");

  ze_group_count_t gc = {.groupCountX = (N + LOCAL - 1) / LOCAL, .groupCountY = 1, .groupCountZ = 1};
  check(zeCommandListAppendLaunchKernel(cl, k, &gc, NULL, 0, NULL), "zeCommandListAppendLaunchKernel");
  check(zeCommandListAppendBarrier(cl, NULL, 0, NULL), "zeCommandListAppendBarrier");
  check(zeCommandListHostSynchronize(cl, UINT64_MAX), "zeCommandListHostSynchronize");

  long bad = 0, guard = 0;
  for (int i = 0; i < N; i++)
    if (c[i] != a[i] + b[i]) bad++;
  for (int i = N; i < N + GUARD; i++)
    if (c[i] != -1.0f) guard++;
  printf("mismatches: %ld of %d, guard writes: %ld of %d\n", bad, N, guard, GUARD);

  zeMemFree(ctx, a);
  zeMemFree(ctx, b);
  zeMemFree(ctx, c);
  zeKernelDestroy(k);
  zeModuleDestroy(mod);
  zeCommandListDestroy(cl);
  zeContextDestroy(ctx);
  free(il);
  return bad != 0 || guard != 0;
}
