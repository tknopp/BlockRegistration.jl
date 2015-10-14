__precompile__()

module RegisterOptimize

using MathProgBase, Ipopt, AffineTransforms, Interpolations, ForwardDiff, FixedSizeArrays, IterativeSolvers
using RegisterCore, RegisterDeformation, RegisterMismatch, RegisterPenalty, RegisterFit
using RegisterDeformation: convert_to_fixed, convert_from_fixed
using Base.Test

import Base: *
import MathProgBase: SolverInterface

export
    auto_λ,
    fit_sigmoid,
    fixed_λ,
    initial_deformation,
    optimize!,
    optimize_rigid

"""
This module provides convenience functions for minimizing the mismatch
between images. It supports both rigid registration and deformable
registration.

The main functions are:

- `optimize_rigid`: iteratively improve a rigid transformation, given raw images
- `initial_deformation`: provide an initial guess based on mismatch quadratic fits
- `optimize!`: iteratively improve a deformation, given mismatch data
"""
RegisterOptimize


# Some conveniences for MathProgBase
abstract GradOnly <: SolverInterface.AbstractNLPEvaluator

function SolverInterface.initialize(d::GradOnly, requested_features::Vector{Symbol})
    for feat in requested_features
        if !(feat in [:Grad, :Jac])
            error("Unsupported feature $feat")
        end
    end
end
SolverInterface.features_available(d::GradOnly) = [:Grad, :Jac]


abstract GradOnlyBoundsOnly <: GradOnly

SolverInterface.eval_g(::GradOnlyBoundsOnly, g, x) = nothing
SolverInterface.jac_structure(::GradOnlyBoundsOnly) = Int[], Int[]
SolverInterface.eval_jac_g(::GradOnlyBoundsOnly, J, x) = nothing


abstract BoundsOnly <: SolverInterface.AbstractNLPEvaluator

SolverInterface.eval_g(::BoundsOnly, g, x) = nothing
SolverInterface.jac_structure(::BoundsOnly) = Int[], Int[]
SolverInterface.eval_jac_g(::BoundsOnly, J, x) = nothing


# Some necessary ForwardDiff extensions to make Interpolations work
Base.real(v::ForwardDiff.GradientNumber) = real(v.value)
Base.ceil(::Type{Int}, v::ForwardDiff.GradientNumber)  = ceil(Int, v.value)
Base.floor(::Type{Int}, v::ForwardDiff.GradientNumber) = floor(Int, v.value)

###
### Rigid registration from raw images
###
"""
`tform = optimize_rigid(fixed, moving, tform0, maxshift, [SD = eye];
[thresh=0, tol=1e-4, print_level=0])` optimizes a rigid transformation
(rotation + shift) to minimize the mismatch between `fixed` and
`moving`.

`tform0` is an initial guess.  Use `SD` if your axes are not uniformly
sampled, for example `SD = diagm(voxelspacing)` where `voxelspacing`
is a vector encoding the spacing along all axes of the image. `thresh`
enforces a certain amount of sum-of-squared-intensity overlap between
the two images; with non-zero `thresh`, it is not permissible to
"align" the images by shifting one entirely out of the way of the
other.
"""
function optimize_rigid(fixed, moving, A::AffineTransform, maxshift, SD = eye(ndims(A)); thresh=0, tol=1e-4, print_level=0)
    objective = RigidOpt(to_float(fixed, moving)..., SD, thresh)
    # Convert initial guess into parameter vector
    R = SD*A.scalefwd/SD
    rotp = rotationparameters(R)
    dx = A.offset
    p0 = [rotp; dx]
    T = eltype(p0)

    # Set up and run the solver
    solver = IpoptSolver(hessian_approximation="limited-memory",
                         print_level=print_level,
                         tol=tol)
    m = SolverInterface.model(solver)
    ub = T[fill(pi, length(p0)-length(maxshift)); [maxshift...]]
    SolverInterface.loadnonlinearproblem!(m, length(p0), 0, -ub, ub, T[], T[], :Min, objective)
    SolverInterface.setwarmstart!(m, p0)
    SolverInterface.optimize!(m)

    stat = SolverInterface.status(m)
    stat == :Optimal || warn("Solution was not optimal")
    p = SolverInterface.getsolution(m)
    fval = SolverInterface.getobjval(m)

    p2rigid(p, SD), fval
