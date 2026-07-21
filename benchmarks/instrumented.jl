# Step-level instrumentation: instead of one wall number per benchmark,
# record timestamps inside the workload and report latency percentiles for
# each scheduler-owned step. Complements external tracing (bpftrace/perf):
# no root needed, and the numbers are attributable to a specific step.
#
#   region ramp     — per-chunk spawn→body-start latency inside a @sync
#                     region; the per-region max is the time until the whole
#                     pool is running (the wake ramp).
#   region tail     — last-chunk-end→@sync-return (join/teardown cost).
#   pingpong rtt    — per-round put!/take! round-trip percentiles.
include(joinpath(@__DIR__, "..", "common.jl"))

pct(v, p) = isempty(v) ? NaN : partialsort!(v, max(1, ceil(Int, p * length(v))))

# --- instrumented back-to-back regions (triad-shaped work) ------------------
function region_steps(iters::Int, a, b, c)
    n = length(a)
    chunk = cld(n, NT)
    nchunks = cld(n, chunk)
    starts = Vector{Int64}(undef, nchunks)   # spawn→body-start per chunk
    ends = Vector{Int64}(undef, nchunks)
    ramps = Float64[]; starts_all = Float64[]; joins = Float64[]; walls = Float64[]
    for _ in 1:iters
        t0 = time_ns()
        @sync begin
            k = 0
            for lo in 1:chunk:n
                hi = min(lo + chunk - 1, n)
                k += 1
                let k = k, lo = lo, hi = hi
                    @spawn begin
                        starts[k] = time_ns() - t0
                        @inbounds for i in lo:hi
                            a[i] = b[i] + 3.0 * c[i]
                        end
                        ends[k] = time_ns() - t0
                    end
                end
            end
        end
        twall = time_ns() - t0
        append!(starts_all, starts ./ 1e3)
        push!(ramps, maximum(starts) / 1e3)          # µs until every chunk runs
        push!(joins, (twall - maximum(ends)) / 1e3)  # µs from last work to return
        push!(walls, twall / 1e6)                    # ms
    end
    return starts_all, ramps, joins, walls
end

# --- same region, @threads-shaped (one task per thread, threading_run) ------
function region_steps_threads(iters::Int, a, b, c)
    starts = Vector{Int64}(undef, NT)
    ends = Vector{Int64}(undef, NT)
    t0ref = Ref{Int64}(0)
    ramps = Float64[]; starts_all = Float64[]; walls = Float64[]
    for _ in 1:iters
        t0ref[] = time_ns()
        @threads for k in 1:NT
            starts[k] = time_ns() - t0ref[]
            n = length(a)
            chunk = cld(n, NT)
            lo = (k - 1) * chunk + 1
            hi = min(k * chunk, n)
            @inbounds for i in lo:hi
                a[i] = b[i] + 3.0 * c[i]
            end
            ends[k] = time_ns() - t0ref[]
        end
        twall = time_ns() - t0ref[]
        append!(starts_all, starts ./ 1e3)
        push!(ramps, maximum(starts) / 1e3)
        push!(walls, twall / 1e6)
    end
    return starts_all, ramps, walls
end

# --- instrumented unbuffered-channel pingpong --------------------------------
function pingpong_rtt(rounds::Int)
    c1 = Channel{Int}(0); c2 = Channel{Int}(0)
    rtt = Vector{Float64}(undef, rounds)
    cons = @spawn for _ in 1:rounds
        put!(c2, take!(c1))
    end
    prod = @spawn for i in 1:rounds
        t0 = time_ns()
        put!(c1, i)
        take!(c2)
        rtt[i] = (time_ns() - t0) / 1e3   # µs
    end
    wait(prod); wait(cons)
    return rtt
end

function main()
    # triad-shaped regions, ~0.7 ms of memory-bound work each
    N = 4_000_000
    a = zeros(N); b = rand(N); c = rand(N)
    region_steps(3, a, b, c)  # warmup
    starts, ramps, joins, walls = region_steps(100, a, b, c)
    result("chunk_start_p50", pct(starts, 0.50); unit="us")
    result("chunk_start_p99", pct(starts, 0.99); unit="us")
    result("region_ramp_p50", pct(ramps, 0.50); unit="us")
    result("region_ramp_p99", pct(ramps, 0.99); unit="us")
    result("region_join_p50", pct(joins, 0.50); unit="us")
    result("region_join_p99", pct(joins, 0.99); unit="us")
    result("region_wall_p50", pct(walls, 0.50))
    result("region_wall_p99", pct(walls, 0.99))

    region_steps_threads(3, a, b, c)  # warmup
    tstarts, tramps, twalls = region_steps_threads(100, a, b, c)
    result("tchunk_start_p50", pct(tstarts, 0.50); unit="us")
    result("tchunk_start_p99", pct(tstarts, 0.99); unit="us")
    result("tregion_ramp_p50", pct(tramps, 0.50); unit="us")
    result("tregion_ramp_p99", pct(tramps, 0.99); unit="us")
    result("tregion_wall_p50", pct(twalls, 0.50))
    result("tregion_wall_p99", pct(twalls, 0.99))

    pingpong_rtt(1000)  # warmup
    rtt = pingpong_rtt(20_000)
    result("pingpong_rtt_p50", pct(rtt, 0.50); unit="us")
    result("pingpong_rtt_p90", pct(rtt, 0.90); unit="us")
    result("pingpong_rtt_p99", pct(rtt, 0.99); unit="us")
    result("pingpong_rtt_max", maximum(rtt); unit="us")
end

main()
