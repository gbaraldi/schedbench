# Wake-path and messaging stress: mass spawn, channel handoffs, a token
# ring of parked tasks, and notify->all-resumed wake storms.
include(joinpath(@__DIR__, "..", "common.jl"))

function spawn_many(n::Int)
    c = Atomic{Int}(0)
    @sync for _ in 1:n
        @spawn atomic_add!(c, 1)
    end
    return c[]
end

function pingpong(iters::Int)
    c1 = Channel{Int}(0); c2 = Channel{Int}(0)
    t = @spawn for _ in 1:iters
        put!(c2, take!(c1))
    end
    for i in 1:iters
        put!(c1, i); take!(c2)
    end
    wait(t)
end

function token_ring(ntasks::Int, laps::Int)
    # buffered by 1 so the final put (which has no taker left) doesn't block
    chans = [Channel{Int}(1) for _ in 1:ntasks]
    ts = Task[]
    for i in 1:ntasks
        nxt = chans[i % ntasks + 1]
        cur = chans[i]
        t = @spawn for _ in 1:laps
            put!(nxt, take!(cur) + 1)
        end
        push!(ts, t)
    end
    put!(chans[1], 0)
    foreach(wait, ts)
    return ntasks * laps
end

# times only notify -> all-resumed; the parking phase is setup
function wake_storm(nwait::Int)
    e = Base.Event()
    c = Atomic{Int}(0)
    ts = [@spawn (wait(e); atomic_add!(c, 1)) for _ in 1:nwait]
    sleep(0.2)
    t0 = time_ns()
    notify(e)
    foreach(wait, ts)
    @assert c[] == nwait
    return (time_ns() - t0) / 1e6
end


banner()
result("spawn_many_100k", bench(spawn_many, 100_000))
result("pingpong_10k", bench(pingpong, 10_000))
result("token_ring_256x50", bench(token_ring, 256, 50))
begin
    wake_storm(2_000)   # warmup; times itself (notify -> drained)
    result("wake_storm_2k", minimum(wake_storm(2_000) for _ in 1:3))
end
