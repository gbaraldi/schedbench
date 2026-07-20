# Fairness and scheduling-delay distribution, after kpamnany's
# MultithreadingBenchmarks.jl (task-ttc, prefix). Everything else in this
# suite reports best-case times; these report the tail: a scheduler with an
# aggressive LIFO slot can be fast on every mean and still starve individual
# tasks (the LIFO_CAP / fairness-tick tradeoff).
include(joinpath(@__DIR__, "..", "common.jl"))

# task-ttc: N tasks admitted through a semaphore, each ~1ms of yielding busy
# work. Reports sojourn time (spawn -> completion) percentiles: p99/max
# measure how long a runnable task can be left behind.
function ttc(ntasks, admit)
    sem = Base.Semaphore(admit)
    sojourn = Vector{Float64}(undef, ntasks)
    @sync for i in 1:ntasks
        t0 = time_ns()
        Threads.@spawn begin
            Base.acquire(sem) do
                h = UInt64(i)
                for k in 1:20
                    for j in 1:5_000
                        h = hash(j, h)
                    end
                    yield()
                end
                sojourn[i] = (time_ns() - t0) / 1e6
                h == 0 && error("unreachable")
            end
        end
    end
    sort!(sojourn)
    return sojourn[end ÷ 2], sojourn[99 * end ÷ 100], sojourn[end]
end

# prefix-sum barrier chain: 2*log2(n) dependent @sync regions; per-region
# latency compounds through real dependencies (unlike tiny_regions, the
# barriers are load-bearing).
function prefix!(y::Vector{Int})
    l = length(y)
    k = ceil(Int, log2(l))
    chunk(r) = Iterators.partition(r, max(1, length(r) ÷ NT))
    for j in 1:k
        @sync for is in chunk(2^j:2^j:min(l, 2^k))
            Threads.@spawn @inbounds for i in is
                y[i] = y[i - 2^(j - 1)] + y[i]
            end
        end
    end
    for j in (k - 1):-1:1
        @sync for is in chunk(3 * 2^(j - 1):2^j:min(l, 2^k))
            Threads.@spawn @inbounds for i in is
                y[i] = y[i - 2^(j - 1)] + y[i]
            end
        end
    end
    return y
end

banner()
ttc(500, 100)  # warmup
p50, p99, mx = ttc(5_000, 100)
result("ttc_5k_sojourn_p50", p50)
result("ttc_5k_sojourn_p99", p99)
result("ttc_5k_sojourn_max", mx)
const A = rand(Int, 1_000_000)
result("prefix_1M", bench(prefix!, A))
