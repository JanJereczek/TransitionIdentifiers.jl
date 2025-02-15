using Revise
using TransitionIdentifiers
using Test
using DifferentialEquations
using CUDA

###############################
# Utils
###############################

@testset "reshaping residuals" begin
    dims = collect(2:5)
    X = rand(dims...)
    R = structured_residual(X, verbose=false)
    Rf = flatten_residual(R)
    Rr = reshape_residual(Rf)
    @test sum(Rr .== X) == prod(dims)

    Xgpu = CuArray(X)
    R = structured_residual(Xgpu, verbose=false)
    Rf = flatten_residual(R)
    Rr = reshape_residual(Rf)
    @test sum(Array(Rr) .== X) == prod(dims)
end

@testset "placeholding dimensions" begin
    X = rand(2,2,2,2)
    placeholder_spacedims = get_placeholder_spacedims(X)
    @test sum(X[:, :, :, 1] .== X[placeholder_spacedims...,1]) == prod(size(X)[1:3])
end

###############################
# Correct computation of statistical moments
###############################

#=
Notice:
Statistical estimator are often biased when formulated in a natural way.
Biases however do not influence the trends, which are the gist of transition indicators.
Nonetheless, the moments implemented here are not biased (if so, it is explicitly specified in the function name).

Here we perform the tests on a uniform distribution on [a, b] = [0, 1].
For this distribution, it holds:
- Mean: 0.5
- Variance: 1/12 (b-a) = 1/12
- Skewness: 0
- Excess kurtosis: -6/5
=#

function create_random_array(;T=Float32, n=100_000)
    x = rand(T, n)
    X = reshape(x, (1,n))
    Xgpu = CuArray(X)
    return x, X, Xgpu
end

@testset "mean" begin
    
    x, X, Xgpu = create_random_array()
    @test isapprox(mean_lastdim(x)[1], 0.5, atol = 1e-3)
    @test isapprox(mean_lastdim(X)[1,1], 0.5, atol = 1e-3)
    @test isapprox(Array(mean_lastdim(Xgpu))[1,1], 0.5, atol = 1e-3)
end

@testset "variance" begin
    x, X, Xgpu = create_random_array()
    @test isapprox(var(x)[1], 1/12, atol = 1e-3)
    @test isapprox(var(X)[1,1], 1/12, atol = 1e-3)
    @test isapprox(Array(var(Xgpu))[1,1], 1/12, atol = 1e-3)
end

@testset "skewness" begin
    x, X, Xgpu = create_random_array()
    @test isapprox(skw(x)[1], 0, atol = 5e-3)
    @test isapprox(skw(X)[1,1], 0, atol = 5e-3)
    @test isapprox(Array(skw(Xgpu))[1,1], 0, atol = 5e-3)
end

@testset "kurtosis" begin
    x, X, Xgpu = create_random_array()
    @test isapprox(krt(x)[1], -6/5, atol = 1e-3)
    @test isapprox(krt(X)[1,1], -6/5, atol = 1e-3)
    @test isapprox(Array(krt(Xgpu))[1,1], -6/5, atol = 1e-3)
end

###############################
# Analytic AR1 regression
###############################

function f_linear!(dx, x, p, t)
    dx[1] = p[1] * x[1]
end

function g_whitenoise!(dx, x, p, t)
    dx[1] = p[2]
end

function generate_ar1(x0::Vector{T}, p::Vector{T}, t::Vector{T}) where {T}
    tspan = extrema(t)
    prob = SDEProblem(f_linear!, g_whitenoise!, x0, tspan, p)
    sol = solve(prob, EM(), dt=t[2]-t[1])
    return hcat(sol.(t)...)
end

@testset "ar1_whitenoise" begin
    T = Float32
    dt = T(1e-2) 
    t = collect(T(0):dt:T(10))
    p = [-rand(T), T(0.1)]      # λ (make it random ), σ
    x0 = [T(1)]
    θ = exp(dt * p[1])          # θ is time discrete equivalent of λ

    X = generate_ar1(x0, p, t)
    x = vec(X)
    Xgpu = CuArray(X)
    θ_est_vec = ar1_whitenoise(x)
    θ_est_mat = ar1_whitenoise(X)[1]
    θ_est_gpu = Array(ar1_whitenoise(Xgpu))[1]
    # θ_est_msk = Array( masked_ar1_whitenoise(xgpu) )
    # TODO: add the accelerated AR1

    @test isapprox(θ_est_vec, θ, atol = T(1e-3))
    @test isapprox(θ_est_mat, θ, atol = T(1e-3))
    @test isapprox(θ_est_gpu, θ, atol = T(1e-3))
    # @test isapprox(θ_est_msk, θ, atol = T(1e-3))
end

###############################
# Analytic estimation of Hurst exponent
###############################

# For random walk, the Hurst exponent is 0.5
function random_walk(T, n1, n2)
    return T.(cumsum(rand(n1, n2) .> .5, dims=2))
end

@testset "hurst_exponent" begin
    T = Float32
    n1, n2 = 10, 100_000
    X = random_walk(T, n1, n2)
    H = hurst_exponent(X)
    @test sum( isapprox.(H, 0.5, atol = 1e-2) ) == n1
end

###############################
# Linear regression
###############################

function generate_affine_data(t::Vector{T}, nr::Int) where {T}
    Y = fill(T(NaN), (nr, length(t)))   # init test data.
    W = 10 .* randn(2, nr)              # random parameters of affine function.
    for i in 1:nr
        Y[i, :] = W[1, i] .* t .+ W[2, i]
    end
    return Y, W
end

@testset "ridge_regression" begin
    T = Float32
    dt = T(1e-2) 
    t = collect(T(0):dt:T(10))
    nr = 10                         # number of tested regressions.
    Y, W = generate_affine_data(t, nr)
    Wcpu = ridge_regression(Y, t)
    Wgpu = Array( ridge_regression(CuArray(Y), t) )
    @test sum(isapprox.(W, Wcpu, atol = T(1e-5))) == length(W)
    @test sum(isapprox.(W, Wgpu, atol = T(1e-5))) == length(W)
end

###############################
# Sliding functions
###############################

@testset "grow_window" begin
    T = Float32
    nrows, ncols = 10, 50
    X = ones(T, nrows, ncols)
    t = collect(1f0:size(X,2))
    p = get_windowing_params([1, 2, 1])
    sum2(X, t) = sum(X, dims=2)
    Y = grow_window(X, t, p, sum2, left_wndw )
    Z = repeat( (2*p.Nwndw+1:p.Nstrd:ncols)', outer=(nrows, 1) )
    @test sum(Y .== Z) == prod(size(Y))
end

###############################
# Percentile computation
###############################

@testset "significance" begin
    T = Float32
    nx, ns, nt = 2, 100, 10         # n° of variables, surrogates per variable, time steps per variable.
    sur_stat = repeat( collect(1:ns) * ones(T, nt)', outer=(2,1) )
    ref_stat = round.( rand(T, nx, nt) * 100 )
    significance = percentile_significance(ref_stat, sur_stat, ns, nx)
    count_correct = sum(isapprox.(significance .* 100 .+ 1, ref_stat))
    @test isapprox(nx * nt, count_correct)
end