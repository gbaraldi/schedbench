# Suite orchestrator. Runs each benchmark group in a FRESH julia process per
# thread count (groups must not share a process: scheduler state, GC pressure
# and spinner population from one benchmark contaminate the next), collects
# RESULT lines, and writes a TSV with provenance in the header.
#
#   julia bench.jl --julia PATH [--groups a,b|all] [--threads 8,32]
#                  [--reps 2] [--tag NAME] [--timeout 900]
#
# Compare runs with compare.jl. Rule of thumb from developing this suite:
# differences under ~15% need multiple reps AND a same-day baseline to mean
# anything; never compare against TSVs recorded on a different day.

const GROUPS = ["throughput", "regions", "messaging", "latency", "producers", "fairness", "tokiostyle"]

function parseargs()
    opt = Dict{String,String}("julia" => "julia", "groups" => "all",
        "threads" => "8,32", "reps" => "2", "tag" => "run", "timeout" => "900")
    i = 1
    while i <= length(ARGS)
        a = ARGS[i]
        startswith(a, "--") || error("unexpected arg $a")
        opt[a[3:end]] = ARGS[i + 1]
        i += 2
    end
    return opt
end

function main()
    opt = parseargs()
    groups = opt["groups"] == "all" ? GROUPS : split(opt["groups"], ",")
    threads = parse.(Int, split(opt["threads"], ","))
    reps = parse(Int, opt["reps"])
    jl = opt["julia"]
    dir = @__DIR__
    out = joinpath(dir, "results",
        "$(opt["tag"])-$(replace(string(now_compact()), ":" => "")).tsv")
    commit = try
        readchomp(pipeline(`$jl -e 'print(Base.GIT_VERSION_INFO.commit_short)'`; stderr=devnull))
    catch; "?"; end
    open(out, "w") do io
        println(io, "# schedbench results  tag=", opt["tag"])
        println(io, "# julia: ", jl, " (", commit, ")")
        println(io, "# host: ", gethostname(), "  date: ", now_compact())
        println(io, "name\tgroup\tthreads\trep\tvalue\tunit")
        for t in threads, g in groups, rep in 1:reps
            file = joinpath(dir, "benchmarks", "$g.jl")
            print(stderr, "== $g  -t$t,1  rep$rep ... "); flush(stderr)
            t0 = time()
            lines = try
                readlines(pipeline(`timeout -k 10 $(opt["timeout"]) $jl -t $t,1 $file`;
                                   stderr=devnull))
            catch
                println(stderr, "FAILED/TIMEOUT"); continue
            end
            for l in lines
                startswith(l, "RESULT ") || continue
                p = split(l)
                println(io, p[2], "\t", g, "\t", t, "\t", rep, "\t", p[3], "\t",
                        length(p) >= 4 ? p[4] : "ms")
            end
            flush(io)
            println(stderr, round(time() - t0, digits=0), "s")
        end
    end
    println("wrote ", out)
end

now_compact() = (t = time(); Libc.strftime("%Y%m%d-%H%M%S", t))

main()
