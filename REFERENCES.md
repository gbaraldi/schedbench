# Research context for the scheduler design

Verified citations (2026-07-08) mapped onto the design decisions in
JuliaLang/julia #56475/#62284/#62285 and the experiments in this suite.

## Delayed work exposure (the LIFO steal grace, JULIA_LIFO_STEAL_GRACE)
- Acar, Charguéraud, Rainey. *Scheduling Parallel Programs by Work Stealing
  with Private Deques.* PPoPP 2013. Owner serves steal requests by polling at
  delay ≤ δ; proves the bound degrades only by an additive O(δ)-per-critical-
  path-node term. **The formal justification for a steal grace: delay is
  additive on the span, not multiplicative on work** — matching our sweep
  (fan-out throughput flat in grace size, chain latency improves).
- Tzannes, Caragea, Barua, Vishkin. *Lazy Binary-Splitting.* PPoPP 2010;
  TOPLAS 2014 (*Lazy Scheduling*). Victim-side laziness: publish work only on
  observed thief demand.
- Acar, Charguéraud, Guatto, Rainey, Sieczkowski. *Heartbeat Scheduling.*
  PLDI 2018; TPAL, PLDI 2021. Promote latent frames to stealable tasks on a
  clock — throttles task creation rather than thieves.
- Dinan, Larkins, Sadayappan, Krishnamoorthy, Nieplocha. *Scalable Work
  Stealing.* SC 2009. Split private/public queues with explicit owner release.
- Singer, Agrawal, Schardl. *Waste-Efficient Work Stealing.* PPoPP 2026.
  Newest: accounts failed-steal waste, throttled/sleeping thieves with
  preserved time bounds.

## Join-side handoff (trytake_for_handoff! experiment)
- Wagner, Calder. *Leapfrogging.* PPoPP 1993. Blocked-on-future workers steal
  from the thief holding their dependency.
- Singer, Xu, Lee. *Proactive Work Stealing for Futures.* PPoPP 2019.
  Formalizes mugging; structured victim choice on future touch.
- Engineering: Java ForkJoinPool tryUnpush+helping; Intel oneTBB "task
  scheduler bypass" (execute() returns next task); Go runnext; Tokio LIFO slot.

## Child- vs continuation-stealing (why Julia can't be Cilk)
- Frigo, Leiserson, Randall. *Cilk-5.* PLDI 1998. The work-first principle.
- Blumofe, Leiserson. *Scheduling Multithreaded Computations by Work
  Stealing.* JACM 1999. The foundational bounds.
- Guo, Barik, Raman, Sarkar. *Work-First and Help-First Scheduling Policies.*
  IPDPS 2009; SLAW (Guo, Zhao, Cavé, Sarkar), IPDPS 2010: adaptive per-task.
- Schardl, Lee. *OpenCilk.* PPoPP 2023. Reference modern continuation-stealing
  implementation (Tapir).
- Kumar, Frampton, Blackburn, Grove, Tardieu. *Work-Stealing Without the
  Baggage.* OOPSLA 2012. Steals materialized at victim yieldpoints.

## Spinner accounting / idle-thread throttling (#62284)
- Arora, Blumofe, Plaxton. SPAA 1998. Thieves yield between failed steals.
- Ding, Wang, Gibbons, Zhang. *BWS.* EuroSys 2012. Sleep persistent failed
  stealers; yield-to-victim.
- McClure, Ousterhout, Shenker, Ratnasamy. *Efficient Scheduling Policies for
  Microsecond-Scale Tasks.* NSDI 2022. Work stealing wins at µs scale;
  quantifies polling-vs-parking waste. Also Shenango (NSDI 2019), Caladan
  (OSDI 2020).

## Latency vs throughput (pingpong-vs-fanout; interactive threadpool)
- Muller, Acar, Harper. *Responsive Parallel Computation.* PLDI 2017;
  Fairness: Muller, Westrick, Acar, ICFP 2019; Futures+state: PLDI 2020.

