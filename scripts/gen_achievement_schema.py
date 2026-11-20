#!/usr/bin/env python3
"""Build a Steam achievement schema (.bin) from the client's cached schema.

Steam writes UserGameStatsSchema_<appid>.bin only for apps whose stats exchange
succeeded. For an unowned app that never happens, so the library never shows an
achievement list. The client *does* cache a complete schema as gzipped JSON at

    userdata/<account>/querycache/achievements/achievements_<appid>_schema-*.cmsg

and each entry's internal_key is  stat*256 + bit, so the binary schema can be
reconstructed exactly. Verified by round-tripping a real .bin byte for byte.
"""
import gzip, json, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bkv

STEAM = os.path.expanduser("~/Library/Application Support/Steam")
QC    = os.path.join(STEAM, "userdata", "1530268740", "querycache", "achievements")
STATS = os.path.join(STEAM, "appcache", "stats")

def sec(name):  n = bkv.N(bkv.SEC, name.encode()); return n
def st(name, v):n = bkv.N(bkv.STR, name.encode(), v.encode()); return n
def it(name, v):n = bkv.N(bkv.INT, name.encode(), int(v)); return n

def qc_schema(app):
    pre = "achievements_%d_schema-" % app
    for n in os.listdir(QC):
        if n.startswith(pre):
            return json.loads(gzip.open(os.path.join(QC, n), "rb").read())["data"]
    return None

def build_schema(app, gamename=""):
    d = qc_schema(app)
    if not d:
        return None
    by_stat = {}
    for g in d["groups"]:
        for a in g["achievements"]:
            k = a["internal_key"]
            by_stat.setdefault(k >> 8, []).append((k & 0xFF, a))

    root = sec(str(app))
    stats = sec("stats")
    root.kids.append(stats)

    for stat in sorted(by_stat):
        s = sec(str(stat)); stats.kids.append(s)
        s.kids.append(st("type", "ACHIEVEMENTS"))   # marks it as an achievement stat
        bits = sec("bits"); s.kids.append(bits)
        for bit, a in sorted(by_stat[stat], key=lambda x: x[0]):
            b = sec(str(bit)); bits.kids.append(b)
            b.kids.append(st("name", a.get("api_name") or ""))

            disp = sec("display"); b.kids.append(disp)
            nm = sec("name");  nm.kids.append(st("english", a.get("name") or ""));  disp.kids.append(nm)
            de = sec("desc");  de.kids.append(st("english", a.get("description") or "")); disp.kids.append(de)
            icon = (a.get("icon_unachieved") or "").rstrip("/").split("/")[-1]
            if icon: disp.kids.append(st("icon", icon))
            if a.get("hidden"): disp.kids.append(it("hidden", 1))

            pr = sec("progress"); b.kids.append(pr)
            pr.kids.append(it("min_val", a.get("min_progress") or 0))
            pr.kids.append(it("max_val", a.get("max_progress") or 0))
            val = sec("value"); pr.kids.append(val)
            val.kids.append(st("operation", "statvalue"))
            val.kids.append(st("operand1", a.get("api_name") or ""))

    root.kids.append(it("version", d.get("schema_version") or 0))
    root.kids.append(st("gamename", gamename))
    return root

def build_stats(app, account):
    d = qc_schema(app)
    if not d: return None
    by = {}
    for g in d["groups"]:
        for a in g["achievements"]:
            by.setdefault(a["internal_key"] >> 8, []).append(a["internal_key"] & 0xFF)
    root = sec("cache")
    root.kids.append(it("crc", 0))
    root.kids.append(it("PendingChanges", 0))
    for stat in sorted(by):
        s = sec(str(stat)); root.kids.append(s)
        s.kids.append(it("data", 0))
        t = sec("AchievementTimes"); s.kids.append(t)
        for bit in sorted(by[stat]):
            t.kids.append(it(str(bit), 0))
    return root

def main():
    app = int(sys.argv[1])
    gamename = sys.argv[2] if len(sys.argv) > 2 else ""
    s = build_schema(app, gamename)
    if s is None:
        print("no cached schema for", app); return 1
    out = os.path.join(STATS, "UserGameStatsSchema_%d.bin" % app)
    open(out, "wb").write(bkv.enc(s))
    t = build_stats(app, 1530268740)
    outp = os.path.join(STATS, "UserGameStats_1530268740_%d.bin" % app)
    open(outp, "wb").write(bkv.enc(t))
    n = sum(len(b.kids) for b in [k for k in s.kids if k.name == b"stats"][0].kids)
    print("app %d: schema %d bytes, stats %d bytes -> %s" % (app, os.path.getsize(out), os.path.getsize(outp), out))
    return 0

if __name__ == "__main__":
    sys.exit(main())
