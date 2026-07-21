#!/bin/bash
# Usage: run_bt.sh <0|1>   (JULIA_SURPLUS value)
# Runs triad_probe.jl as the invoking user, attaches root bpftrace for the
# measured phase only, prints both outputs.
set -u
SP=/tmp/claude-57389960/-home-gbaraldi-julia2/4e72f64f-5b5e-4c85-973c-477e54f74a86/scratchpad
GATE=$SP/gate.$1.$$
rm -f "$GATE"

JULIA_SURPLUS=$1 ~/julia2-partr/usr/bin/julia -t 16 "$SP/triad_probe.jl" "$GATE" > "$SP/julia.$1.out" 2>&1 &
JPID=$!

for _ in $(seq 100); do
    grep -q READY "$SP/julia.$1.out" 2>/dev/null && break
    sleep 0.2
done

sudo bpftrace "$SP/sched.bt" -p "$JPID" > "$SP/bt.$1.out" 2> "$SP/bt.$1.err" &
BTPID=$!
sleep 3   # give bpftrace time to attach uprobes
touch "$GATE"

wait "$JPID"
wait "$BTPID" 2>/dev/null
rm -f "$GATE"

echo "===== julia (surplus=$1) ====="
cat "$SP/julia.$1.out"
echo "===== bpftrace ====="
cat "$SP/bt.$1.out"
sed -n 1,5p "$SP/bt.$1.err"
