__precompile__()

# Note: this requires a patch to julia itself. See julia PR#13203/#13235.

module CenterIndexedArrays

using Images

import Base: size, eachindex, getindex, setindex!, linearindexing
import Base: ==, +, -, *, /, .+, .-, .*, ./, .\, .%, .<<, .>>, &, |, $
import Base: copy, isequal, maximum, minimum, cumsum, permutedims, ipermutedims
import Base: mapslices, flipdim
import Base: show, showcompact, writemime
using Base.Cartesian

export CenterIndexedArray

"""
A `CenterIndexedArray` is one for which the array center has indexes
`0,0,...`. Along each coordinate, allowed indexes range from `-n:n`.
"""
immutable CenterIndexedArray{T,N,A<:AbstractArray} <: DenseArray{T,N}
    data::A
    halfsize::NTuple{N,Int}

    function CenterIndexedArray(data::A)
        new(data, _halfsize(data))
    end
end

CenterIndexedArray{T,N}(A::AbstractArray{T,N}) = CenterIndexedArray{T,N,typeof(A)}(A)
CenterIndexedArray{T}(::Type{T}, dims) = CenterIndexedArray(Array(T, dims))
CenterIndexedArray{T}(::Type{T}, dims...) = CenterIndexedArray(Array(T, dims))

# This is the AbstractArray default, but do this just to be sure
linearindexing{A<:CenterIndexedArray}(::Type{A}) = Base.LinearSlow()

size(A::CenterIndexedArray) = size(A.data)

@generated function _halfsize{T,N}(A::AbstractArray{T,N})
    args = [:(size(A,$d)>>1) for d = 1:N]
    quote
        @nexprs $N d->(isodd(size(A,d)) || error("Must have all-odd sizes"))
        tuple($(args...))
    end
end

@generated function eachindex{T,N}(::Base.LinearSlow, A::CenterIndexedArray{T,N})
    startargs = [:(-A.halfsize[$i]) for i = 1:N]
    stopargs  = [:( A.halfsize[$i]) for i = 1:N]
    meta = Expr(:meta, :inline)
    :($meta; CartesianRange(CartesianIndex{$N}($(startargs...)), CartesianIndex{$N}($(stopargs...))))
end

@generated function getindex{T,N}(A::CenterIndexedArray{T,N}, i::Number...)
    length(i) == N || error("Must use $N indexes")
    args = [:(i[$d]+A.halfsize[$d]+1) for  d = 1:N]
    meta = Expr(:meta, :inline)
    :($meta; A.data[$(args...)])
end

typealias Index Union{Colon,AbstractVector}

getindex{T}(A::CenterIndexedArray{T,1}, I::Index) = CenterIndexedArray([A[i] for i in _cindex(A, 1, I)])
getindex{T}(A::CenterIndexedArray{T,2}, I::Index, J::Index) = CenterIndexedArray([A[i,j] for i in _cindex(A,1,I), j in _cindex(A,2,J)])
getindex{T}(A::CenterIndexedArray{T,3}, I::Index, J::Index, K::Index) = CenterIndexedArray([A[i,j,k] for i in _cindex(A,1,I), j in _cindex(A,2,J), k in _cindex(A,3,K)])

_cindex(A::CenterIndexedArray, d, I::Range) = first(I) == -last(I) ? I : error("Must be symmetric around zero")
_cindex(A::CenterIndexedArray, d, I::AbstractVector) = error("unsupported, use a range")
_cindex(A::CenterIndexedArray, d, ::Colon) = -A.halfsize[d]:A.halfsize[d]


@generated function setindex!{T,N}(A::CenterIndexedArray{T,N}, v, i::Number...)
    length(i) == N || error("Must use $N indexes")
    args = [:(i[$d]+A.halfsize[$d]+1) for  d = 1:N]
    meta = Expr(:meta, :inline)
    :($meta; A.data[$(args...)] = v)
end

(==)(A::CenterIndexedArray, B::CenterIndexedArray) = A.data == B.data
(==)(A::CenterIndexedArray, B::AbstractArray) = A.data == B
(==)(A::AbstractArray, B::CenterIndexedArray) = A == B.data

isequal(A::CenterIndexedArray, B::CenterIndexedArray) = isequal(A.data, B.data)
isequal(A::CenterIndexedArray, B::AbstractArray) = isequal(A.data, B)
isequal(A::AbstractArray, B::CenterIndexedArray) = isequal(A, B.data)

copy(A::CenterIndexedArray) = CenterIndexedArray(copy(A.data))

maximum(A::CenterIndexedArray, region) = maximum(A.data, region)
minimum(A::CenterIndexedArray, region) = minimum(A.data, region)

cumsum(A::CenterIndexedArray, region) = cumsum(A.data, region)

 permutedims(A::CenterIndexedArray, perm) = CenterIndexedArray(permutedims(A.data, perm))
ipermutedims(A::CenterIndexedArray, perm) = CenterIndexedArray(ipermutedims(A.data, perm))

mapslices(f, A::CenterIndexedArray, dims::AbstractVector) = mapslices(f, A.data, dims)
flipdim{T}(A::CenterIndexedArray{T,1}, dim::Integer) = CenterIndexedArray(flipdim(A.data, dim))  # ambiguity
flipdim(A::CenterIndexedArray, dim::Integer) = CenterIndexedArray(flipdim(A.data, dim))

