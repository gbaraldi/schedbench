# Align two or more bench.jl TSVs and print deltas vs the first (baseline).
#   julia compare.jl base.tsv new.tsv [more.tsv...]
# Aggregates min over reps per (name, threads). Deltas beyond the ~15% noise
# threshold (established empirically for this machine) are marked; smaller
# ones are probably not real unless consistent across reps and days.

function load(f)
    d = Dict{Tuple{String,Int},Float64}()
    unit = Dict{Tuple{String,Int},String}()
    for l in eachline(f)
        (startswith(l, "#") || startswith(l, "name\t")) && continue
        p = split(l, "\t")
        length(p) >= 6 || continue
        k = (String(p[1]), parse(Int, p[3]))
        v = parse(Float64, p[5])
        d[k] = min(get(d, k, Inf), v)
        unit[k] = String(p[6])
    end
    return d, unit
end

length(ARGS) >= 2 || error("usage: compare.jl base.tsv new.tsv [more...]")
base, units = load(ARGS[1])
others = [load(f)[1] for f in ARGS[2:end]]
names = [basename(f) for f in ARGS]

keys_sorted = sort(collect(keys(base)); by = k -> (k[2], k[1]))
w = maximum(length(k[1]) for k in keys_sorted) + 2
println(rpad("benchmark", w), rpad("t", 5), rpad(names[1], 12),
        join((rpad(n, 22) for n in names[2:end])))
lastt = -1
for k in keys_sorted
    global lastt
    k[2] != lastt && (lastt = k[2]; println("-"^(w + 5 + 12 + 22 * length(others))))
    b = base[k]
    row = rpad(k[1], w) * rpad(string(k[2]), 5) *
          rpad(string(round(b, sigdigits=4)) * " " * units[k], 12)
    for o in others
        if haskey(o, k)
            v = o[k]; d = 100 * (v / b - 1)
            mark = abs(d) >= 15 ? (d > 0 ? " ▲" : " ▼") : "  "
            row *= rpad(string(round(v, sigdigits=4)) * " (" *
                        (d >= 0 ? "+" : "") * string(round(d, digits=0)) * "%)" * mark, 22)
        else
            row *= rpad("—", 22)
        end
    end
    println(row)
end
println("\n▲/▼ = beyond the ±15% noise threshold; smaller deltas need reps + same-day baseline.")