end

function p2rigid(p, SD)
    if length(p) == 1
        return AffineTransform([1], p)  # 1 dimension
    elseif length(p) == 3
        return AffineTransform(SD\(rotation2(p[1])*SD), p[2:end])    # 2 dimensions
    elseif length(p) == 6
        return AffineTransform(SD\(rotation3(p[1:3])*SD), p[4:end])  # 3 dimensions
    else
        error("Dimensionality not supported")
    end
end

to_float(A, B) = to_float(typeof(one(eltype(A)) - one(eltype(B))), A, B)
to_float{T<:AbstractFloat}(::Type{T}, A, B) = convert(Array{T}, A), convert(Array{T}, B)
to_float{T}(::Type{T}, A, B) = convert(Array{Float32}, A), convert(Array{Float32}, B)


###
### Rigid registration from raw images, MathProg interface
###
type RigidValue{N,A<:AbstractArray,I<:AbstractExtrapolation,SDT} <: SolverInterface.AbstractNLPEvaluator
    fixed::A
    wfixed::A
    moving::I
    SD::SDT
    thresh
end

function RigidValue{T<:Real}(fixed::AbstractArray, moving::AbstractArray{T}, SD, thresh)
    f = copy(fixed)
    fnan = isnan(f)
    f[fnan] = 0
    m = copy(moving)
    mnan = isnan(m)
    m[mnan] = 0
    metp = extrapolate(interpolate!(m, BSpline(Quadratic(InPlace())), OnCell()), NaN)
    RigidValue{ndims(f),typeof(f),typeof(metp),typeof(SD)}(f, !fnan, metp, SD, thresh)
end

function Base.call(d::RigidValue, x)
    tfm = p2rigid(x, d.SD)
    mov = transform(d.moving, tfm)
    movnan = isnan(mov)
    mov[movnan] = 0
    f = d.fixed.*!movnan
    m = mov.*d.wfixed
    den = sumabs2(f)+sumabs2(m)
    real(den) < d.thresh && return convert(typeof(den), Inf)
    sumabs2(f-m)/den
end

type RigidOpt{RV<:RigidValue,G} <: GradOnlyBoundsOnly
    rv::RV
    g::G
end

function RigidOpt(fixed, moving, SD, thresh)
    rv = RigidValue(fixed, moving, SD, thresh)
    g = ForwardDiff.gradient(rv)
    RigidOpt(rv, g)
end

SolverInterface.eval_f(d::RigidOpt, x) = d.rv(x)
SolverInterface.eval_grad_f(d::RigidOpt, grad_f, x) =
    copy!(grad_f, d.g(x))

###
### Globally-optimal initial guess for deformation given
### quadratic-fit mismatch data
###
"""
`u0 = initial_deformation(ap::AffinePenalty, cs, Qs;
[ϕ_old=identity])` prepares a globally-optimal initial guess for a
deformation, given a quadratic fit to the aperture-wise mismatch
data. `cs` and `Qs` must be arrays-of-arrays in the shape of the
u0-grid, each entry as calculated by `qfit`. The initial guess
minimizes the function

```
    ap(ϕ(u0)) + ∑_i (u0[i]-cs[i])' * Qs[i] * (u0[i]-cs[i])
```
where `ϕ(u0)` is the deformation associated with `u0`.

If `ϕ_old` is not the identity, it must be interpolating.
"""
function initial_deformation{T,N}(ap::AffinePenalty{T,N}, cs, Qs)
    b = prep_b(T, cs, Qs)
    # A = to_full(ap, Qs)
    # F = svdfact(A)
    # S = F[:S]
    # smax = maximum(S)
    # fac = sqrt(eps(typeof(smax)))
    # for i = 1:length(S)
    #     if S[i] < fac*smax
    #         S[i] = Inf
    #     end
    # end
    # x, isconverged = F\b, true
    # In case the grid is really big, solve iteratively
    # (The matrix is not sparse, but matrix-vector products can be
    # computed efficiently.)
    P = AffineQHessian(ap, Qs, identity)
    x, isconverged = find_opt(P, b)
    convert_to_fixed(x, (N,size(cs)...))::Array{Vec{N,T},N}, isconverged
