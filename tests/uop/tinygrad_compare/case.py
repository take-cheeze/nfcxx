# Writes tinygrad's kernels (from gen.py's report.json) as WebGPU cases for run_tinygrad.html. The expected values are
# our interpreter's (scratch case files from tests/uop/test_wgsl.cpp, passed as argv[2] and argv[3]), so the runner
# checks tinygrad's kernels against the same reference. Usage: case.py OUT_DIR REPORT_JSON OUR_REDUCE_JS OUR_ELEM_JS
import json, re, sys
out, report = sys.argv[1], json.load(open(sys.argv[2]))
ours = {"reduce": sys.argv[3], "elementwise": sys.argv[4]}
for name, v in report.items():
  js = open(ours[name]).read()
  expected = re.search(r"expected: \[([^\]]*)\]", js).group(1)
  kernels = []
  for k in v["kernels"]:
    # Binding i+1 is the kernel's buffer dataI_ (the call argument I); binding 0 is the INFINITY uniform.
    names = {int(m.group(1)): None for m in re.finditer(r"data(\d+)_\d+", k["src"])}
    # Only the bindings the entry point uses: with layout 'auto' an unused binding is not in the layout.
    body = k["src"].split("fn " + k["entry"] + "(", 1)[1]
    binds = ([{"binding": 0, "uniform": True}] if "INFINITY" in body else []) + \
            [{"binding": i + 1, "buf": k["binds"][i]} for i in sorted(names) if f"data{i}_" in body]
    kernels.append({"source": k["src"], "entry": k["entry"], "dispatch": k["dispatch"], "binds": binds})
  case = {"kernels": kernels, "buffers": v["bufs"], "output": v["output"], "inputs": v["inputs"], "expected": expected}
  open(f"{out}/tg_case_{name}.js", "w").write("window.TG_CASE = " + json.dumps(case) + ";\n")
  print(name, "kernels", len(kernels), "expected", expected)
