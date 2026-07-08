# Fork-join compute benchmarks (cilkbench-style): recursive spawn trees,
# skewed work needing steal rebalancing, and barrier-per-sweep stencil.
include(joinpath(@__DIR__, "..", "common.jl"))

function fib(n::Int)
    n <= 1 && return n
    t = @spawn fib(n - 2)
    return fib(n - 1) + fetch(t)::Int
end

# nqueens: count solutions, spawning per branch down to a depth cutoff
function nqueens_ok(q::Vector{Int8}, n::Int)
    for i in 1:(n - 1)
        d = q[n] - q[i]
        (d == 0 || abs(d) == n - i) && return false
    end
    return true
end

function nqueens(N::Int, q::Vector{Int8}, row::Int, spawndepth::Int)
    row == N && return 1
    if spawndepth <= 0
        cnt = 0
        for col in Int8(1):Int8(N)
            q2 = copy(q); q2[row + 1] = col
            nqueens_ok(q2, row + 1) && (cnt += nqueens(N, q2, row + 1, 0))
        end
        return cnt
    end
    ts = Task[]
    for col in Int8(1):Int8(N)
        q2 = copy(q); q2[row + 1] = col
        nqueens_ok(q2, row + 1) && push!(ts, @spawn nqueens(N, q2, row + 1, spawndepth - 1))
    end
    return sum(Int[fetch(t)::Int for t in ts]; init=0)
end
nqueens(N) = nqueens(N, zeros(Int8, N), 0, 4)

# cilksort: parallel merge sort, serial cutoff
function pmergesort!(v::AbstractVector{T}, buf::AbstractVector{T}, cutoff::Int) where {T}
    n = length(v)
    if n <= cutoff
        sort!(v)
        return
    end
    mid = n >> 1
    l = view(v, 1:mid); r = view(v, (mid + 1):n)
    bl = view(buf, 1:mid); br = view(buf, (mid + 1):n)
    t = @spawn pmergesort!(l, bl, cutoff)
    pmergesort!(r, br, cutoff)
    wait(t)
    copyto!(buf, v)
    i = 1; j = mid + 1; k = 1
    @inbounds while i <= mid && j <= n
        if buf[i] <= buf[j]
            v[k] = buf[i]; i += 1
        else
            v[k] = buf[j]; j += 1
        end
        k += 1
    end
    @inbounds while i <= mid
        v[k] = buf[i]; i += 1; k += 1
    end
    @inbounds while j <= n
        v[k] = buf[j]; j += 1; k += 1
    end
    return
end

function cilksort(data::Vector{Float64})
    v = copy(data)
    pmergesort!(v, similar(v), 1 << 15)
    return v[1]
end

# skewed work: task i busy-computes ~i^2 units; stealing must rebalance
function imbalance(ntasks::Int, units::Int)
    sink = zeros(Float64, ntasks * 8)
    @sync for i in 1:ntasks
        @spawn begin
            acc = 0.0
            for j in 1:(units * i * i)
                acc += sin(j * 1e-3)
            end
            sink[i * 8] = acc
        end
    end
    return sum(sink)
end

# iterative stencil: one fork-join barrier per sweep, nthreads row-band tasks
function stencil(iters::Int, n::Int)
    a = zeros(Float64, n, n); b = zeros(Float64, n, n)
    a[1, :] .= 1.0
    band = cld(n - 2, NT)
    for _ in 1:iters
        @sync for lo in 2:band:(n - 1)
            hi = min(lo + band - 1, n - 1)
            @spawn @inbounds for j in 2:(n - 1), i in lo:hi
                b[i, j] = 0.25 * (a[i-1, j] + a[i+1, j] + a[i, j-1] + a[i, j+1])
            end
        end
        a, b = b, a
    end
    return a[2, 2]
end


const sortdata = rand(Float64, 8_000_000)
banner()
result("fib24", bench(fib, 24))
result("nqueens12", bench(nqueens, 12))
result("cilksort8M", bench(cilksort, sortdata))
result("imbalance_256", bench(imbalance, 256, 8))
result("stencil_100x512", bench(stencil, 100, 512))