## Queue mechanics
- Hendler, Shavit. *Non-Blocking Steal-Half Work Queues.* PODC 2002.
- Michael, Vechev, Saraswat. *Idempotent Work Stealing.* PPoPP 2009
  (fence-free owner path via at-least-once semantics).
- Acar, Blelloch, Blumofe. *The Data Locality of Work Stealing.* SPAA 2000;
  Shiina, Taura. *Almost Deterministic Work Stealing.* SC 2019.

## Negative result
No peer-reviewed analysis of Go's current scheduler or Tokio's exists
(2018–2026); primary sources remain Vyukov's 2012 design doc, runtime code
comments, and the Tokio blog. Our TLA+ model of the wake protocol
(doc/src/devdocs/scheduler-wakeup/) appears to be untrodden ground.

## Dedicated IO thread vs polling in workers (why not to dedicate)
- Go pre-1.1: singleton `pollServer` goroutine waking blocked goroutines via
  channels (go1.0.3 src/pkg/net/fd.go). Replaced by the integrated netpoller,
  golang/go@49e03008 (Go 1.1, 2013): TCP4Persistent −93%, OneShot −77% in the
  commit message. Current: findRunnable polls; idle Ms block in netpoll;
  sysmon 10ms backstop.
- Tokio: reform RFC (2017) chose a dedicated event-loop thread; 0.1 runtime
  shipped it (docs.rs tokio 0.1.3). Reversed: tokio-rs/tokio#660 (2018,
  "sharing one reactor among all workers causes a lot of contention; each
  worker drives its own reactor when it goes to sleep"), completed by the
  0.2 scheduler (10x blog; Hyper +34%). Current multi_thread/park.rs: one
  shared driver behind TryLock, parking workers compete for it, losers park
  on condvars — architecturally identical to Julia's jl_uv_mutex scheme.

## Wakeup policy: how many workers to wake, and when (2026-07-21)

The ablation of #62284 against its merge-base isolated the wakeup-policy
question from task selection: master wakes one thread per enqueue (parallel
burst ramp, pathological handoff storms), spinner accounting wakes at most
one while anyone spins (storm-free, serial burst ramp). Survey of how other
runtimes gate wakeups:

### Family 1: spinner-conservation gates (wake ≤ 1, rely on propagation)
- Vyukov, *Scalable Go Scheduler Design Doc* (2012) + `runtime/proc.go`
  header comment: unpark an additional spinning M when readying a goroutine
  only "if there is an idle P and there are no other spinning threads";
  the doc explicitly names the tradeoff — unconditional unpark causes
  "excessive thread parking/unparking", suppressed unpark hurts ramp.
  Propagation: a spinning M that finds work calls `wakep` (resetspinning)
  to conserve "one spinner while there may be work". Burst ramp is a serial
  chain, absorbed in practice by steal-half + long busy-spin in findrunnable.
