# A/B the half-pool searcher cap under the count-gate policy (surplus=1).
using Base.Threads

mutable struct RUsage
    ru_utime_s::Clong; ru_utime_us::Clong; ru_stime_s::Clong; ru_stime_us::Clong
    pad::NTuple{14,Clong}
    RUsage() = new(0,0,0,0,ntuple(_->Clong(0),14))
end
function cputime()
    ru = RUsage()
    ccall(:getrusage, Cint, (Cint, Ref{RUsage}), 0, ru)
    ru.ru_utime_s + ru.ru_utime_us/1e6 + ru.ru_stime_s + ru.ru_stime_us/1e6
end

const N = 4_000_000
const A = zeros(N); const B = rand(N); const C = rand(N)
triad(iters) = for _ in 1:iters
    @threads for i in 1:N
        @inbounds A[i] = B[i] + 3.0 * C[i]
    end
end
function ppw(rounds)
    c1 = Channel{Int}(0); c2 = Channel{Int}(0)
    cons = @spawn for _ in 1:rounds; put!(c2, take!(c1)); end
    prod = @spawn begin
        t0 = time_ns(); for i in 1:rounds; put!(c1, i); take!(c2); end
        (time_ns()-t0)/1e6
    end
    ms = fetch(prod); wait(cons); ms
end

ccall(:jl_set_surplus_wake, Cvoid, (Cint,), 1)  # count-gate on throughout
triad(3); ppw(500)

for rep in 1:4, cap in (1, 0)
    ccall(:jl_set_spin_cap, Cvoid, (Cint,), cap)
    triad(1)
    c0 = cputime(); w0 = time_ns()
    t = @elapsed triad(10)
    cpu = cputime() - c0; wall = (time_ns()-w0)/1e9
    p = ppw(10_000)
    # burst-then-idle: how much CPU burns in the 50ms after work ends?
    triad(1); ci = cputime(); sleep(0.05); idlecpu = cputime() - ci
    println("rep$rep cap=$cap triad=$(round(32*N*10/t/1e9, digits=1))GB/s cpu/wall=$(round(cpu/wall, digits=1)) pingpong=$(round(p, digits=1))ms idleburn=$(round(idlecpu*1000, digits=1))ms")
    flush(stdout)
end
