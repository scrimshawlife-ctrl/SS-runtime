"""Summarise pacing-search jsonl files: one block per config.

usage: ps-sum.py file.jsonl [...] [--segs] [--md]
"""
import json
import statistics as st
import sys

H = "/private/tmp/claude-501/-Users-luna-Documents-claude/c5a69cd5-d75b-4716-a9cd-7bb13ac15e9e/scratchpad/"
args = [a for a in sys.argv[1:] if not a.startswith("--")]
SEGS = "--segs" in sys.argv
MD = "--md" in sys.argv
rows = []
for p in args:
    rows += [json.loads(l) for l in open(p if p.startswith("/") else H + p) if l.strip()]

SEG_KEYS = [("Z02", "cameraCorridor", 30, 75), ("MA", "civicPlaza", 75, 135), ("MB", "pressureRoute", 135, 195),
            ("El", "lockdownRing", 195, 240), ("Bo", "captainCourt", 240, 360), ("Ex", "extraction", 360, 390)]


def mmss(s):
    if s is None:
        return "—"
    s = int(round(s))
    return "%d:%02d" % (s // 60, s % 60)


def med(v):
    return st.median(v) if v else None


def summarise(rs):
    n = len(rs)
    wins = [r for r in rs if r["outcome"] == "success"]
    secs = [r["ticks"] / 60 for r in wins]
    kills = sum(r["standardKills"] for r in rs)
    amb = sum(r["ambushKills"] for r in rs)
    causes = {}
    for r in rs:
        for k, v in r["alertsByCause"].items():
            causes[k] = causes.get(k, 0) + v
    total = sum(causes.values())
    unaware = sum(r["spawnedUnaware"] for r in rs)
    segs = {}
    for label, key, lo, hi in SEG_KEYS:
        v = [r["segmentStarts"][key] / 60 for r in wins if key in r["segmentStarts"]]
        segs[label] = med(v)
    mc = [r["mobCStartTick"] / 60 for r in wins if r.get("mobCStartTick")]
    return {
        "n": n, "win": len(wins) / n if n else 0, "wins": len(wins),
        "med": med(secs), "in58": (sum(1 for s in secs if 300 <= s <= 480) / len(secs)) if secs else None,
        "amb": amb / kills if kills else None,
        "sight": causes.get("sight", 0) / total if total else 0,
        "sightPerRun": causes.get("sight", 0) / n if n else 0,
        "sightOfUnaware": causes.get("sight", 0) / unaware if unaware else 0,
        "dmg": st.mean(r["damageTaken"] for r in rs) if rs else None,
        "stalls": sum(1 for r in rs if r.get("stalledOn")),
        "invalid": sum(1 for r in rs if r["outcome"] == "invalid"),
        "segs": segs, "mc": med(mc),
    }


def pct(x):
    return "—" if x is None else "%d%%" % round(100 * x)


configs = []
for r in rows:
    if r["config"] not in configs:
        configs.append(r["config"])
if MD:
    print("| config | profile | legal win | legal win med | in 5–8 | sust. win med | sust. in 5–8 | ambush share | sight share (per run) | dmg (legal) | Z02 | M-A | M-B | M-C | Elite | Boss | Extr |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for c in configs:
    for prof in ["competent", "stealth", "loud"]:
        L = [r for r in rows if r["config"] == c and r["profile"] == prof and not r["sustained"]]
        S = [r for r in rows if r["config"] == c and r["profile"] == prof and r["sustained"]]
        if not L and not S:
            continue
        l = summarise(L) if L else None
        s = summarise(S) if S else None
        segsrc = s if s else l
        if MD:
            sg = segsrc["segs"]
            print("| %s | %s | %s (%d/%d) | %s | %s | %s | %s | %s | %s (%.1f) | %.0f | %s | %s | %s | %s | %s | %s | %s |" % (
                c, prof, pct(l["win"]), l["wins"], l["n"], mmss(l["med"]), pct(l["in58"]),
                mmss(s["med"]) if s else "—", pct(s["in58"]) if s else "—", pct(l["amb"]),
                pct(l["sight"]), l["sightPerRun"], l["dmg"],
                mmss(sg["Z02"]), mmss(sg["MA"]), mmss(sg["MB"]), mmss(segsrc["mc"]), mmss(sg["El"]), mmss(sg["Bo"]), mmss(sg["Ex"])))
        else:
            line = "%-34s %-9s L win %4s (%2d/%2d) med %5s in58 %4s | S win %4s med %5s in58 %4s | amb %4s sight %4s (%.1f/run, %s of unaware) dmg %3.0f stall %d/%d inv %d" % (
                c[:34], prof, pct(l["win"]), l["wins"], l["n"], mmss(l["med"]), pct(l["in58"]),
                pct(s["win"]) if s else "—", mmss(s["med"]) if s else "—", pct(s["in58"]) if s else "—",
                pct(l["amb"]), pct(l["sight"]), l["sightPerRun"], pct(l["sightOfUnaware"]), l["dmg"],
                l["stalls"], (s["stalls"] if s else 0), l["invalid"] + (s["invalid"] if s else 0))
            print(line)
            if SEGS:
                sg = segsrc["segs"]
                print("%36s segs(%s wins): Z02 %s MA %s MB %s MC %s El %s Bo %s Ex %s" % (
                    "", "sust" if s else "legal", mmss(sg["Z02"]), mmss(sg["MA"]), mmss(sg["MB"]), mmss(segsrc["mc"]),
                    mmss(sg["El"]), mmss(sg["Bo"]), mmss(sg["Ex"])))
    if not MD:
        print()
