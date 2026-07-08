# Shared measurement helpers. Every benchmark file includes this and prints
# machine-readable lines:  RESULT <name> <value> <unit>
using Base.Threads

const NT = nthreads(:default)

# best-of-reps wall time in ms; warmup run first, GC quiesced between reps
function bench(f::F, args...; reps::Int=3) where {F}
    f(args...)
    best = Inf
    for _ in 1:reps
        GC.gc(false)
        t0 = time_ns()
        f(args...)
        best = min(best, (time_ns() - t0) / 1e6)
    end
    return best
end

# ns/op over n inner iterations, best of 5 (for sub-µs paths)
function bench_ns(f::F, n::Int) where {F}
    f()
    best = Inf
    for _ in 1:5
        t0 = time_ns()
        for _ in 1:n
            f()
        end
        best = min(best, (time_ns() - t0) / n)
    end
    return best
end

result(name, v; unit="ms") =
    (println("RESULT ", name, " ", round(v, digits=3), " ", unit); flush(stdout))

banner() = println("# threads=", nthreads(), " default=", NT,
                   " interactive=", nthreads(:interactive))
