# schedbench — Julia scheduler benchmark suite

Benchmarks developed while building the workstealing scheduler
(JuliaLang/julia #56475 / #62284 / #62285), consolidated so scheduler work
can be measured reproducibly. Pure Base, no package dependencies.

## Usage

```sh
# run everything on two builds, then compare
julia bench.jl --julia ~/julia-ws/usr/bin/julia    --tag ws    --threads 8,32 --reps 2
julia bench.jl --julia ~/julia-partr/usr/bin/julia --tag partr --threads 8,32 --reps 2
julia compare.jl results/partr-*.tsv results/ws-*.tsv
```

Each group also runs standalone: `julia -t 8,1 benchmarks/messaging.jl`.

`plot.jl` renders unicode charts (UnicodePlots.jl, via the suite's project
env): speedup/slowdown bar sections per thread count, oriented so >1x is
always "new is better" regardless of unit, plus a producer-scaling line plot
when producers results are present:

```sh
julia --project=. plot.jl results/partr-*.tsv results/ws-*.tsv
```

## Benchmark groups

| group | benchmarks | measures | sensitive to |
|---|---|---|---|
| throughput | fib24, nqueens12, cilksort8M, imbalance, stencil | recursive fork-join, steal rebalancing, barrier sweeps | queue design, steal batching |
| regions | pfor_fine (c2048/c256), tiny_regions | fine-grained parallel-for, per-region latency | spawn cost, wake path, sync |
| messaging | spawn_many, pingpong, token_ring, wake_storm | channel handoffs, parked-task chains, mass wake | LIFO slot, wake protocol, spinner accounting |
| latency | raw_ctx_switch, task_alloc, yield, spawn_join{,_pinned}, spawn_forget, wake_parked p50/p99 | single-operation costs, main-vs-worker (cross- vs same-pool) | everything; the Go-comparison numbers |
| producers | prod_main, prod_P{1,2,4,8,2NT} | spawn-path throughput and retire ceiling | spawn cost, inject striping, @sync bookkeeping |
| fairness | ttc sojourn p50/p99/max, staggered displacement, prefix_1M | scheduling-delay distribution under admission control; yield-requeue order; dependent barrier chains (after kpamnany/MultithreadingBenchmarks.jl) | LIFO-slot starvation risk, fairness tick, barrier latency |
| tokiostyle | chained_spawn, yield_many, ping_pong pairs, spawn_busy | serial spawn chains, contended yield, mass handoff pairs, injection under load (after tokio benches/rt_multi_threaded.rs) | LIFO handoff, yield requeue locality, inject drain rate / fairness tick |

Reference points (Go 1.22, same machine, `crossruntime/`): goroutine switch
~60ns (Julia raw yieldto: ~59ns — parity), spawn+join ~270ns, single-producer
spawn ~1.0µs/task, producer ceiling ~1.9 Mtask/s (Julia ws: ~3.1 at P32).

## Cross-runtime equivalents

`crossruntime/gospawn.go` and `crossruntime/tokiospawn/` mirror the producers
group; `gobench.go` mirrors messaging/latency. Build with `go build` /
`cargo build --release`. Caveat for quoting Tokio numbers: the idiomatic
counter+Notify implementation pays two Arc clone/drop pairs per task that
GC'd runtimes don't.

## Methodology (learned the hard way)

- **Same-day baselines only.** This machine drifts 10–30% between days on
  identical code. Never compare against a TSV from another day; re-run the
  baseline.
- **±15% is noise** for single runs of fib/nqueens/spawn_many/token_ring.
  `compare.jl` marks only larger deltas; trust smaller ones only when
  consistent across `--reps` and across days.
- **One process per group** (bench.jl does this): spinner population, GC
  pressure, and thread placement from one benchmark contaminate the next.
- Latency benchmarks are 1–2-thread games and producer-bound spawn storms
  measure the *producer*: don't read either as scheduler scalability. Use
  throughput + producers-at-high-P for that.
- Spin-wait loops in benchmark code need `GC.safepoint()` or they deadlock
  the GC; kill hung runs with `timeout -k` (SIGTERM alone won't stop spinning
  tasks); beware `pkill -f` matching your own wrapper shell.
- `-tN` means `-tN,1`: the main task lives on the interactive thread, so
  main-spawned work always crosses pools (inject queue + wake, no LIFO
  handoff). The latency group measures both sides; the `main/*` vs `worker/*`
  split is structural, not noise.
