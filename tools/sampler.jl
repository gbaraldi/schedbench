# Timeline sampler: queued-but-unclaimed tasks vs spinner count vs running
# threads, sampled from a sticky task on the interactive pool so the default
# pool's ramp cannot stall the sampler. Run with -t 16,1.
using Base.Threads

qdepth() = sum(Int(h.ntasks) for h in Base.Partr.heaps[2]; init=0) +
           sum(Int(h.ntasks) for h in Base.Partr.heaps[1]; init=0)
nspin() = ccall(:jl_sched_n_spinning, Int32, (Int8,), 0)
nrun() = ccall(:jl_sched_n_running, Int32, ())

const NSAMP = 400_000
const ts = Vector{Int64}(undef, NSAMP)
const qd = Vector{Int16}(undef, NSAMP)
const sp = Vector{Int16}(undef, NSAMP)
const rn = Vector{Int16}(undef, NSAMP)
const nsamples = Ref(0)
const sampling = Ref(true)
const started = Ref(false)

function sampler()
    i = 0
    while !started[]
        ccall(:jl_cpu_pause, Cvoid, ())
    end
    while sampling[] && i < NSAMP
        i += 1
        ts[i] = time_ns()
        qd[i] = qdepth()
        sp[i] = nspin()
        rn[i] = nrun()
    end
    nsamples[] = i
end

const N = 4_000_000
const A = zeros(N); const B = rand(N); const C = rand(N)
function triad()
    @threads for i in 1:N
        @inbounds A[i] = B[i] + 3.0 * C[i]
    end
end

if get(ENV, "JULIA_SURPLUS", "0") == "1"
    ccall(:jl_set_surplus_wake, Cvoid, (Cint,), 1)
end
triad(); triad()  # warmup

samp = Task(sampler)
samp.sticky = true
ccall(:jl_set_task_tid, Cint, (Any, Cint), samp, nthreads(:default))  # interactive tid
schedule(samp)
sleep(0.3)   # let the default pool park (past the 100µs threshold)
started[] = true
t0 = time_ns()
triad()      # ONE region from fully-parked state
t1 = time_ns()
sampling[] = false
wait(samp)

# report: bucket the region window into 25µs bins
n = nsamples[]
println("region wall: $(round((t1-t0)/1e3, digits=1)) µs, samples: $n")
lo, hi = t0 - 50_000, t1 + 20_000
println(" t(µs)  queued  spinners  running   (25µs bins, max within bin)")
bin = 25_000
for b in lo:bin:hi
    idx = findall(i -> b <= ts[i] < b + bin, 1:n)
    isempty(idx) && continue
    println(rpad(round(Int, (b - t0)/1e3), 7), rpad(maximum(qd[idx]), 8),
            rpad(maximum(sp[idx]), 10), maximum(rn[idx]))
end
