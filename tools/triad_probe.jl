# Back-to-back @threads triad regions, gated on a start file so bpftrace can
# attach before the measured phase. JULIA_SURPLUS=1 turns the wakep prototype on.
using Base.Threads

const N = 4_000_000
a = zeros(N); b = rand(N); c = rand(N)
const SCALAR = 3.0

function triad!(a, b, c)
    @threads for i in eachindex(a)
        @inbounds a[i] = b[i] + SCALAR * c[i]
    end
end

triad!(a, b, c)  # warmup/compile

if get(ENV, "JULIA_SURPLUS", "0") == "1"
    ccall(:jl_set_surplus_wake, Cvoid, (Cint,), 1)
end

gate = ARGS[1]
println("READY $(getpid())"); flush(stdout)
while !isfile(gate)
    sleep(0.05)
end

t = @elapsed for _ in 1:100
    triad!(a, b, c)
end
gbs = 100 * 3 * 8 * N / t / 1e9
println("triad: $(round(gbs, digits=1)) GB/s over $(round(t*1000, digits=1)) ms")
