# Interleaved A/B: builds two copies of the harness (each bound to its own RecortiaKit tree), then
# alternates base and head processes within every scenario so a load change hits both sides alike.
# usage: python3 -I ab.py <base-package> <head-package> <label> [scenario ...]
# Reports the median of the per-process medians; results go to <repo>/.scratch/perf/ab-<label>.json.
import json
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".scratch", "perf"))
ENV = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
SCEN = {  # scenario: (processes per side, iterations)
    "render_base_5k": (3, 5), "render_base_5k_masked": (3, 5), "export_png_5k": (3, 5),
    "export_auto_5k": (3, 5), "export_heic_5k": (3, 3), "export_png_photo": (3, 5),
    "decode_png_5k": (3, 5), "canvas_draw_5k": (3, 5), "scan_sensitive_5k": (2, 2),
}
base_pkg, head_pkg, label = sys.argv[1:4]
chosen = sys.argv[4:] or list(SCEN)


def build(package):
    b = subprocess.run(["xcrun", "swift", "build", "-c", "release", "--package-path", package], env=ENV,
                       capture_output=True, text=True)
    if b.returncode:
        sys.exit(b.stdout[-3000:] + b.stderr[-3000:])
    for rel in (".build/release/bench", ".build/out/Products/Release/bench"):
        if os.path.exists(os.path.join(package, rel)):
            return os.path.join(package, rel)
    sys.exit(f"no bench executable under {package}")


exe = {"base": build(base_pkg), "head": build(head_pkg)}
summary = {}
for s in chosen:
    procs, iters = SCEN[s]
    runs = {"base": [], "head": []}
    for _ in range(procs):
        for side in ("base", "head"):
            r = subprocess.run([exe[side], s, str(iters)], capture_output=True, text=True, timeout=900)
            if r.returncode:
                sys.exit(f"{side} {s} failed: {r.stderr[-2000:]}")
            runs[side].append(json.loads(r.stdout.strip().splitlines()[-1]))
    summary[s] = {}
    for side, xs in runs.items():
        agg = {k: statistics.median(x[k] for x in xs) for k in xs[0] if isinstance(xs[0][k], (int, float))}
        agg["cpu_ms_spread"] = max(x["cpu_ms_median"] for x in xs) - min(x["cpu_ms_median"] for x in xs)
        summary[s][side] = agg
    b, h = summary[s]["base"], summary[s]["head"]
    line = {"cpu_base": round(b["cpu_ms_median"], 2), "cpu_head": round(h["cpu_ms_median"], 2),
            "cpu_delta_pct": round(100 * (h["cpu_ms_median"] / b["cpu_ms_median"] - 1), 1),
            "spread_base": round(b["cpu_ms_spread"], 2), "spread_head": round(h["cpu_ms_spread"], 2),
            "peak_base": round(b["peak_footprint_mb"], 1), "peak_head": round(h["peak_footprint_mb"], 1)}
    if "bytes" in b:
        line.update(bytes_base=int(b["bytes"]), bytes_head=int(h["bytes"]),
                    bytes_delta_pct=round(100 * (h["bytes"] / b["bytes"] - 1), 1))
    print(s, json.dumps(line), flush=True)
os.makedirs(OUT, exist_ok=True)
out = os.path.join(OUT, f"ab-{label}.json")
json.dump(summary, open(out, "w"), indent=1)
print("saved", out)
