# Frozen driver: builds the bench in release, runs each scenario in P separate processes and
# reports the median of the per-process medians. usage: python3 -I run.py <label> [scenario ...]
# RECORTIA_BENCH_PACKAGE selects another copy of the harness (an A/B against another tree);
# results go to the ignored <repo>/.scratch/perf/results-<label>.json.
import json
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.environ.get("RECORTIA_BENCH_PACKAGE", os.path.join(HERE, "bench"))
OUT = os.path.join(HERE, "..", "..", "..", ".scratch", "perf")
ENV = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
SCEN = {  # scenario: (processes, iterations)
    "render_base_5k": (3, 5), "render_base_5k_masked": (3, 5), "export_png_5k": (3, 5),
    "export_auto_5k": (3, 5), "export_heic_5k": (3, 3), "export_png_photo": (3, 5),
    "decode_png_5k": (3, 5), "canvas_draw_5k": (3, 5), "scan_sensitive_5k": (2, 2),
}
label = sys.argv[1]
chosen = sys.argv[2:] or list(SCEN)
b = subprocess.run(["xcrun", "swift", "build", "-c", "release", "--package-path", BENCH], env=ENV,
                   capture_output=True, text=True)
if b.returncode:
    sys.exit(b.stdout[-3000:] + b.stderr[-3000:])
exe = os.path.join(BENCH, ".build/release/bench")
if not os.path.exists(exe):
    exe = os.path.join(BENCH, ".build/out/Products/Release/bench")
summary = {}
for s in chosen:
    procs, iters = SCEN[s]
    runs = []
    for _ in range(procs):
        r = subprocess.run([exe, s, str(iters)], capture_output=True, text=True, timeout=900)
        if r.returncode:
            sys.exit(f"{s} failed: {r.stderr[-2000:]}")
        runs.append(json.loads(r.stdout.strip().splitlines()[-1]))
    agg = {k: statistics.median(x[k] for x in runs) for k in runs[0] if isinstance(runs[0][k], (int, float))}
    agg["cpu_ms_spread"] = max(x["cpu_ms_median"] for x in runs) - min(x["cpu_ms_median"] for x in runs)
    summary[s] = agg
    print(s, json.dumps({k: round(v, 2) for k, v in agg.items()}), flush=True)
os.makedirs(OUT, exist_ok=True)
out = os.path.normpath(os.path.join(OUT, f"results-{label}.json"))
json.dump(summary, open(out, "w"), indent=1)
print("saved", out)
