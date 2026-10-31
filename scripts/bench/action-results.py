"""Scripted action bench for an OCU build, measured the way cua-eval measures (chars/4 + w*h/750 per image).

CUA_EVAL_DIR=<cua-eval checkout> python3 scripts/bench/action-results.py <ocu-binary> <label> [--repeat N] [--extra-env K=V ...]

Targets: a renamed copy of the cua-eval AppKit fixture (bundle sk.ocubench.fixture, so a running eval is not
disturbed) and a Safari window showing scripts/bench/action-results.html. The binary must be signed so the
Locked Use broker accepts it, and run with OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY=1 (set here). Results go
to $OCU_BENCH_OUT (default /tmp/ocu-bench).
"""
import argparse, json, os, statistics, sys
sys.path.insert(0, os.environ["CUA_EVAL_DIR"])
from cuaeval.mcp import MCPClient  # noqa: E402

APP = "sk.ocubench.fixture"

ap = argparse.ArgumentParser()
ap.add_argument("binary"); ap.add_argument("label")
ap.add_argument("--repeat", type=int, default=5)
ap.add_argument("--extra-env", nargs="*", default=[])
ap.add_argument("--state", default=None, help="pass state=<v> to actions (new build only)")
ap.add_argument("--dump", action="store_true")
a = ap.parse_args()

env = {"OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY": "1"}
for kv in a.extra_env:
    k, v = kv.split("=", 1); env[k] = v
c = MCPClient([a.binary, "mcp"], env=env)
tools = c.tools()
schema = json.dumps(tools)
instr = c.server_info.get("instructions") or ""
out = {"label": a.label, "tool_count": len(tools), "schema_chars": len(schema), "instructions_chars": len(instr),
       "tools_list_tokens": (len(schema) + len(instr)) // 4, "calls": {}}

def extra(d):
    if a.state: d = {**d, "state": a.state}
    return d

def find(text, needle):
    for line in text.splitlines():
        s = line.strip().lstrip("~+- ")
        if needle in s:
            return s.split(" ", 1)[0]
    raise SystemExit(f"element not found: {needle}\n{text[:2000]}")

samples = {}
def rec(name, r):
    if not r.ok:
        print("ERROR", name, r.text[:400]); return r
    samples.setdefault(name, []).append(r)
    if a.dump: print(f"--- {name} {r.seconds:.2f}s {r.est_tokens}tok\n{r.text[:1500]}")
    return r

SAFARI = "com.apple.Safari"
for i in range(a.repeat):
    st = rec("get_app_state", c.call("get_app_state", {"app": APP}))
    name_idx = find(st.text, "text field (settable, string) Description: Name")
    box_idx = find(st.text, "checkbox Subscribe")
    rec("set_value", c.call("set_value", extra({"app": APP, "element_index": name_idx, "value": f"Grace Hopper {i}"})))
    rec("click", c.call("click", extra({"app": APP, "element_index": box_idx})))
    rec("press_key", c.call("press_key", extra({"app": APP, "key": "Tab"})))

    st = rec("web:get_app_state", c.call("get_app_state", {"app": SAFARI}))
    todo = find(st.text, "What needs doing")
    toggle = find(st.text, "button Toggle details")
    add = find(st.text, "button Add")
    rec("web:set_value", c.call("set_value", extra({"app": SAFARI, "element_index": todo, "value": f"Buy milk {i}"})))
    rec("web:click", c.call("click", extra({"app": SAFARI, "element_index": add})))
    rec("web:click", c.call("click", extra({"app": SAFARI, "element_index": toggle})))
    rec("web:click", c.call("click", extra({"app": SAFARI, "element_index": toggle})))
c.close()

for name, rs in samples.items():
    out["calls"][name] = {"n": len(rs), "median_s": round(statistics.median(r.seconds for r in rs), 3),
                          "mean_s": round(statistics.mean(r.seconds for r in rs), 3),
                          "median_tokens": int(statistics.median(r.est_tokens for r in rs)),
                          "median_text_chars": int(statistics.median(r.text_chars for r in rs)),
                          "images": statistics.mean(len(r.images) for r in rs)}
print(json.dumps(out, indent=1))
out_dir = os.environ.get("OCU_BENCH_OUT", "/tmp/ocu-bench")
os.makedirs(out_dir, exist_ok=True)
json.dump(out, open(os.path.join(out_dir, f"{a.label}.json"), "w"), indent=1)
