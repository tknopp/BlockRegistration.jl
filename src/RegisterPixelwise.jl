__precompile__()

module RegisterPixelwise

using Interpolations, RegisterDeformation, RegisterPenalty, ImageCore, Compat
using Base.Cartesian
using Interpolations: sqr, SimpleRatio
# using ReverseDiff
# using ReverseDiff: GradientTape, GradientConfig, compile

using ForwardDiff
ImageCore.float64(d::ForwardDiff.Dual) = ForwardDiff.Dual(float64(d.value), ForwardDiff.Partials(map(float64, d.partials.values)))

@compat const InterpolatingDeformation{T,N,A<:AbstractInterpolation} = GridDeformation{T,N,A}

# Because automatic differentiation requires arrays of <:Real, we
# implement deformation-interpolation on real-valued arrays. This
# requires that we manually implement the calculations that would be
# handled by a StaticArray. (We compute coefficients once and apply
# them to all the components of the deformation vector field.)
@generated function deformation_coords(U, itp, xs::Real...)
    N = ndims(itp)
    length(xs) == N || return :(error("must index with ", $N, " dimensions"))
    ndims(U) == N+1 || return :(DimensionMismatch("dimensions of U must be 1 larger than dimensions of itp"))
    deformation_coords_impl(itp)
end

function deformation_coords_impl{itp<:Interpolations.BSplineInterpolation}(::Type{itp})
    N = ndims(itp)
    itype = Interpolations.itptype(itp)
    Pad = Interpolations.padding(itp)
    if !(itype <: Tuple)
        itype = Tuple{ntuple(i->itype, N)...}
    end
    # first coord of U is for components of deformation vector
    IT = Tuple{NoInterp, itype.parameters...}
    usym = [Symbol(:u_, n) for n = 1:N]
    u_ex = Expr(:block, [:(ix_1 = $n; @inbounds $(usym[n]) = $(Interpolations.index_gen(IT, N+1))) for n = 1:N]...)
    ex = quote
        $(Expr(:meta, :inline))
        @nexprs $N d->(x_{d+1} = xs[d])
        x_1 = 1
        inds_itp = indices(U)

        # Calculate the indices of all coefficients that will be used
        # and define fx = x - xi in each dimension
        $(Interpolations.define_indices(IT, N+1, Pad))

        # Calculate coefficient weights based on fx
        $(Interpolations.coefficients(IT, N+1))

        # Calculate the outputs
        $u_ex
        tuple($(usym...),)
    end
    replace_expr!(ex, :(itp.coefs), :U)
end

function replace_expr!(ex::Expr, pat, rep)
    for i = 1:length(ex.args)
        if ex.args[i] == pat
            ex.args[i] = rep
        else
            replace_expr!(ex.args[i], pat, rep)
        end
    end
    ex
end
replace_expr!(obj, pat, rep) = obj

function penalty_pixelwise{T<:Real}(U::AbstractArray{T}, itp, knots, ap::AffinePenalty, fixed, moving)
    size(U, 1) == ndims(fixed) || throw(DimensionMismatch("size(U) = $(size(U)), which disagrees with an $(ndims(fixed))-dimensional image"))
    # The regularization penalty. We apply this to the interpolation
    # coefficients rather than the on-grid values. This may be
    # cheating. It also requires InPlace() so that the sizes match.
    n = prod(Base.tail(size(U)))
    X = reshape(U, size(U, 1), n)
    F, λ = ap.F, ap.λ
    A = (X*F)*F'
    dX = X-A
    val = (λ/n) * sumabs2(dX)
    # Combine with the data penalty
    convert(T, val + penalty_pixelwise_data(U, itp, knots, fixed, moving))
end

@generated function penalty_pixelwise_data{T<:Real,_,N}(U::AbstractArray{T},
                                                        itp,
                                                        knots::NTuple{N,Range},
                                                        fixed::AbstractArray{_,N},
                                                        moving)
    uindexes = [:((I[$d]-offsets[$d])/steps[$d] + 1) for d = 1:N]
    ϕxindexes = [:(I[$d] + u[$d]) for d = 1:N]
    quote
        steps = map(step, knots)
        offsets = map(first, knots)
        valid = 0
        mm = 0.0
        for I in CartesianRange(indices(fixed))
            fval = fixed[I]
            if isfinite(fval)
                u = deformation_coords(U, itp, $(uindexes...))
                mval = moving[$(ϕxindexes...)]
                if isfinite(mval)
                    valid += 1
                    diff = float64(fval)-float64(mval)
                    mm += diff^2
                end
            end
        end
        mm/valid
    end
end

function optimize_pixelwise!(ϕ::InterpolatingDeformation, dp::DeformationPenalty, fixed, moving::AbstractExtrapolation; stepsize = 1.0)
    # Optimize the interpolation coefficients, rather than the values
    # of the deformation at the grid points
    itp = ϕ.u.itp
    U = RegisterDeformation.convert_from_fixed(itp.coefs)
    @assert pointer(U) == pointer(itp.coefs)
    g = similar(U)
    objective = x->penalty_pixelwise(x, itp, ϕ.knots, dp, fixed, moving)
    # f_tape = GradientTape(objective, (copy(U),))
    # compiled_f_tape = compile(f_tape)
    # ∇objective!(results, x) = ReverseDiff.gradient!(results, compiled_f_tape, x)
    ∇objective!(results, x) = ForwardDiff.gradient!(results, objective, x)
    p0 = p = objective(U)
    pold = oftype(p, Inf)
    while p < pold
        pold = p
        ∇objective!(g, U)
        gmax = mapreduce(abs, max, g)
        if gmax == 0 || !isfinite(gmax)
            break
        end
        s = eltype(g)(stepsize/gmax)
        Utrial = U .- s .* g
        p = objective(Utrial)
        if p < pold
            copy!(U, Utrial)
        end
    end
    ϕ, pold, p0
end

function optimize_pixelwise!(ϕ::GridDeformation, dp::DeformationPenalty, fixed, moving::AbstractExtrapolation; stepsize = 1.0)
    optimize_pixelwise!(interpolate!(ϕ), dp, fixed, moving; stepsize=stepsize)
end

end
