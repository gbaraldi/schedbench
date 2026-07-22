# Ecosystem parallel-for comparison: Base @threads vs OhMyThreads
# (dynamic + greedy schedulers) vs AcceleratedKernels.foreachindex vs
# Polyester.@batch, across the three regimes that expose scheduling policy:
#   uniform_cheap — overhead-dominated fine-grained loop
#   few_long      — 32 iterations x ~1ms (count-based grain's failure case)
#   skewed        — cost ramps with index (static chunking's failure case)
include(joinpath(@__DIR__, "..", "common.jl"))

using OhMyThreads: tforeach, DynamicScheduler, GreedyScheduler
import AcceleratedKernels as AK
using Polyester: @batch

# --- uniform cheap: axpy 10k ------------------------------------------------
function uni_threads!(y, x)
    @threads for i in eachindex(y)
        @inbounds y[i] = 2.0f0 * x[i] + y[i]
    end
end
uni_omt!(y, x, sched) = tforeach(eachindex(y); scheduler=sched) do i
    @inbounds y[i] = 2.0f0 * x[i] + y[i]
end
uni_ak!(y, x) = AK.foreachindex(y) do i
    @inbounds y[i] = 2.0f0 * x[i] + y[i]
end
function uni_batch!(y, x)
    @batch for i in eachindex(y)
        @inbounds y[i] = 2.0f0 * x[i] + y[i]
    end
end

# --- work bodies for the long/skewed regimes ---------------------------------
# spin for roughly `units` of calibrated busy-work
function burn(units::Int)
    x = 0.0
    for _ in 1:units
        x += sin(x) + 1.0
    end
    x
end

# --- runners ------------------------------------------------------------------
function main()
    # uniform cheap
    y = zeros(Float32, 10_000); x = rand(Float32, 10_000)
    result("uniform_threads", 1000 * bench(uni_threads!, y, x; reps=5); unit="us")
    result("uniform_omt_dynamic", 1000 * bench(uni_omt!, y, x, DynamicScheduler(); reps=5); unit="us")
    result("uniform_omt_greedy", 1000 * bench(uni_omt!, y, x, GreedyScheduler(); reps=5); unit="us")
    result("uniform_ak", 1000 * bench(uni_ak!, y, x; reps=5); unit="us")
    result("uniform_batch", 1000 * bench(uni_batch!, y, x; reps=5); unit="us")

    GC.gc(); sleep(0.3)  # settle: previous section's workers park

    # few long iterations: 32 x ~1ms
    units = 40_000  # ~1ms of sin() on this machine
    out = zeros(32)
    fl_threads!(out) = @threads for i in eachindex(out); out[i] = burn(units); end
    fl_omt!(out, sched) = tforeach(i -> (out[i] = burn(units)), eachindex(out); scheduler=sched)
    fl_ak!(out) = AK.foreachindex(i -> (out[i] = burn(units)), out)
    fl_batch!(out) = @batch for i in eachindex(out); out[i] = burn(units); end
    result("fewlong_threads", bench(fl_threads!, out; reps=3))
    result("fewlong_omt_dynamic", bench(fl_omt!, out, DynamicScheduler(); reps=3))
    result("fewlong_omt_greedy", bench(fl_omt!, out, GreedyScheduler(); reps=3))
    result("fewlong_ak", bench(fl_ak!, out; reps=3))
    result("fewlong_batch", bench(fl_batch!, out; reps=3))

    GC.gc(); sleep(0.3)

    # skewed: 1000 iterations, cost proportional to index (last chunk carries
    # the bulk under consecutive static chunking)
    outs = zeros(1_000)
    sk_threads!(outs) = @threads for i in eachindex(outs); outs[i] = burn(4 * i); end
    sk_threads_greedy!(outs) = @threads :greedy for i in eachindex(outs); outs[i] = burn(4 * i); end
    sk_omt!(outs, sched) = tforeach(i -> (outs[i] = burn(4 * i)), eachindex(outs); scheduler=sched)
    sk_ak!(outs) = AK.foreachindex(i -> (outs[i] = burn(4 * i)), outs)
    sk_batch!(outs) = @batch for i in eachindex(outs); outs[i] = burn(4 * i); end
    result("skewed_threads", bench(sk_threads!, outs; reps=3))
    result("skewed_threads_greedy", bench(sk_threads_greedy!, outs; reps=3))
    result("skewed_omt_dynamic", bench(sk_omt!, outs, DynamicScheduler(); reps=3))
    result("skewed_omt_greedy", bench(sk_omt!, outs, GreedyScheduler(); reps=3))
    result("skewed_ak", bench(sk_ak!, outs; reps=3))
    result("skewed_batch", bench(sk_batch!, outs; reps=3))
end

main()