- Tokio (multi-thread runtime, since PR #660 rewrite): `notify_one` gated on
  "no searching workers"; a searching worker that finds work notifies a
  successor. Same shape as Go; LIFO slot + steal-half bound the damage.
- **Both mitigate the serial chain with a spin phase long enough to absorb
  the next wake — the piece Julia's park-immediately workers lack.**

### Family 2: demand-count gates (wake pending − active, generically)
- Java ForkJoinPool (Doug Lea, jsr166): `signalWork` releases/creates a
  worker whenever the packed `ctl` counts show active < parallelism AND
  work was just pushed; each activated worker signals at most one more if
  its queue is still nonempty ("to reduce flailing, each worker signals
  only one other per activation") — count gate + bounded propagation chain.
- Rayon (`rayon-core/src/sleep/README.md`): on posting a job, "check if
  there are idle threads available to handle this new job; if not, and
  there are sleeping threads, then wake one or more" — demand vs
  idle-count comparison, with the Jobs Event Counter protocol (seq-cst
  fence + odd/even counter) closing the lost-wakeup race. The best written
  spec of a count-gated wake protocol.
- TBB: arena advertises work to the market, which adjusts per-arena worker
  demand (`adjust_demand`) — workers are allocated by count of pending
  demand, not by a boolean "someone is looking".
- Agrawal, Leiserson et al., *Adaptive work stealing with parallelism
  feedback* (A-STEAL, PPoPP 2007/TOCS): per-quantum processor requests from
  measured parallelism — demand-count at scheduler-quantum granularity.

### Family 3: congestion/delay signals (the µs-kernel literature)
- Shenango (NSDI 2019): IOKernel polls every 5 µs; a packet or thread still
  queued since the previous poll ⇒ grant one more core. Delay-since-last-
  check, not instantaneous count — deliberately hysteretic to avoid
  overreaction. Caladan (OSDI 2020) refines with finer signals.
- Arachne (OSDI 2018): core estimator from load factor with hysteresis.

### Family 4: don't sleep / structured release
- OpenMP (libomp): `KMP_BLOCKTIME` default 200 ms of spin-wait before
  parking — back-to-back regions never pay a wake at all (the design Julia
  approximates with JULIA_THREAD_SLEEP_THRESHOLD=100µs, 2000× shorter);
  when workers do sleep, fork release goes through the tree barrier
  (hierarchical, log fan-out; cf. Mellor-Crummey & Scott 1991).

### Synthesis for Julia
Sampler evidence (this suite + jl_sched_n_spinning getter): committed SA
ramps a parked pool in parallel by accident (freshly woken threads aren't
spinners yet, so the boolean gate stays open) but starves when leftover
spinners exist; wakep serializes the cold ramp (pre-accounted slot closes
the gate after one wake). Both fail because the gate compares spinners to
ZERO. The FJP/Rayon/TBB family compares to PENDING: wake while
n_spinning < pending, which with wake-as-spinner pre-accounting wakes
exactly (pending − in-flight) workers — burst fan-out, handoff gating, and
no starvation from leftover spinners, with no fork-join special-casing.

### The academic literature on the same question
- Karlin, Li, Manasse, Owicki. *Empirical Studies of Competitive Spinning
  for a Shared-Memory Multiprocessor.* SOSP 1991. Spin-then-block with spin
  budget ≈ context-switch cost is 2-competitive with the offline optimum;
  studies seven adaptive variants. The theory behind every blocktime/grace
  knob (KMP_BLOCKTIME, JULIA_THREAD_SLEEP_THRESHOLD): the wake side gets
  cheaper the longer the sleep side is willing to poll.
- Lim, Agarwal. *Waiting Algorithms for Synchronization in Large-Scale
  Multiprocessors.* TOCS 11(3), 1993. Generalizes two-phase waiting beyond
  locks (barriers, producer-consumer); static spin budgets close to optimal
  when waiting-time distributions are known.
- Gandhi, Doroudi, Harchol-Balter, Scheller-Wolf. *Exact Analysis of the
  M/M/k/setup Class of Markov Chains.* SIGMETRICS 2013; and Gandhi et al.,
  *AutoScale* (TOCS 2012). The queueing-theoretic formalization: a parked
  worker is a server with a SETUP TIME (our ~35µs wake hop). Main results
  mapped to schedulers: (a) setup times shift the optimal policy toward
  keeping servers on briefly after going idle (DelayedOff ≈ blocktime /
  sleep threshold), and (b) waking one server per arrival (staggered setup)
  badly underperforms when arrivals are bursty — the queueing-theory name
  for the serial wake chain this suite measured (8.7µs vs 34.7µs inter-wake
  gaps; running-thread crawl 3→11 over 800µs on a 16-task burst).
- Williams et al., CMU-CS-24-104 (2024) and the M/M/k/Setup-Deterministic
  line (SIGMETRICS 2023): deterministic setup times (closest to a futex
  wake) are provably worse for waiting time than exponential ones at the
  same mean — bursty fork-join is the adversarial case, not the benign one.
- Ribic, Liu. *Energy-Efficient Work-Stealing Language Runtimes.* ASPLOS
  2014 (HERMES). DVFS-based thief tempo control; the energy-side argument
  for waking few workers slowly — the counterweight to burst fan-out, and
  why the count gate should wake (pending − searching), not the whole pool.
