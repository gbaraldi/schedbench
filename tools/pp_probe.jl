using Base.Threads
function ppw(rounds)
    c1 = Channel{Int}(0); c2 = Channel{Int}(0)
    cons = Threads.@spawn for _ in 1:rounds; put!(c2, take!(c1)); end
    prod = Threads.@spawn begin
        t0 = time_ns(); for i in 1:rounds; put!(c1, i); take!(c2); end
        (time_ns() - t0) / 1e6
    end
    ms = fetch(prod); wait(cons); ms
end
ppw(1000)  # warmup
if get(ENV, "JULIA_SURPLUS", "0") == "1"
    ccall(:jl_set_surplus_wake, Cvoid, (Cint,), 1)
end
gate = ARGS[1]
println("READY $(getpid())"); flush(stdout)
while !isfile(gate); sleep(0.05); end
ms = ppw(20_000)
println("pingpong_workers: $(round(ms, digits=1)) ms")