# The following definitions are needed to avoid ambiguity warnings
for f in (:+, :-, :.+, :.-)
    @eval begin
        ($f)(A::CenterIndexedArray{Bool},x::Bool) = CenterIndexedArray($f(A.data, x))
        ($f)(x::Bool, A::CenterIndexedArray{Bool}) = CenterIndexedArray($f(x, A.data))
        ($f)(A::CenterIndexedArray{Bool}, B::CenterIndexedArray{Bool}) = CenterIndexedArray($f(A.data, B.data))
        ($f)(A::CenterIndexedArray{Bool}, B::StridedArray{Bool}) = error("ambiguous container type")
        ($f)(A::StridedArray{Bool}, B::CenterIndexedArray{Bool}) = error("ambiguous container type")
    end
end
(.*){T<:Dates.Period}(A::CenterIndexedArray{T},x::Real) = CenterIndexedArray(A.data .* x)
(.*){T<:Dates.Period}(x::Real,A::CenterIndexedArray{T}) = CenterIndexedArray(x .* A.data)
(./){T<:Dates.Period}(A::CenterIndexedArray{T},x::Real) = CenterIndexedArray(A.data ./ x)
(.%){T<:Dates.Period}(A::CenterIndexedArray{T},x::Integer) = CenterIndexedArray(A.data .% x)
for op in (:.+, :.-, :+, :-)
    @eval begin
        ($op){P<:Dates.GeneralPeriod, Q<:Dates.GeneralPeriod}(X::CenterIndexedArray{P}, Y::CenterIndexedArray{Q}) = CenterIndexedArray($op(X.data, Y.data))
        ($op){P<:Dates.GeneralPeriod, Q<:Dates.GeneralPeriod}(X::CenterIndexedArray{P}, Y::StridedArray{Q}) = error("ambiguous container type")
        ($op){P<:Dates.GeneralPeriod, Q<:Dates.GeneralPeriod}(X::StridedArray{P}, Y::CenterIndexedArray{Q}) = error("ambiguous container type")
    end
end
for f in (:&, :|, :$)
    @eval begin
        ($f)(A::CenterIndexedArray{Bool}, B::CenterIndexedArray{Bool}) = CenterIndexedArray($f(A.data, B.data))
        ($f)(A::CenterIndexedArray{Bool}, B::BitArray) = error("ambiguous container type")
        ($f)(A::BitArray, B::CenterIndexedArray{Bool}) = error("ambiguous container type")
    end
end
(+)(A::AbstractImageDirect, B::CenterIndexedArray) = error("ambiguous container type")
(-)(A::AbstractImageDirect, B::CenterIndexedArray) = error("ambiguous container type")

# Now we get to the real stuff
for f in (:.+, :.-, :.*, :./, :.\, :.%, :.<<, :.>>, :div, :mod, :rem, :&, :|, :$)
   @eval begin
       ($f){T}(A::Number, B::CenterIndexedArray{T}) = CenterIndexedArray($f(A,B.data))
       ($f){T}(A::CenterIndexedArray{T}, B::Number) = CenterIndexedArray($f(A.data,B))
    end
end

(+)(A::CenterIndexedArray,x::Number) = CenterIndexedArray(A.data + x)
(+)(x::Number,A::CenterIndexedArray) = CenterIndexedArray(x + A.data)
(-)(A::CenterIndexedArray,x::Number) = CenterIndexedArray(A.data - x)
(-)(x::Number,A::CenterIndexedArray) = CenterIndexedArray(x - A.data)

(*)(A::CenterIndexedArray,x::Number) = CenterIndexedArray(A.data * x)
(*)(x::Number,A::CenterIndexedArray) = CenterIndexedArray(x * A.data)
(/)(A::CenterIndexedArray,x::Number) = CenterIndexedArray(A.data / x)

for f in (:+, :-, :div, :mod, :&, :|, :$)
    @eval begin
        ($f)(A::CenterIndexedArray, B::CenterIndexedArray) = CenterIndexedArray($f(A.data,B.data))
        ($f){S,T}(A::CenterIndexedArray{S}, B::Range{T}) = CenterIndexedArray($f(A.data,B))
        ($f){S,T}(B::Range{S}, A::CenterIndexedArray{T}) = CenterIndexedArray($f(B,A.data))
        ($f)(A::CenterIndexedArray, B::AbstractArray) = error("ambiguous container type")
        ($f)(B::AbstractArray, A::CenterIndexedArray) = error("ambiguous container type")
    end
end

writemime(io::IO, ::MIME"text/plain", X::CenterIndexedArray) =
    Base.with_output_limit(()->begin
        print(io, summary(X))
        !isempty(X) && println(io, ":")
        Base.showarray(io, X.data, header=false, repr=false)
    end)

show(io::IO, X::CenterIndexedArray) = show(io, X.data)
showcompact(io::IO, X::CenterIndexedArray) = showcompact(io, X.data)

# Remove when the LinearSlow patch gets merged
Base.vec(A::CenterIndexedArray) = vec(A.data)
Base.minimum(A::CenterIndexedArray) = minimum(A.data)
Base.maximum(A::CenterIndexedArray) = maximum(A.data)
function Base.findmin(A::CenterIndexedArray)
    val, idx = findmin(A.data)
    val, cia_index(A, idx)
end
function Base.findmax(A::CenterIndexedArray)
    val, idx = findmax(A.data)
    val, cia_index(A, idx)
end
function Base.findn(A::CenterIndexedArray)
    ret = findn(A.data)
    ntuple(d->ret[d]-A.halfsize[d]-1, ndims(A))
end


@generated function cia_index{T,N}(A::CenterIndexedArray{T,N}, idx)
    args = [:(s[$d]-A.halfsize[$d]-1) for d = 1:N]
    quote
        s = ind2sub(size(A), idx)
        CartesianIndex{N}(($(args...),))
    end
end

end  # module