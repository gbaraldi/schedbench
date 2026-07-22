using Base.Threads
using Polyester: @batch
const NT = nthreads(:default)
@inline function kernel!(y, x, lo, hi)
    @inbounds @simd for i in lo:hi
        y[i] = 2.0f0 * x[i] + y[i]
    end
end
function threadsmacro!(y, x)
    @threads for i in eachindex(y)
        @inbounds y[i] = 2.0f0 * x[i] + y[i]
    end
end
# adaptive helpers: spawn only as many helpers as the work supports
# (grain=4096), caller runs the first chunk; all tasks carry real work
function adaptive!(y, x)
    n = length(y)
    nchunks = min(NT, max(1, cld(n, 4096)))
    c = cld(n, nchunks)
    if nchunks == 1
        kernel!(y, x, 1, n)
        return
    end
    tasks = Vector{Task}(undef, nchunks - 1)
    for k in 2:nchunks
        lo = (k-1)*c + 1; hi = min(k*c, n)
        tasks[k-1] = @spawn kernel!(y, x, $lo, $hi)
    end
    kernel!(y, x, 1, c)
    foreach(wait, tasks)
end
function batch!(y, x)
    @batch for i in eachindex(y)
        @inbounds y[i] = 2.0f0 * x[i] + y[i]
    end
end
function measure(f!, iters, y, x)
    f!(y, x)
    best = Inf
    for _ in 1:3
        GC.gc(false)
        t0 = time_ns()
        for _ in 1:iters; f!(y, x); end
        best = min(best, (time_ns() - t0) / 1e3 / iters)
    end
    best
end
for (n, iters) in ((1_000, 20_000), (10_000, 5_000), (100_000, 1_000), (1_000_000, 200))
    y = zeros(Float32, n); x = rand(Float32, n)
    r = [name => measure(f!, iters, y, x) for (name, f!) in
         ("threads" => threadsmacro!, "adaptive" => adaptive!, "batch" => batch!)]
    println("N=$n  ", join(("$(k)=$(round(v, digits=2))us" for (k,v) in r), "  "))
end
