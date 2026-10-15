@group(0) @binding(0) var<storage, read> x: array<f32>;
@group(0) @binding(1) var<storage, read> y: array<f32>;
@group(0) @binding(2) var<storage, read_write> b3: array<f32>;
@group(0) @binding(3) var<storage, read_write> b4: array<f32>;
@group(0) @binding(4) var<storage, read_write> b5: array<f32>;

@compute @workgroup_size(64)
fn k3(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i >= 6u) { return; }
  b3[i] = (x[i] + y[i]);
}

@compute @workgroup_size(64)
fn k4(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i >= 6u) { return; }
  b4[i] = (b3[i] * 2.0);
}

@compute @workgroup_size(64)
fn k5(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i >= 2u) { return; }
  var acc: f32 = b4[(((i / 1u) % 2u) * 3u + 0u * 1u)];
  for (var r1: u32 = 0u; r1 < 3u; r1 = r1 + 1u) {
    if (r1 != 0u) { acc = acc + b4[(((i / 1u) % 2u) * 3u + r1 * 1u)]; }
  }
  b5[i] = acc;
}

