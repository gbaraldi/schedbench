# Ports of tokio's benches/rt_multi_threaded.rs scheduler benchmarks (the
# set behind the "10x scheduler" comparison), shapes ours lacks: a serial
# tail-spawn chain, contended yielding, mass short-lived handoff pairs, and
# injection onto an already-busy pool.
include(joinpath(@__DIR__, "..", "common.jl"))

# chained_spawn: each task spawns the next; measures the spawn->run handoff
# compounded ITER times with no parallelism to hide it.
function chain(n::Int, done::Channel{Nothing})
    if n == 0
        put!(done, nothing)
    else
        Threads.@spawn chain(n - 1, done)
    end
    return nothing
end

function chained_spawn(iter)
    done = Channel{Nothing}(1)
    Threads.@spawn chain(iter, done)
    take!(done)
end

# yield_many: TASKS tasks each yield NUM_YIELD times, concurrently.
function yield_many(tasks, nyield)
    @sync for _ in 1:tasks
        Threads.@spawn for _ in 1:nyield
            yield()
        end
    end
end

# ping_pong: NUM_PINGS concurrent short-lived pairs; each ping spawns a
# coordinator and a partner exchanging one message each way.
function ping_pong(npings)
    rem = Threads.Atomic{Int}(npings)
    done = Channel{Nothing}(1)
    Threads.@spawn for _ in 1:npings
        Threads.@spawn begin
            c1 = Channel{Nothing}(1); c2 = Channel{Nothing}(1)
            Threads.@spawn (take!(c1); put!(c2, nothing))
            put!(c1, nothing)
            take!(c2)
            Threads.atomic_sub!(rem, 1) == 1 && put!(done, nothing)
        end
    end
    take!(done)
end

# spawn_many_remote_busy: keep the pool busy with yielding tasks that stall
# ~10us between yields, then measure spawning a wave from outside.
stall(us) = (t0 = time_ns(); while time_ns() - t0 < us * 1000; end)

function spawn_busy(nspawn)
    flag = Threads.Atomic{Bool}(true)
    hogs = [Threads.@spawn while flag[]
                yield()
                stall(10)
            end for _ in 1:(2 * NT)]
    wave(n) = @sync for _ in 1:n
        Threads.@spawn nothing
    end
    r = bench(wave, nspawn)
    flag[] = false
    foreach(wait, hogs)
    return r
end

banner()
chained_spawn(100)  # warmup
result("chained_spawn_1k", bench(chained_spawn, 1_000))
yield_many(8, 100)
result("yield_many_200x1k", bench(n -> yield_many(200, n), 1_000))
ping_pong(100)
result("ping_pong_1k_pairs", bench(ping_pong, 1_000))
result("spawn_busy_10k", spawn_busy(10_000))
