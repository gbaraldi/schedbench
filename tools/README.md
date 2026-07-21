# Measurement tools

Instruments developed alongside the #62284/#62285 scheduler work. Three tiers:

## Works against any julia built with `WITH_DTRACE=1` in Make.user
- `sched.bt` — aggregating bpftrace script: park-duration and wake→unpark
  latency histograms, wake counts by reason, from the runtime's USDT probes.
- `waketime.bt` / `wakestack.bt` — per-wake timestamps (burst spacing
  analysis) and waker call stacks.
- `run_bt.sh`, `triad_probe.jl`, `pp_probe.jl` — harness: julia runs as the
  user gated on a start file; bpftrace attaches as root to the live PID
  (never `sudo bpftrace -c julia` — the workload must not run as root).
- Probes are a nop + ELF note when unattached; safe in benchmark builds.
  Note `sys/sdt.h` lives at the multiarch path on Ubuntu and Make.user flag
  changes do not invalidate objects (`make -C src clean` first).

## Works against stock julia
- `wallprof.jl` — Profile.@profile_walltime bucketed into
  parked/scheduler-wait vs work vs task machinery (sees sleeping threads,
  which perf record cannot).

## Requires an ablation build (runtime-toggle exports in scheduler.c)
- `ablate.jl` — interleaved single-build A/B across wake-policy configs
  (needs `jl_set_surplus_wake`/`jl_set_warm_park` exports).
- `cap_ab.jl` — half-pool searcher cap A/B (needs `jl_set_spin_cap`).
- `sampler.jl` — timeline of queued tasks vs spinners vs running threads,
  sampled from a sticky interactive-pool task (`-t N,1`); needs
  `jl_sched_n_spinning`/`jl_sched_n_running` getters.
- `surplus_ab.jl` — the original triad+pingpong interleaved A/B.

The toggle/getter exports were ablation scaffolding, deleted before the
policy landed; each is a ~5-line `JL_DLLEXPORT` following the patterns the
scripts ccall. Methodology notes and results in ../REFERENCES.md and the
suite README.
