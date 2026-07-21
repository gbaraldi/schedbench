# Interleaved A/B of surplus propagation on one build.
using Base.Threads
const NB = 20_000_000
const bA = zeros(NB); const bB = fill(2.0, NB); const bC = fill(2.0, NB)
triad(iters) = for _ in 1:iters
    Threads.@threads for i in 1:NB
        @inbounds bA[i] += bB[i] + 3.0 * bC[i]
    end
end
function ppw(rounds)
    c1 = Channel{Int}(0); c2 = Channel{Int}(0)
    cons = Threads.@spawn for _ in 1:rounds; put!(c2, take!(c1)); end
    prod = Threads.@spawn begin
        t0 = time_ns(); for i in 1:rounds; put!(c1, i); take!(c2); end
        (time_ns() - t0) / 1e6
    end
    ms = fetch(prod); wait(cons); ms
end
set(x) = ccall(:jl_set_surplus_wake, Cvoid, (Cint,), x)
triad(3); ppw(1000)  # warmup
for rep in 1:4, mode in (0, 1)
    set(mode)
    t = @elapsed triad(10)
    gbps = round(4 * 8 * NB * 10 / t / 1e9, digits=1)
    p = round(ppw(10_000), digits=1)
    println("rep$rep surplus=$mode  triad=$gbps GB/s  pingpong_workers=$p ms")
end