end

function to_full{T,N}(ap::AffinePenalty{T,N}, Qs)
    FF = ap.F*ap.F'
    nA = N*size(FF,1)
    FFN = zeros(nA,nA)
    for o = 1:N
        FFN[o:N:end,o:N:end] = FF
    end
    A = ap.λ*(I - FFN)
    for i = 1:length(Qs)
        A[N*(i-1)+1:N*i, N*(i-1)+1:N*i] += Qs[i]
    end
    A
end

function prep_b{T}(::Type{T}, cs, Qs)
    n = prod(size(Qs))
    N = length(first(cs))
    b = zeros(T, N*n)
    for i = 1:n
        b[(i-1)*N+1:i*N] = Qs[i]*cs[i]
    end
    b
end

function find_opt(P, b)
    x, result = cg(P, b)
    x, result.isconverged
end

# A type for computing multiplication by the linear operator
type AffineQHessian{AP<:AffinePenalty,M<:Mat,N,Φ}
    ap::AP
    Qs::Array{M,N}
    ϕ_old::Φ
end

function AffineQHessian{T}(ap::AffinePenalty{T}, Qs::AbstractArray, ϕ_old)
    N = ndims(Qs)
    AffineQHessian{typeof(ap),Mat{N,N,T},N,typeof(ϕ_old)}(ap, Qs, ϕ_old)
end

Base.eltype{AP,M,N,Φ}(::Type{AffineQHessian{AP,M,N,Φ}}) = eltype(AP)
Base.eltype(P::AffineQHessian) = eltype(typeof(P))
Base.size(P::AffineQHessian, d) = length(P.Qs)*size(first(P.Qs),1)

# These compute the gradient of (x'*P*x)/2, where P is the Hessian
# for the objective in the doc text for initial_deformation.
function (*){T,N}(P::AffineQHessian{AffinePenalty{T,N}}, x::AbstractVector{T})
    gridsize = size(P.Qs)
    n = prod(gridsize)
    u = convert_to_fixed(x, (N,gridsize...)) #reinterpret(Vec{N,T}, x, gridsize)
    g = similar(u)
    λ = P.ap.λ
    P.ap.λ = λ*n/2
    affine_part!(g, P, u)
    P.ap.λ = λ
    sumQ = zero(T)
    for i = 1:n
        g[i] += P.Qs[i] * u[i]
        sumQ += trace(P.Qs[i])
    end
    # Add a stabilizing diagonal, for cases where λ is very small
    if sumQ == 0
        sumQ = one(T)
    end
    fac = cbrt(eps(T))*sumQ/n
    for i = 1:n
        g[i] += fac*u[i]
    end
    reinterpret(T, g, size(x))
end

affine_part!(g, P, u) = penalty!(g, P.ap, u)


function initial_deformation{T,N}(ap::AffinePenalty{T,N}, cs, Qs, ϕ_old, maxshift)
    error("This is broken, don't use it")
    b = prep_b(T, cs, Qs)
    # In case the grid is really big, solve iteratively
    # (The matrix is not sparse, but matrix-vector products can be
    # computed efficiently.)
    P0 = AffineQHessian(ap, Qs, identity)
    x0 = find_opt(P0, b)
    P = AffineQHessian(ap, Qs, ϕ_old)
    x = find_opt(P, b, maxshift, x0)
    u0 = convert_to_fixed(x, (N,size(cs)...)) #reinterpret(Vec{N,eltype(x)}, x, size(cs))
