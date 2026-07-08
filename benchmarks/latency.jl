# Single-operation latency decomposition: raw switch, scheduler round trip,
# spawn+join in its variants (pinned / default / cross-pool), and the
# parked-consumer wake path. These are the numbers to compare against Go
# (gogo ~60ns, spawn+join ~270ns, wake ~1µs); see crossruntime/.
include(joinpath(@__DIR__, "..", "common.jl"))

const NOOP = () -> nothing

function raw_switch()   # yieldto ping-pong: pure ctx_switch, no scheduler
    main = current_task()
    other = Task(() -> while true; yieldto(main); end)
    yieldto(other)
    t0 = time_ns()
    for _ in 1:100_000
        yieldto(other)
    end
    return (time_ns() - t0) / 100_000 / 2
end

spawn_join() = wait(Threads.@spawn nothing)

function spawn_join_pinned()
    t = Task(NOOP)
    t.sticky = true
    ccall(:jl_set_task_tid, Cint, (Any, Cint), t, Threads.threadid() - 1)
    schedule(t)
    wait(t)
end

spawn_forget() = @sync for _ in 1:10_000   # producer-side cost, amortized
    Threads.@spawn nothing
end

# parked-consumer wake latency percentiles: producer sleeps so the consumer
# is futex-parked when the value arrives
function wake_percentiles(rounds)
    lat = Float64[]
    c = Channel{UInt64}(1); res = Channel{Nothing}(1)
    t = Threads.@spawn for t0 in c
        push!(lat, Float64(time_ns() - t0))
        put!(res, nothing)
    end
    for _ in 1:rounds
        Libc.systemsleep(200e-6)
        put!(c, time_ns())
        take!(res)
    end
    close(c); wait(t)
    sort!(lat)
    return lat[length(lat) ÷ 2], lat[length(lat) * 99 ÷ 100]
end

function suite(tag)
    result("$tag/task_alloc", bench_ns(() -> Task(NOOP), 200_000); unit="ns")
    result("$tag/yield_roundtrip", bench_ns(yield, 100_000); unit="ns")
    result("$tag/spawn_join_pinned", bench_ns(spawn_join_pinned, 20_000); unit="ns")
    result("$tag/spawn_join", bench_ns(spawn_join, 20_000); unit="ns")
    result("$tag/spawn_forget_per_task", bench_ns(spawn_forget, 5) / 10_000; unit="ns")
end

banner()
result("raw_ctx_switch", (raw_switch(); raw_switch()); unit="ns")
suite("main")                            # cross-pool when run with -tN,1
fetch(Threads.@spawn suite("worker"))    # same-pool
begin
    wake_percentiles(500)   # warmup
    p50, p99 = wake_percentiles(2_000)
    result("wake_parked_p50", p50; unit="ns")
    result("wake_parked_p99", p99; unit="ns")
end
