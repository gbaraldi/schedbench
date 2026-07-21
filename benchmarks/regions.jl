# Fine-grained parallel-for (Polyester-style): task overhead against tiny
# work bodies, and back-to-back small @sync regions (per-region latency).
include(joinpath(@__DIR__, "..", "common.jl"))

# axpy in many small chunk-tasks (task overhead vs 2 flops/element)
function pfor_fine(y::Vector{Float32}, x::Vector{Float32}, chunk::Int)
    n = length(y)
    @sync for lo in 1:chunk:n
        hi = min(lo + chunk - 1, n)
        @spawn @inbounds for i in lo:hi
            y[i] = 2.0f0 * x[i] + y[i]
        end
    end
    return y[1]
end

# many consecutive tiny parallel regions (the @batch-in-a-loop pattern):
# per-region cost = spawn + wake + sync latency
function tiny_regions(iters::Int, y::Vector{Float32}, x::Vector{Float32})
    n = length(y)
    chunk = cld(n, NT)
    for _ in 1:iters
        @sync for lo in 1:chunk:n
            hi = min(lo + chunk - 1, n)
            @spawn @inbounds for i in lo:hi
                y[i] = 2.0f0 * x[i] + y[i]
            end
        end
    end
    return y[1]
end


const xs = rand(Float32, 1_000_000); const ys = rand(Float32, 1_000_000)
const xs_small = rand(Float32, 65_536); const ys_small = rand(Float32, 65_536)
banner()
result("pfor_fine_1M_c2048", bench(pfor_fine, ys, xs, 2048))
result("pfor_fine_1M_c256", bench(pfor_fine, ys, xs, 256))
result("tiny_regions_500x64k", bench(tiny_regions, 500, ys_small, xs_small))

# Back-to-back medium (~2-10ms) @threads regions over large arrays (the PRK
# nstream shape). Chunk-completion skew at this granularity exceeds the spin
# threshold, so workers park in every inter-region gap and the wake ramp is
# paid per region; micro regions (above) and long regions both hide this.
const NB = 20_000_000
const bA = zeros(NB); const bB = fill(2.0, NB); const bC = fill(2.0, NB)
function triad_regions(iters)
    for _ in 1:iters
        Threads.@threads for i in 1:NB
            @inbounds bA[i] += bB[i] + 3.0 * bC[i]
        end
    end
end
let t = (triad_regions(3); minimum((@elapsed triad_regions(10)) for _ in 1:3))
    result("triad_regions_GBps", 4 * 8 * NB * 10 / t / 1e9; unit="GB/s")
end