end

# type for minimization with composition (which turns the problem into
# a nonlinear problem)
type InitialDefOpt{AQH,B} <: GradOnlyBoundsOnly
    P::AQH
    b::B
end

function find_opt{AP,M,N,Φ<:GridDeformation}(P::AffineQHessian{AP,M,N,Φ}, b, maxshift, x0)
    objective = InitialDefOpt(P, b)
    solver = IpoptSolver(hessian_approximation="limited-memory",
                         print_level=0)
    m = SolverInterface.model(solver)
    T = eltype(b)
    n = length(b)
    ub1 = T[maxshift...] - T(0.5001)
    ub = repeat(ub1, outer=[div(n, length(maxshift))])
    SolverInterface.loadnonlinearproblem!(m, n, 0, -ub, ub, T[], T[], :Min, objective)
    SolverInterface.setwarmstart!(m, x0)
    SolverInterface.optimize!(m)
    stat = SolverInterface.status(m)
    stat == :Optimal || warn("Solution was not optimal")
    SolverInterface.getsolution(m)
end

# We omit the constant term ∑_i cs[i]'*Qs[i]*cs[i], since it won't
# affect the solution
SolverInterface.eval_f(d::InitialDefOpt, x::AbstractVector) =
    _eval_f(d.P, d.b, x)

