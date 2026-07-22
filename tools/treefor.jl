# @threads-macro-level alternatives, scheduler untouched:
#   flat    — today's @threads (nthreads tasks, caller waits)
#   callerN — flat spawn of nt-1, caller runs chunk 0
#   tree    — Cilk/rayon recursive halving to depth log2(nt); caller
#             participates; join is a log-depth wait tree
#   grain   — tree that stops splitting below a minimum chunk (TBB-style)
#   batch   — Polyester reference
using Base.Threads
using Polyester: @batch

const NT = nthreads(:default)

@inline function kernel!(y::Vector{Float32}, x::Vector{Float32}, lo::Int, hi::Int)
    @inbounds @simd for i in lo:hi
        y[i] = 2.0f0 * x[i] + y[i]
    end
end

function flat!(y, x)
    n = length(y); c = cld(n, NT)
    @sync for k in 1:NT
        lo = (k-1)*c + 1; hi = min(k*c, n)
        lo > n && break
        @spawn kernel!(y, x, lo, hi)
    end
end

function callern!(y, x)
    n = length(y); c = cld(n, NT)
    tasks = Vector{Task}(undef, 0)
    sizehint!(tasks, NT-1)
    for k in 2:NT
        lo = (k-1)*c + 1; hi = min(k*c, n)
        lo > n && break
        t = Task(() -> kernel!(y, x, lo, hi))
        t.sticky = false
        schedule(t)
        push!(tasks, t)
    end
    kernel!(y, x, 1, min(c, n))
    foreach(wait, tasks)
end

function treerec!(y, x, lo, hi, depth)
    if depth <= 0
        kernel!(y, x, lo, hi)
        return
    end
    mid = (lo + hi) >> 1
    t = @spawn treerec!(y, x, mid+1, hi, depth-1)
    treerec!(y, x, lo, mid, depth-1)
    wait(t)
end
tree!(y, x) = treerec!(y, x, 1, length(y), trailing_zeros(nextpow(2, NT)))

function grainrec!(y, x, lo, hi, depth, minchunk)
    if depth <= 0 || hi - lo + 1 <= minchunk
        kernel!(y, x, lo, hi)
        return
    end
    mid = (lo + hi) >> 1
    t = @spawn grainrec!(y, x, mid+1, hi, depth-1, minchunk)
    grainrec!(y, x, lo, mid, depth-1, minchunk)
    wait(t)
end
grain!(y, x) = grainrec!(y, x, 1, length(y), trailing_zeros(nextpow(2, NT)), 4096)

function batch!(y, x)
    @batch for i in eachindex(y)
        @inbounds y[i] = 2.0f0 * x[i] + y[i]
    end
end

function threadsmacro!(y, x)
    @threads for i in eachindex(y)
        @inbounds y[i] = 2.0f0 * x[i] + y[i]
    end
end

function measure(f!, iters, y, x)
    f!(y, x)
    best = Inf
    for _ in 1:3
        GC.gc(false)
        t0 = time_ns()
        for _ in 1:iters
            f!(y, x)
        end
        best = min(best, (time_ns() - t0) / 1e3 / iters)
    end
    best
end

for (n, iters) in ((1_000, 20_000), (10_000, 5_000), (100_000, 1_000), (1_000_000, 200))
    y = zeros(Float32, n); x = rand(Float32, n)
    r = [name => measure(f!, iters, y, x) for (name, f!) in
         ("threads" => threadsmacro!, "flat" => flat!, "callern" => callern!,
          "tree" => tree!, "grain" => grain!, "batch" => batch!)]
    println("N=$n  ", join(("$(k)=$(round(v, digits=2))us" for (k,v) in r), "  "))
end

# OpenMP schedule(dynamic): shared atomic chunk counter, caller helps until
# the chunks are gone; work-conserving caller participation.
function selfsched!(y, x)
    n = length(y); nchunks = NT; c = cld(n, nchunks)
    ctr = Threads.Atomic{Int}(0)
    work = let y=y, x=x, n=n, c=c, ctr=ctr, nchunks=nchunks
        function ()
            while true
                k = Threads.atomic_add!(ctr, 1)
                k >= nchunks && break
                kernel!(y, x, k*c + 1, min((k+1)*c, n))
            end
        end
    end
    tasks = Vector{Task}(undef, NT-1)
    for i in 1:NT-1
        t = Task(work)
        t.sticky = false
        schedule(t)
        tasks[i] = t
    end
    work()
    foreach(wait, tasks)
end

# Chunk countdown latch: completion = all chunks done, not all tasks done.
# Un-woken helper tasks are fire-and-forget shells that exit on the drained
# counter whenever they eventually run.
function selfsched2!(y, x)
    n = length(y); nchunks = NT; c = cld(n, nchunks)
    ctr = Threads.Atomic{Int}(0)
    done = Threads.Atomic{Int}(0)
    work = let y=y, x=x, n=n, c=c, ctr=ctr, done=done, nchunks=nchunks
        function ()
            while true
                k = Threads.atomic_add!(ctr, 1)
                k >= nchunks && break
                kernel!(y, x, k*c + 1, min((k+1)*c, n))
                Threads.atomic_add!(done, 1)
            end
        end
    end
    for i in 1:NT-1
        t = Task(work)
        t.sticky = false
        schedule(t)
    end
    work()
    while done[] < nchunks
        ccall(:jl_cpu_pause, Cvoid, ())
        GC.safepoint()
    end
end
