# Spawn-throughput scaling in producer count. All runtimes we measured
# (Julia, Go, Tokio) are producer-bound on this workload: throughput is flat
# in worker count and scales with producers, so this is the true spawn-path
# rate benchmark; single-producer configs measure spawn cost, high-P configs
# measure the aggregate retire ceiling. Cross-runtime equivalents in
# crossruntime/{gospawn.go, tokiospawn}.
include(joinpath(@__DIR__, "..", "common.jl"))

const PER = 25_000
const TOTAL = 2_000_000

wave(per) = @sync for _ in 1:per
    Threads.@spawn nothing
end

produce(waves) = for _ in 1:waves; wave(PER); end

function run_pool_producers(P)
    waves = TOTAL ÷ (P * PER)
    return @elapsed @sync for _ in 1:P
        Threads.@spawn produce(waves)
    end
end

banner()
produce(4); run_pool_producers(1)  # warmup
result("prod_main", TOTAL / (@elapsed produce(TOTAL ÷ PER)) / 1e6; unit="Mtask/s")
for P in (1, 2, 4, 8, 2 * NT)
    result("prod_P$P", TOTAL / run_pool_producers(P) / 1e6; unit="Mtask/s")
end