function _eval_f{T,N}(P::AffineQHessian{AffinePenalty{T,N}}, b, x::AbstractVector)
    gridsize = size(P.Qs)
    n = prod(gridsize)
    u  = convert_to_fixed(x, (N,gridsize...))# reinterpret(Vec{N,T}, x, gridsize)
    bf = convert_to_fixed(b, (N,gridsize...))# reinterpret(Vec{N,T}, b, gridsize)
    λ = P.ap.λ
    P.ap.λ = λ*n/2
    val = affine_part!(nothing, P, u)
    P.ap.λ = λ
    for i = 1:n
        val += ((u[i]' * P.Qs[i] * u[i])/2 - bf[i]'*u[i])[1]
    end
    val
end

function SolverInterface.eval_grad_f(d::InitialDefOpt, grad_f, x)
    P, b = d.P, d.b
    copy!(grad_f, P*x-b)
end

function affine_part!{AP,M,N,Φ<:GridDeformation}(g, P::AffineQHessian{AP,M,N,Φ}, u)
    ϕ_c, g_c = compose(P.ϕ_old, GridDeformation(u, P.ϕ_old.knots))
    penalty!(g, P.ap, ϕ_c, g_c)
end

function affine_part!{AP,M,N,Φ<:GridDeformation}(::Void, P::AffineQHessian{AP,M,N,Φ}, u)
    # Sadly, with GradientNumbers this gives an error I haven't traced
    # down (might be a Julia bug)
    # ϕ_c = P.ϕ_old(GridDeformation(u, P.ϕ_old.knots))
    # penalty!(nothing, P.ap, ϕ_c)
    u_c = RegisterDeformation._compose(P.ϕ_old.u, u, P.ϕ_old.knots)
    penalty!(nothing, P.ap, u_c)
end

###
### Optimize (via descent) a deformation to mismatch data
###
"""
`ϕ, fval, fval0 = optimize!(ϕ, ϕ_old, dp, mmis; [tol=1e-6, print_level=0])`
improves an initial deformation `ϕ` to reduce the mismatch.  The
arguments are as described for `penalty!` in RegisterPenalty.  On
output, `ϕ` is set in-place to the new optimized deformation,
`fval` is the value of the penalty, and `fval0` was the starting value.

It's recommended that you verify that `fval < fval0`; if it's not
true, consider adding `mu_strategy="monotone", mu_init=??` to the
options (where the value of ?? might require some experimentation; a
starting point might be 1e-4).

"""
function optimize!(ϕ, ϕ_old, dp::DeformationPenalty, mmis; tol=1e-6, print_level=0, kwargs...)
    objective = DeformOpt(ϕ, ϕ_old, dp, mmis)
    uvec = u_as_vec(ϕ)
    T = eltype(uvec)
    mxs = maxshift(first(mmis))

    solver = IpoptSolver(;hessian_approximation="limited-memory",
                         print_level=print_level,
                         tol=tol, kwargs...)
    m = SolverInterface.model(solver)
    ub1 = T[mxs...] - T(0.5001)
    ub = repeat(ub1, outer=[length(ϕ.u)])
    SolverInterface.loadnonlinearproblem!(m, length(uvec), 0, -ub, ub, T[], T[], :Min, objective)
    SolverInterface.setwarmstart!(m, uvec)
    fval0 = SolverInterface.eval_f(objective, uvec)
    isfinite(fval0) || error("Initial value must be finite")
    SolverInterface.optimize!(m)

    stat = SolverInterface.status(m)
    stat == :Optimal || warn("Solution was not optimal")
    uopt = SolverInterface.getsolution(m)
    fval = SolverInterface.getobjval(m)
    copy!(uvec, uopt)
    ϕ, fval, fval0
end

function u_as_vec(ϕ)
    T = eltype(eltype(ϕ.u))
    N = length(eltype(ϕ.u))
    uvec = reinterpret(T, ϕ.u, (N*length(ϕ.u),))
end

function vec_as_u{T,N}(g::Array{T}, ϕ::GridDeformation{T,N})
    reinterpret(Vec{N,T}, g, size(ϕ.u))
end

type DeformOpt{D,Dold,DP,M} <: GradOnlyBoundsOnly
    ϕ::D
    ϕ_old::Dold
    dp::DP
    mmis::M
end

function SolverInterface.eval_f(d::DeformOpt, x)
    uvec = u_as_vec(d.ϕ)
    copy!(uvec, x)
    penalty!(nothing, d.ϕ, d.ϕ_old, d.dp, d.mmis)
end

function SolverInterface.eval_grad_f(d::DeformOpt, grad_f, x)
    uvec = u_as_vec(d.ϕ)
    copy!(uvec, x)
    penalty!(vec_as_u(grad_f, d.ϕ), d.ϕ, d.ϕ_old, d.dp, d.mmis)
end

"""
`ϕ, penalty = fixed_λ(cs, Qs, knots, affinepenalty, mmis)` computes an
optimal deformation `ϕ` and its total `penalty` (data penalty +
regularization penalty).  `cs` and `Qs` come from `qfit`, `knots`
specifies the deformation grid, `affinepenalty` the `AffinePenalty`
object for that grid, and `mmis` is the array-of-mismatch arrays
(already interpolating, see `interpolate_mm!`).

See also: `auto_λ`.
"""
function fixed_λ{T,N}(cs, Qs, knots::NTuple{N}, ap::AffinePenalty{T,N}, mmis)
    maxshift = map(x->(x-1)>>1, size(first(mmis)))
    u0, isconverged = initial_deformation(ap, cs, Qs)
    if !isconverged
        Base.warn_once("initial_deformation failed to converge with λ = ", ap.λ)
    end
    uclamp!(u0, maxshift)
    ϕ = GridDeformation(u0, knots)
    mu_init = 0.1
    local mismatch
    while mu_init > 1e-16
        ϕ, mismatch, mismatch0 = optimize!(ϕ, identity, ap, mmis, mu_strategy="monotone", mu_init=mu_init)
        mismatch <= mismatch0 && break
        mu_init /= 10
        @show mu_init
    end
    ϕ, mismatch
end

###
### Set λ automatically
###
"""
`ϕ, penalty, λ, datapenalty, quality = auto_λ(cs, Qs, knots,
affinepenalty, mmis, λmin, λmax)` automatically chooses "the best"
value of `λ` to serve in the regularization penalty. It tests a
sequence of `λ` values, starting with `λmin` and each successive value
two-fold larger than the previous; for each such `λ`, it optimizes the
registration and then evaluates just the "data" portion of the
penalty.  The "best" value is selected by a sigmoidal fit of the
impact of `λ` on the data penalty, choosing a value that lies at the
initial upslope of the sigmoid (indicating that the penalty is large
enough to begin limiting the form of the deformation, but not yet to
substantially decrease the quality of the registration).

`cs` and `Qs` come from `qfit`, `knots` specifies the deformation
grid, `affinepenalty` the `AffinePenalty` object for that grid (the
value of `lambda` that you used to create the object is unimportant,
it will be replaced with the sequence described above), and `mmis` is
the array-of-mismatch arrays (already interpolating, see
`interpolate_mm!`).

As a first pass, try setting `λmin=1e-6` and `λmax=100`. You can plot
the returned `datapenalty` and check that it is approximately
sigmoidal; if not, you will need to alter the range you supply.

Upon return, `ϕ` is the chosen deformation, `penalty` its total
penalty (data penalty+regularization penalty), `λ` is the chosen value
of `λ`, `datapenalty` is a vector containing the data penalty for each
tested `λ` value, and `quality` an estimate (possibly broken) of the
fidelity of the sigmoidal fit.

See also: `fixed_λ`. Because `auto_λ` performs the optimization
repeatedly for many different `λ`s, it is slower than `fixed_λ`.
"""
function auto_λ{T,N}(cs, Qs, knots::NTuple{N}, ap::AffinePenalty{T,N}, mmis, λmin, λmax)
    gridsize = map(length, knots)
    uc = zeros(T, N, gridsize...)
    for i = 1:length(cs)
        uc[:,i] = cs[i]
    end
    function optimizer!(x, mu_init)
        local pnew
        while mu_init > 1e-16
            x, pnew, p0 = optimize!(x, identity, ap, mmis, mu_strategy="monotone", mu_init=mu_init)
            pnew <= p0 && break
            mu_init /= 10
        end
        x, pnew
    end
    ap.λ = λ = λmin
    maxshift = map(x->(x-1)>>1, size(first(mmis)))
    uclamp!(uc, maxshift)
    ϕprev = GridDeformation(uc, knots)
    mu_init = 0.1
    ϕprev, penaltyprev = optimizer!(ϕprev, mu_init)
    u0, isconverged = initial_deformation(ap, cs, Qs)
    if !isconverged
        Base.warn_once("initial_deformation failed to converge with λ = ", λ)
    end
    uclamp!(u0, maxshift)
    ϕap = GridDeformation(u0, knots)
    ϕap, penaltyap = optimizer!(ϕap, mu_init)
    penalty_all = typeof(penaltyprev)[]
    datapenalty_all = similar(penalty_all)
    ϕ_all = Any[]
    # Keep the lower penalty, but for the purpose of the sigmoidal fit
    # evaluate just the data penalty
    if penaltyprev < penaltyap
        push!(penalty_all, penaltyprev)
        push!(datapenalty_all, penalty!(nothing, ϕprev, mmis))
        push!(ϕ_all, ϕprev)
    else
        push!(penalty_all, penaltyap)
        push!(datapenalty_all, penalty!(nothing, ϕap, mmis))
        push!(ϕ_all, ϕap)
    end
    λ_all = [λ]
    λ *= 2
    while λ < λmax
        ap.λ = λ
        ϕprev = GridDeformation(copy(ϕ_all[end].u), knots)
        ϕprev, penaltyprev = optimizer!(ϕprev, mu_init)
        u0, isconverged = initial_deformation(ap, cs, Qs)
        if !isconverged
            Base.warn_once("initial_deformation failed to converge with λ = ", λ)
        end
        uclamp!(u0, maxshift)
        ϕap = GridDeformation(u0, knots)
        ϕap, penaltyap = optimizer!(ϕap, mu_init)
        if penaltyprev < penaltyap
            push!(penalty_all, penaltyprev)
            push!(datapenalty_all, penalty!(nothing, ϕprev, mmis))
            push!(ϕ_all, ϕprev)
        else
            push!(penalty_all, penaltyap)
            push!(datapenalty_all, penalty!(nothing, ϕap, mmis))
            push!(ϕ_all, ϕap)
        end
        push!(λ_all, λ)
        λ *= 2
    end
    bottom, top, center, width, val = fit_sigmoid(datapenalty_all)
    idx = max(1, round(Int, center-width))
    quality = val/(top-bottom)^2/length(datapenalty_all)
    ϕ_all[idx], penalty_all[idx], λ_all[idx], datapenalty_all, quality
end

###
### Mismatch-based optimization of affine transformation
###
### NOTE: not updated yet, probably broken
"""
`tform = optimize(tform0, mms, knots)` performs descent-based
minimization of the total mismatch penalty as a function of the
parameters of an affine transformation, starting from an initial guess
`tform0`.  While this is unlikely to yield very accurate results for
large rotations or skews (the mismatch data are themselves suspect in
such cases), it can be helpful for polishing small deformations.

For a good initial guess, see `mismatch2affine`.
"""
function optimize(tform::AffineTransform, mmis, knots)
    gridsize = size(mmis)
    N = length(gridsize)
    ndims(tform) == N || error("Dimensionality of tform is $(ndims(tform)), which does not match $N for nums/denoms")
    mm = first(mmis)
    mxs = maxshift(mm)
    T = eltype(eltype(mm))
    # Compute the bounds
    asz = arraysize(knots)
    center = T[(asz[i]+1)/2 for i = 1:N]
    X = zeros(T, N+1, prod(gridsize))
    for (i, knot) in enumerate(eachknot(knots))
        X[1:N,i] = knot - center
        X[N+1,i] = 1
    end
    bound = convert(Vector{T}, [mxs .- register_half; Inf])
    lower = repeat(-bound, outer=[1,size(X,2)])
    upper = repeat( bound, outer=[1,size(X,2)])
    # Extract the parameters from the initial guess
    Si = tform.scalefwd
    displacement = tform.offset
    A = convert(Matrix{T}, [Si-eye(N) displacement; zeros(1,N) 1])
    # Determine the blocks that start in-bounds
    AX = A*X
    keep = trues(gridsize)
    for j = 1:length(keep)
        for idim = 1:N
            xi = AX[idim,j]
            if xi < -mxs[idim]+register_half_safe || xi > mxs[idim]-register_half_safe
                keep[j] = false
                break
            end
        end
    end
    if !any(keep)
        @show tform
        warn("No valid blocks were found")
        return tform
    end
    ignore = !keep[:]
    lower[:,ignore] = -Inf
    upper[:,ignore] =  Inf
    # Assemble the objective and constraints

    constraints = Optim.ConstraintsL(X', lower', upper')
    gtmp = Array(Vec{N,T}, gridsize)
    objective = (x,g) -> affinepenalty!(g, x, mmis, keep, X', gridsize, gtmp)
    @assert typeof(objective(A', T[])) == T
    result = interior(DifferentiableFunction(x->objective(x,T[]), Optim.dummy_g!, objective), A', constraints, method=:cg)
    @assert Optim.converged(result)
    Aopt = result.minimum'
    Siopt = Aopt[1:N,1:N] + eye(N)
    displacementopt = Aopt[1:N,end]
    AffineTransform(convert(Matrix{T}, Siopt), convert(Vector{T}, displacementopt)), result.f_minimum
end

function affinepenalty!{N}(g, At, mmis, keep, Xt, gridsize::NTuple{N}, gtmp)
    u = _calculate_u(At, Xt, gridsize)
    @assert eltype(u) == eltype(At)
    val = penalty!(gtmp, u, mmis, keep)
    @assert isa(val, eltype(At))
    if !isempty(g)
        T = eltype(eltype(gtmp))
        nblocks = size(Xt,1)
        At_mul_Bt!(g, Xt, [reinterpret(T,gtmp,(N,nblocks)); zeros(1,nblocks)])
    end
    val
end

function _calculate_u{N}(At, Xt, gridsize::NTuple{N})
    Ut = Xt*At
    u = Ut[:,1:size(Ut,2)-1]'                   # discard the dummy dimension
    reinterpret(Vec{N, eltype(u)}, u, gridsize) # put u in the shape of the grid
end

###
### Fitting to a sigmoid
###
# Used in automatically setting λ

"""
`fit_sigmoid(data, [bottom, top, center, width])` fits the y-values in `data` to a logistic function
```
   y = bottom + (top-bottom)./(1 + exp(-(data-center)/width))
```
This is "non-extrapolating": the parameter values are constrained to
be within the range of the supplied data (i.e., `bottom` and `top`
between the min and max values of `data`, `center` within `[1,
length(data)]`, and `0.1 <= width <= length(data)`.)
"""
function fit_sigmoid(data, bottom, top, center, width)
    length(data) >= 4 || error("Too few data points for sigmoidal fit")
    objective = SigmoidOpt(data)
    solver = IpoptSolver(print_level=0)
    m = SolverInterface.model(solver)
    x0 = Float64[bottom, top, center, width]
    mn, mx = extrema(data)
    ub = [mx, mx, length(data), length(data)]
    lb = [mn, mn, 1, 0.1]
    SolverInterface.loadnonlinearproblem!(m, 4, 0, lb, ub, Float64[], Float64[], :Min, objective)
    SolverInterface.setwarmstart!(m, x0)
    SolverInterface.optimize!(m)

    stat = SolverInterface.status(m)
    stat == :Optimal || warn("Solution was not optimal")
    x = SolverInterface.getsolution(m)

    x[1], x[2], x[3], x[4], SolverInterface.getobjval(m)
end

function fit_sigmoid(data)
    length(data) >= 4 || error("Too few data points for sigmoidal fit")
    sdata = sort(data)
    mid = length(data)>>1
    bottom = mean(sdata[1:mid])
    top = mean(sdata[mid+1:end])
    fit_sigmoid(data, bottom, top, mid, mid)
end


type SigmoidOpt{G,H} <: BoundsOnly
    data::Vector{Float64}
    g::G
    h::H
end

SigmoidOpt(data::Vector{Float64}) = SigmoidOpt(data, ForwardDiff.gradient(x->sigpenalty(x, data)), ForwardDiff.hessian(x->sigpenalty(x, data)))

function SolverInterface.initialize(d::SigmoidOpt, requested_features::Vector{Symbol})
    for feat in requested_features
        if !(feat in [:Grad, :Jac, :Hess])
            error("Unsupported feature $feat")
        end
    end
end
SolverInterface.features_available(d::SigmoidOpt) = [:Grad, :Jac, :Hess]

SolverInterface.eval_f(d::SigmoidOpt, x) = sigpenalty(x, d.data)

SolverInterface.eval_grad_f(d::SigmoidOpt, grad_f, x) =
    copy!(grad_f, d.g(x))

function SolverInterface.hesslag_structure(d::SigmoidOpt)
    I, J = Int[], Int[]
    for i in CartesianRange((4,4))
        push!(I, i[1])
        push!(J, i[2])
    end
    (I, J)
end

function SolverInterface.eval_hesslag(d::SigmoidOpt, H, x, σ, μ)
    copy!(H, σ * d.h(x))
end

function sigpenalty(x, data)
    bottom, top, center, width = x[1], x[2], x[3], x[4]
    sumabs2((data-bottom)/(top-bottom) - 1./(1+exp(-((1:length(data))-center)/width)))
end

end # module