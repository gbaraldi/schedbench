# Head-to-head against Polyester.@batch: per-region cost of back-to-back
# parallel-for regions across work sizes. Polyester keeps a pool of
# pre-spawned tasks parked on their own spin protocol, bypassing the
# scheduler's spawn/wake/sync path entirely — it is the standard "Base
# threading overhead is too high" comparison, so it measures exactly the
# path the wake-ledger work optimizes. Skips cleanly if Polyester is not
# installed in the suite environment.
include(joinpath(@__DIR__, "..", "common.jl"))

using Polyester: @batch

function axpy_threads!(iters::Int, y::Vector{Float32}, x::Vector{Float32})
    for _ in 1:iters
        @threads for i in eachindex(y)
            @inbounds y[i] = 2.0f0 * x[i] + y[i]
        end
    end
    return y[1]
end

function axpy_batch!(iters::Int, y::Vector{Float32}, x::Vector{Float32})
    for _ in 1:iters
        @batch for i in eachindex(y)
            @inbounds y[i] = 2.0f0 * x[i] + y[i]
        end
    end
    return y[1]
end

function axpy_serial!(iters::Int, y::Vector{Float32}, x::Vector{Float32})
    for _ in 1:iters
        @inbounds @simd for i in eachindex(y)
            y[i] = 2.0f0 * x[i] + y[i]
        end
    end
    return y[1]
end

function main()
    for (n, iters) in ((1_000, 20_000), (10_000, 5_000), (100_000, 1_000), (1_000_000, 200))
        y = zeros(Float32, n); x = rand(Float32, n)
        ts = bench(axpy_threads!, iters, y, x)
        tb = bench(axpy_batch!, iters, y, x)
        t0 = bench(axpy_serial!, iters, y, x)
        result("threads_n$(n)_perregion", 1000 * ts / iters; unit="us")
        result("batch_n$(n)_perregion", 1000 * tb / iters; unit="us")
        result("serial_n$(n)_perregion", 1000 * t0 / iters; unit="us")
    end
end

main()
