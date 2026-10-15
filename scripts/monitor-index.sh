#!/bin/bash
# Samples the running Findling and its catalog as CSV. Reads the catalog read-only.
# Usage: scripts/monitor-index.sh [interval seconds] [output file]
set -u
interval="${1:-10}"
out="${2:-/dev/stdout}"
db="$HOME/Library/Application Support/Findling/catalog-v2.sqlite"
start=$(date +%s)
echo "time,elapsed_s,cpu_percent,cpu_time,footprint,rss_mb,db_mb,wal_mb,entries,walk_done,probe_ms" > "$out"
while true; do
  pid=$(pgrep -x Findling | head -1)
  if [ -n "$pid" ]; then
    cpu=$(ps -o %cpu= -p "$pid" | tr -d ' ')
    cputime=$(ps -o time= -p "$pid" | tr -d ' ')
    rss=$(( $(ps -o rss= -p "$pid") / 1024 ))
    footprint=$(footprint "$pid" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]* [KMG]B\).*/\1/p')
  else
    cpu=""; cputime=""; rss=""; footprint="not running"
  fi
  size() { [ -f "$1" ] && echo $(( $(stat -f %z "$1") / 1048576 )) || echo 0; }
  catalog=$(/usr/bin/python3 -I - "$db" <<'EOF' 2>/dev/null
import sqlite3, sys, time
try:
    db = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True, timeout=5)
    entries = db.execute('SELECT count(*) FROM entries').fetchone()[0]
    done = db.execute("SELECT count(*) FROM metadata WHERE key='eventCursor'").fetchone()[0]
    started = time.time()
    db.execute("SELECT count(*) FROM names WHERE names MATCH 'nname : \"readme\"'").fetchone()
    print(f"{entries},{'yes' if done else 'no'},{(time.time() - started) * 1000:.0f}")
except Exception:
    print(",,")
EOF
)
  echo "$(date +%T),$(( $(date +%s) - start )),$cpu,$cputime,$footprint,$rss,$(size "$db"),$(size "$db-wal"),${catalog:-,,}" >> "$out"
  sleep "$interval"
done
