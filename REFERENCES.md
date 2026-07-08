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
