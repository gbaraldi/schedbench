# Unicode plots for bench.jl TSVs (UnicodePlots.jl; run with --project=<suite>).
#
#   julia --project=. plot.jl base.tsv new.tsv          speedup bars per thread count
#   julia --project=. plot.jl a.tsv b.tsv [c.tsv...]    producer-scaling lines, if present
#
# Speedup is oriented so >1x is always "new is better": base/new for time
# units (ms/ns), new/base for rates (Mtask/s). Faster and slower benchmarks
# are split into separately labeled sections so polarity never rides on
# color alone; bars carry direct value labels.
using UnicodePlots

function load(f)
    d = Dict{Tuple{String,Int},Float64}()
    unit = Dict{Tuple{String,Int},String}()
    for l in eachline(f)
        (startswith(l, "#") || startswith(l, "name\t")) && continue
        p = split(l, "\t")
        length(p) >= 6 || continue
        k = (String(p[1]), parse(Int, p[3]))
        d[k] = min(get(d, k, Inf), parse(Float64, p[5]))
        unit[k] = String(p[6])
    end
    return d, unit
end

israte(u) = occursin("/s", u)
speedup(b, n, u) = israte(u) ? n / b : b / n

function speedup_bars(basefile, newfile)
    base, units = load(basefile)
    new, _ = load(newfile)
    for t in sort(unique(k[2] for k in keys(base)))
        pairs = [(k[1], speedup(base[k], new[k], units[k]))
                 for k in keys(base) if k[2] == t && haskey(new, k)]
        isempty(pairs) && continue
        sort!(pairs; by = last, rev = true)
        faster = [(n, round(s, digits=2)) for (n, s) in pairs if s >= 1.005]
        slower = sort([(n, round(1 / s, digits=2)) for (n, s) in pairs if s < 0.995];
                      by = last, rev = true)
        println("\n== $t threads: $(basename(newfile)) vs $(basename(basefile)) ==")
        if !isempty(faster)
            show(barplot(first.(faster), last.(faster);
                 title = "faster (speedup x)", color = :green, maximum = 4.0))
            println()
        end
        if !isempty(slower)
            show(barplot(first.(slower), last.(slower);
                 title = "slower (slowdown x)", color = :red, maximum = 4.0))
            println()
        end
        nc = count(p -> 0.995 <= p[2] < 1.005, pairs)
        nc > 0 && println("($nc benchmark(s) within +-0.5%)")
    end
end

function producer_lines(files)
    plt = nothing
    for (i, f) in enumerate(files)
        d, _ = load(f)
        ks = [k for k in keys(d) if startswith(k[1], "prod_P")]
        isempty(ks) && continue
        for t in sort(unique(k[2] for k in ks))
            ps = sort([(parse(Int, k[1][7:end]), d[k]) for k in ks if k[2] == t])
            xs = first.(ps); ys = last.(ps)
            lbl = "$(basename(f)) t$t"
            if plt === nothing
                plt = lineplot(xs, ys; name = lbl, title = "spawn throughput vs producers",
                               xlabel = "producers", ylabel = "Mtask/s", canvas = DotCanvas,
                               width = 60, height = 12)
            else
                lineplot!(plt, xs, ys; name = lbl)
            end
        end
    end
    plt === nothing || (show(plt); println())
end

length(ARGS) >= 2 || error("usage: plot.jl base.tsv new.tsv [more.tsv...]")
speedup_bars(ARGS[1], ARGS[2])
producer_lines(ARGS)
