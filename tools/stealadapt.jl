# User-side steal-adaptive parallel for: shared atomic cursor over the
# iteration range, guided (halving) block sizes, and a LADDER of workers —
# each worker spawns at most one successor before touching the range, so a
# busy machine never materializes parallelism (the unstarted task is the
# "nobody is idle" signal) while an idle machine cascades to full width.
# Completion is a done-count latch, so at most one never-started shell task
# per region exists and nobody waits on it.
using Base.Threads
using Polyester: @batch
using OhMyThreads: tforeach, GreedyScheduler
const NT = nthreads(:default)

struct AdaptiveRange
    cursor::Threads.Atomic{Int}   # next unclaimed iteration (1-based)
    done::Threads.Atomic{Int}     # completed iterations
    n::Int
end

# grab a guided-size block: half the remainder split across 2NT, floored by
# minblock (the SIMD grain; demand checks never enter the inner kernel)
@inline function grab!(r::AdaptiveRange, minblock::Int)
    while true
        lo = r.cursor[]
        lo > r.n && return 0:-1
        blk = max(minblock, (r.n - lo + 1) ÷ (2 * NT))
        hi = min(lo + blk - 1, r.n)
        if Threads.atomic_cas!(r.cursor, lo, hi + 1) == lo
            return lo:hi
        end
    end
end

function worker(body::F, r::AdaptiveRange, minblock::Int, rung::Int) where {F}
    spawned = false
    while true
        blk = grab!(r, minblock)
        isempty(blk) && break
        if !spawned && rung < NT - 1 && r.cursor[] <= r.n
            # expose the next rung before working: if anyone is idle they
            # will run it and keep the cascade going; if not it stays queued
            let body=body, r=r, minblock=minblock, nrung=rung+1
                @spawn worker(body, r, minblock, nrung)
            end
            spawned = true
        end
        body(blk)                       # clean inner kernel, no checks inside
        Threads.atomic_add!(r.done, length(blk))
    end
end

function adaptive_for(body::F, n::Int; minblock::Int=1) where {F}
    n <= 0 && return
    r = AdaptiveRange(Threads.Atomic{Int}(1), Threads.Atomic{Int}(0), n)
    worker(body, r, minblock, 0)        # caller is rung 0
    while r.done[] < n                  # latch: chunks, not tasks
        ccall(:jl_cpu_pause, Cvoid, ())
        GC.safepoint()
    end
end

# ---- the three regimes + tiny ----------------------------------------------
function burn(units); x = 0.0; for _ in 1:units; x += sin(x) + 1.0; end; x; end

function measure(f, iters)
    f()
    best = Inf
    for _ in 1:3
        GC.gc(false)
        t0 = time_ns()
        for _ in 1:iters; f(); end
        best = min(best, (time_ns() - t0) / 1e3 / iters)
    end
    best
end

y1 = zeros(Float32, 1_000); x1 = rand(Float32, 1_000)
y2 = zeros(Float32, 10_000); x2 = rand(Float32, 10_000)
axpy_blk!(y, x) = blk -> (@inbounds @simd for i in blk; y[i] = 2.0f0*x[i] + y[i]; end)
out32 = zeros(32)
outs = zeros(1_000)

th1!() = @threads for i in 1:1000; @inbounds y1[i] = 2f0*x1[i]+y1[i]; end
bt1!() = @batch for i in 1:1000; @inbounds y1[i] = 2f0*x1[i]+y1[i]; end
th2!() = @threads for i in 1:10_000; @inbounds y2[i] = 2f0*x2[i]+y2[i]; end
bt2!() = @batch for i in 1:10_000; @inbounds y2[i] = 2f0*x2[i]+y2[i]; end
thfl!() = @threads for i in 1:32; out32[i] = burn(40_000); end
thsk!() = @threads for i in 1:1000; outs[i] = burn(4i); end
omtsk!() = tforeach(i -> (outs[i] = burn(4i)), 1:1000; scheduler=GreedyScheduler())

println("tiny 1k:      adaptive=", round(measure(() -> adaptive_for(axpy_blk!(y1, x1), 1000; minblock=2048), 20_000), digits=2),
        "us  threads=", round(measure(th1!, 20_000), digits=2),
        "us  batch=", round(measure(bt1!, 20_000), digits=2), "us")
println("uniform 10k:  adaptive=", round(measure(() -> adaptive_for(axpy_blk!(y2, x2), 10_000; minblock=2048), 5_000), digits=2),
        "us  threads=", round(measure(th2!, 5_000), digits=2),
        "us  batch=", round(measure(bt2!, 5_000), digits=2), "us")
fl_body = blk -> (for i in blk; out32[i] = burn(40_000); end)
println("fewlong 32x1ms:  adaptive=", round(measure(() -> adaptive_for(fl_body, 32), 3)/1000, digits=2),
        "ms  threads=", round(measure(thfl!, 3)/1000, digits=2), "ms")
sk_body = blk -> (for i in blk; outs[i] = burn(4i); end)
println("skewed 1k:  adaptive=", round(measure(() -> adaptive_for(sk_body, 1000), 3)/1000, digits=2),
        "ms  threads=", round(measure(thsk!, 3)/1000, digits=2),
        "ms  omt_greedy=", round(measure(omtsk!, 3)/1000, digits=2), "ms")
