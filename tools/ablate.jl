# Ablation runner for #62284 components. Configs are runtime-toggled so all
# non-base configs interleave in one process (same-build A/B). The merge-base
# build runs with ABLATE_BASE=1 (no toggle ccalls; symbols don't exist there).
#
# Output: RESULT <rep> <config> <metric> <value>
using Base.Threads

const BASE = get(ENV, "ABLATE_BASE", "0") == "1"

mutable struct RUsage
    ru_utime_s::Clong; ru_utime_us::Clong; ru_stime_s::Clong; ru_stime_us::Clong
    ru_maxrss::Clong; ru_ixrss::Clong; ru_idrss::Clong; ru_isrss::Clong
    ru_minflt::Clong; ru_majflt::Clong; ru_nswap::Clong
    ru_inblock::Clong; ru_oublock::Clong; ru_msgsnd::Clong; ru_msgrcv::Clong
    ru_nsignals::Clong; ru_nvcsw::Clong; ru_nivcsw::Clong
    RUsage() = new(ntuple(_->0,18)...)
end
function ctxswitches()
    ru = RUsage()
    ccall(:getrusage, Cint, (Cint, Ref{RUsage}), 0, ru)
    ru.ru_nvcsw + ru.ru_nivcsw
end

# --- workloads ---------------------------------------------------------------
const N = 4_000_000
const A = zeros(N); const B = rand(N); const C = rand(N)

function triad(iters)
    for _ in 1:iters
        @threads for i in 1:N
            @inbounds A[i] = B[i] + 3.0 * C[i]
        end
    end
end

function region_ramps(iters)
    starts = Vector{Int64}(undef, nthreads(:default))
    t0 = Ref{Int64}(0)
    ramps = Float64[]; walls = Float64[]
    for _ in 1:iters
        t0[] = time_ns()
        @threads for k in 1:nthreads(:default)
            starts[k] = time_ns() - t0[]
            n = length(A); chunk = cld(n, nthreads(:default))
            lo = (k-1)*chunk + 1; hi = min(k*chunk, n)
            @inbounds for i in lo:hi
                A[i] = B[i] + 3.0 * C[i]
            end
        end
        push!(ramps, maximum(starts)/1e3); push!(walls, (time_ns()-t0[])/1e6)
    end
    ramps, walls
end

function ppw(rounds)
    c1 = Channel{Int}(0); c2 = Channel{Int}(0)
    cons = @spawn for _ in 1:rounds; put!(c2, take!(c1)); end
    prod = @spawn begin
        t0 = time_ns(); for i in 1:rounds; put!(c1, i); take!(c2); end
        (time_ns() - t0)/1e6
    end
    ms = fetch(prod); wait(cons); ms
end

function spawn_many(n)
    t0 = time_ns()
    @sync for _ in 1:n
        @spawn nothing
    end
    (time_ns() - t0)/1e6
end

pct(v, p) = partialsort!(copy(v), max(1, ceil(Int, p*length(v))))

# --- config plumbing ---------------------------------------------------------
function setcfg(cfg)
    BASE && return
    warm, surplus = cfg == "sa" ? (1, 0) :
                    cfg == "sa-nowarm" ? (0, 0) :
                    cfg == "sa+wakep" ? (1, 1) : error("bad cfg $cfg")
    ccall(:jl_set_warm_park, Cvoid, (Cint,), warm)
    ccall(:jl_set_surplus_wake, Cvoid, (Cint,), surplus)
end

configs = BASE ? ["base"] : ["sa", "sa-nowarm", "sa+wakep"]

# warmup all paths
triad(3); ppw(500); spawn_many(10_000); region_ramps(3)

for rep in 1:4, cfg in configs
    setcfg(cfg)
    triad(1)  # settle after toggle flip
    c0 = ctxswitches()
    t = @elapsed triad(10)
    println("RESULT $rep $cfg triad_gbps $(round(4*8*N*10/t/1e9, digits=1))")
    println("RESULT $rep $cfg triad_ctxsw $(ctxswitches() - c0)")
    ramps, walls = region_ramps(60)
    println("RESULT $rep $cfg ramp_p50_us $(round(pct(ramps,0.5), digits=1))")
    println("RESULT $rep $cfg ramp_p99_us $(round(pct(ramps,0.99), digits=1))")
    println("RESULT $rep $cfg wall_p99_ms $(round(pct(walls,0.99), digits=3))")
    c0 = ctxswitches()
    p = ppw(10_000)
    println("RESULT $rep $cfg pingpong_ms $(round(p, digits=1))")
    println("RESULT $rep $cfg pingpong_ctxsw $(ctxswitches() - c0)")
    s = minimum(spawn_many(100_000) for _ in 1:3)
    println("RESULT $rep $cfg spawn100k_ms $(round(s, digits=1))")
    flush(stdout)
end
