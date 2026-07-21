using Base.Threads, Profile
ccall(:jl_set_surplus_wake, Cvoid, (Cint,), parse(Int, ARGS[1]))
const NB = 20_000_000
const bA = zeros(NB); const bB = fill(2.0, NB); const bC = fill(2.0, NB)
triad(iters) = for _ in 1:iters
    Threads.@threads for i in 1:NB
        @inbounds bA[i] += bB[i] + 3.0 * bC[i]
    end
end
triad(3)
Profile.init(n = 10^7, delay = 0.0005)
Profile.@profile_walltime triad(30)
data = Profile.fetch(include_meta = false)
lidict = Profile.getdict(data)
buckets = Dict{String,Int}(); total = 0
i = 1; n = length(data)
while i <= n
    j = i
    while j <= n && data[j] != 0; j += 1; end
    if j > i
        global total += 1
        cat = "other"
        for ip in view(data, i:j-1), fr in get(lidict, ip, [])
            f = String(fr.func); fl = String(fr.file)
            if occursin("uv_cond_wait", f) || f == "jl_task_get_next" || occursin("wait_forever", f)
                cat = "parked/scheduler-wait"; break
            elseif occursin("wallprof", fl) && occursin("macro expansion", f) || occursin("triad", f)
                cat = "triad work"; break
            elseif occursin("threading", fl) || occursin("task.jl", fl)
                cat = "task machinery"; break
            end
        end
        buckets[cat] = get(buckets, cat, 0) + 1
    end
    global i = j + 1
    while i <= n && data[i] == 0; global i += 1; end
end
println("surplus=", ARGS[1], " total_samples=", total)
for (k, v) in sort(collect(buckets); by=last, rev=true)
    println(rpad(k, 24), round(100v / total, digits=1), "%")
end
