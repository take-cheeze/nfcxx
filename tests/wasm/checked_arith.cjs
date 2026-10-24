// The checks of checked_arith.ir (checked arithmetic, cadd csub cmul cneg: the front end writes them under
// NFCXX_IR_OVERFLOW=trap, and llvm-to-pathb.rb for nsw): node checked_arith.cjs MODULE.wasm. Each case is [function, arguments, result or
// "trap"], at the edges of the type. Prints "ok N" or the failing cases, and exits 1 on a failure.
// The module's imports (the --asan report) are stubs: no case reaches them.
const stubs = new Proxy({}, { get: () => new Proxy({}, { get: () => () => 0 }) });
const x = new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[2])), stubs).exports;
const M=2147483647, m=-2147483648, L=(1n<<63n)-1n, l=-(1n<<63n);
const cases=[["add32",[M,0],M],["add32",[M,1],"trap"],["add32",[m,-1],"trap"],["add32",[-5,3],-2],
["sub32",[m,1],"trap"],["sub32",[m,-1],m+1],["mul32",[65536,32768],"trap"],["mul32",[-65536,32768],m],["mul32",[-3,7],-21],
["neg32",[m],"trap"],["neg32",[5],-5],["addu",[-1,0],-1],["addu",[-1,1],"trap"],
["add64",[L,0n],L],["add64",[L,1n],"trap"],["add64",[l,-1n],"trap"],["add64",[-5n,3n],-2n],
["sub64",[l,1n],"trap"],["sub64",[0n,l],"trap"],["sub64",[-1n,l],L],["mul64",[l,-1n],"trap"],["mul64",[-1n,l],"trap"],["mul64",[1n<<32n,1n<<31n],"trap"],["mul64",[-(1n<<32n),1n<<31n],l],["mul64",[0n,l],0n],["mul64",[-7n,6n],-42n],
["neg64",[l],"trap"],["neg64",[7n],-7n],["addul",[-1n,0n],-1n],["addul",[-1n,1n],"trap"],["subul",[0n,1n],"trap"],["subul",[5n,3n],2n],
["mulul",[1n<<32n,1n<<32n],"trap"],["mulul",[3n,5n],15n],["sc",[100,27],127],["sc",[100,28],"trap"],["sc",[-100,-28],-128]];
let bad = 0;
for (const [f, a, e] of cases) {
  let r;
  try { r = x[f](...a); } catch (err) { r = "trap"; }
  if (String(r) !== String(e)) { bad++; console.log("FAIL", f, a, r, e); }
}
console.log(bad ? `${bad} failed` : `ok ${cases.length}`);
process.exit(bad ? 1 : 0);
console.log(bad?"failures "+bad:"all "+cases.length+" ok");
