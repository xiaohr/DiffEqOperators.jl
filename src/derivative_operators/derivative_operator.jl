get_type(::AbstractDerivativeOperator{T}) where {T} = T

function *(A::AbstractDerivativeOperator,x::AbstractVector)
    #=
        We will output a vector which is a supertype of the types of A and x
        to ensure numerical stability
    =#
    get_type(A) != eltype(x) ? error("DiffEqOperator and array are not of same type!") : nothing
    y = zeros(promote_type(eltype(A),eltype(x)), length(x))
    Base.A_mul_B!(y, A::AbstractDerivativeOperator, x::AbstractVector)
    return y
end


function *(A::AbstractDerivativeOperator,M::AbstractMatrix)
    #=
        We will output a vector which is a supertype of the types of A and x
        to ensure numerical stability
    =#
    get_type(A) != eltype(M) ? error("DiffEqOperator and array are not of same type!") : nothing
    y = zeros(promote_type(eltype(A),eltype(M)), size(M))
    Base.A_mul_B!(y, A::AbstractDerivativeOperator, M::AbstractMatrix)
    return y
end


function *(M::AbstractMatrix,A::AbstractDerivativeOperator)
    #=
        We will output a vector which is a supertype of the types of A and x
        to ensure numerical stability
    =#
    get_type(A) != eltype(M) ? error("DiffEqOperator and array are not of same type!") : nothing
    y = zeros(promote_type(eltype(A),eltype(M)), size(M))
    Base.A_mul_B!(y, A::AbstractDerivativeOperator, M::AbstractMatrix)
    return y
end


function *(A::AbstractDerivativeOperator,B::AbstractDerivativeOperator)
    # TODO: it will result in an operator which calculates
    #       the derivative of order A.dorder + B.dorder of
    #       approximation_order = min(approx_A, approx_B)
end


function negate!(arr::T) where T
    if size(arr,2) == 1
        scale!(arr,-one(eltype(arr)))
    else
        for row in arr
            scale!(row,-one(eltype(arr)))
        end
    end
end


struct DerivativeOperator{T<:Real,S<:SVector,LBC,RBC} <: AbstractDerivativeOperator{T}
    derivative_order    :: Int
    approximation_order :: Int
    dx                  :: T
    dimension           :: Int
    stencil_length      :: Int
    stencil_coefs       :: S
    boundary_point_count:: Tuple{Int,Int}
    boundary_length     :: Tuple{Int,Int}
    low_boundary_coefs  :: Ref{Vector{Vector{T}}}
    high_boundary_coefs :: Ref{Vector{Vector{T}}}
    boundary_condition  :: Ref{Tuple{Tuple{T,T,Any},Tuple{T,T,Any}}}
    t                   :: Ref{Int}

    Base.@pure function DerivativeOperator{T,S,LBC,RBC}(derivative_order::Int, approximation_order::Int, dx::T,
                                            dimension::Int, BC) where {T<:Real,S<:SVector,LBC,RBC}
        dimension            = dimension
        dx                   = dx
        stencil_length       = derivative_order + approximation_order - 1 + (derivative_order+approximation_order)%2
        bl                   = derivative_order + approximation_order
        boundary_length      = (bl,bl)
        bpc                  = stencil_length - div(stencil_length,2) + 1
        bpc_array            = [bpc,bpc]
        grid_step            = one(T)
        low_boundary_coefs   = Vector{T}[]
        high_boundary_coefs  = Vector{T}[]
        stencil_coefs        = convert(SVector{stencil_length, T}, calculate_weights(derivative_order, zero(T),
                               grid_step .* collect(-div(stencil_length,2) : 1 : div(stencil_length,2))))

        left_bndry = initialize_left_boundary!(Val{:LO},low_boundary_coefs,stencil_coefs,BC,derivative_order,
                                               grid_step,bl,bpc_array,dx,LBC)

        right_bndry = initialize_right_boundary!(Val{:LO},high_boundary_coefs,stencil_coefs,BC,derivative_order,
                                                 grid_step,bl,bpc_array,dx,RBC)

        boundary_condition = (left_bndry, right_bndry)
        boundary_point_count = (bpc_array[1],bpc_array[2])

        t = 0

        new(derivative_order, approximation_order, dx, dimension, stencil_length,
            stencil_coefs,
            boundary_point_count,
            boundary_length,
            low_boundary_coefs,
            high_boundary_coefs,
            boundary_condition,
            t
            )
    end
    DerivativeOperator{T}(dorder::Int,aorder::Int,dx::T,dim::Int,LBC::Symbol,RBC::Symbol;BC=(zero(T),zero(T))) where {T<:Real} =
        DerivativeOperator{T, SVector{dorder+aorder-1+(dorder+aorder)%2,T}, LBC, RBC}(dorder, aorder, dx, dim, BC)
end

#=
    This function is used to update the boundary conditions especially if they evolve with
    time.
=#
function DiffEqBase.update_coefficients!(A::DerivativeOperator{T,S,LBC,RBC};BC=nothing) where {T<:Real,S<:SVector,RBC,LBC}
    if BC != nothing
        LBC == :Robin ? (length(BC[1])==3 || error("Enter the new left boundary condition as a 1-tuple")) :
                        (length(BC[1])==1 || error("Robin BC needs a 3-tuple for left boundary condition"))

        RBC == :Robin ? length(BC[2])==3 || error("Enter the new right boundary condition as a 1-tuple") :
                        length(BC[2])==1 || error("Robin BC needs a 3-tuple for right boundary condition")

        left_bndry = initialize_left_boundary!(A.low_boundary_coefs[],A.stencil_coefs,BC,
                                               A.derivative_order,one(T),A.boundary_length[1],A.dx,LBC)

        right_bndry = initialize_right_boundary!(A.high_boundary_coefs[],A.stencil_coefs,BC,
                                                 A.derivative_order,one(T),A.boundary_length[2],A.dx,RBC)

        boundary_condition = (left_bndry, right_bndry)
        A.boundary_condition[] = boundary_condition
    end
end

#################################################################################################

#=
    This function sets us up to apply the boundary condition correctly. It returns a
    3-tuple which is basically the coefficients in the equation
                            a*u + b*du/dt = c(t)
    The RHS ie. 'c' can be a function of time as well and therefore it is implemented
    as an anonymous function.
=#
function initialize_left_boundary!(::Type{Val{:LO}},low_boundary_coefs,stencil_coefs,BC,derivative_order,grid_step::T,
                                   boundary_length,boundary_point_count,dx,LBC) where T
    stencil_length = length(stencil_coefs)

    if LBC == :None
        #=
            Val{:LO} is type parametrization on symbols. There are two different right_None_BC!
            functions, one for LinearOperator and one for UpwindOperator. So to select the correct
            function without changing the name, this trick has been applied.
        =#
        boundary_point_count[1] = div(stencil_length,2)
        return (zero(T),zero(T),left_None_BC!(Val{:LO},low_boundary_coefs,stencil_length,derivative_order,
                                              grid_step,boundary_length)*BC[1]*dx)
    elseif LBC == :Neumann
        return (zero(T),one(T),left_Neumann_BC!(Val{:LO},low_boundary_coefs,stencil_length,derivative_order,
                                                grid_step,boundary_length)*BC[1]*dx)
    elseif LBC == :Robin
        return (BC[1][1],-BC[1][2],left_Robin_BC!(Val{:LO},low_boundary_coefs,stencil_length,
                                                   BC[1],derivative_order,grid_step,
                                                   boundary_length,dx)*BC[1][3]*dx)
    elseif LBC == :Dirichlet0
        return (one(T),zero(T),zero(T)*BC[1])

    elseif LBC == :Dirichlet
        typeof(BC[1]) <: Real ? ret = t->BC[1] : ret = BC[1]
        return (one(T),zero(T),ret)

    elseif LBC == :Neumann0
        return (zero(T),one(T),zero(T))

    elseif LBC == :periodic
        return (zero(T),zero(T),zero(T))

    else
        error("Unrecognized Boundary Type!")
    end
end


#=
    This function sets us up to apply the boundary condition correctly. It returns a
    3-tuple which is basically the coefficients in the equation
                            a*u + b*du/dt = c(t)
    The RHS ie. 'c' can be a function of time as well and therefore it is implemented
    as an anonymous function.
=#
function initialize_right_boundary!(::Type{Val{:LO}},high_boundary_coefs,stencil_coefs,BC,derivative_order,grid_step::T,
                                    boundary_length,boundary_point_count,dx,RBC) where T
    stencil_length = length(stencil_coefs)

    if RBC == :None
        boundary_point_count[2] = div(stencil_length,2)
        #=
            Val{:LO} is type parametrization on symbols. There are two different right_None_BC!
            functions, one for LinearOperator and one for UpwindOperator. So to select the correct
            function without changing the name, this trick has been applied.
        =#
        return (zero(T),zero(T),right_None_BC!(Val{:LO},high_boundary_coefs,stencil_length,derivative_order,
                               grid_step,boundary_length)*BC[2]*dx)
    elseif RBC == :Neumann
        return (zero(T),one(T),right_Neumann_BC!(Val{:LO},high_boundary_coefs,stencil_length,derivative_order,
                                  grid_step,boundary_length)*BC[2]*dx)
    elseif RBC == :Robin
        return (BC[2][1],BC[2][2],right_Robin_BC!(Val{:LO},high_boundary_coefs,stencil_length,
                                                    BC[2],derivative_order,grid_step,
                                                    boundary_length,dx)*BC[2][3]*dx)
    elseif RBC == :Dirichlet0
        return (one(T),zero(T),zero(T)*BC[2])

    elseif RBC == :Dirichlet
        typeof(BC[2]) <: Real ? ret = t->BC[2] : ret = BC[2]
        return (one(T),zero(T),ret)

    elseif RBC == :Neumann0
        return (zero(T),one(T),zero(T))

    elseif RBC == :periodic
        return (zero(T),zero(T),zero(T))

    else
        error("Unrecognized Boundary Type!")
    end
end


function left_None_BC!(::Type{Val{:LO}},low_boundary_coefs,stencil_length,derivative_order,
                       grid_step::T,boundary_length) where T
    # Fixes the problem excessive boundary points
    boundary_point_count = div(stencil_length,2)
    l_diff               = zero(T)
    mid                  = div(stencil_length,2)

    for i in 1 : boundary_point_count
        # One-sided stencils require more points for same approximation order
        # TODO: I don't know if this is the correct stencil length for i > 1?
        push!(low_boundary_coefs, calculate_weights(derivative_order, (i-1)*grid_step, collect(zero(T) : grid_step : (boundary_length-1)*grid_step)))
    end
    return l_diff
end


function right_None_BC!(::Type{Val{:LO}},high_boundary_coefs,stencil_length,derivative_order,
                        grid_step::T,boundary_length) where T
    boundary_point_count = div(stencil_length,2)
    high_temp            = zeros(T,boundary_length)
    flag                 = derivative_order*boundary_point_count%2
    aorder               = boundary_length - 1
    r_diff               = zero(T)

    for i in 1 : boundary_point_count
        # One-sided stencils require more points for same approximation order
        push!(high_boundary_coefs, calculate_weights(derivative_order, -(i-1)*grid_step, reverse(collect(zero(T) : -grid_step : -(boundary_length-1)*grid_step))))
    end
    return r_diff
end


function left_Neumann_BC!(::Type{Val{:LO}},low_boundary_coefs,stencil_length,derivative_order,
                          grid_step::T,boundary_length) where T
    boundary_point_count = stencil_length - div(stencil_length,2) + 1
    first_order_coeffs   = zeros(T,boundary_length)
    original_coeffs      = zeros(T,boundary_length)
    l_diff               = one(T)
    mid                  = div(stencil_length,2)+1

    first_order_coeffs = calculate_weights(1, (0)*grid_step, collect(zero(T) : grid_step : (boundary_length-1)*grid_step))
    original_coeffs =  calculate_weights(derivative_order, (0)*grid_step, collect(zero(T) : grid_step : (boundary_length-1) * grid_step))
    l_diff = original_coeffs[end]/first_order_coeffs[end]
    scale!(first_order_coeffs, original_coeffs[end]/first_order_coeffs[end])
    # scale!(original_coeffs, first_order_coeffs[end]/original_coeffs[end])
    @. original_coeffs = original_coeffs - first_order_coeffs
    # copy!(first_order_coeffs, first_order_coeffs[1:end-1])
    push!(low_boundary_coefs, original_coeffs[1:end-1])

    for i in 2 : boundary_point_count
        #=  this means that a stencil will suffice ie. we dont't need to worry about the boundary point
            being considered in the low_boundary_coefs
        =#
        if i > mid
            pos=i-1
            push!(low_boundary_coefs, calculate_weights(derivative_order, pos*grid_step, collect(zero(T) : grid_step : (boundary_length-1) * grid_step)))
        else
            pos=i-2
            push!(low_boundary_coefs, append!([zero(T)],calculate_weights(derivative_order, pos*grid_step, collect(zero(T) : grid_step : (boundary_length-1) * grid_step))))
        end
    end

    return l_diff
end


function right_Neumann_BC!(::Type{Val{:LO}},high_boundary_coefs,stencil_length,derivative_order,
                           grid_step::T,boundary_length) where T
    boundary_point_count = stencil_length - div(stencil_length,2) + 1
    flag                 = derivative_order*boundary_point_count%2
    original_coeffs      = zeros(T,boundary_length)
    r_diff               = one(T)
    mid                  = div(stencil_length,2)+1

    # this part is to incorporate the value of first derivative at the right boundary
    first_order_coeffs = calculate_weights(1, (boundary_point_count-1)*grid_step,
                                           collect(zero(T) : grid_step : (boundary_length-1) * grid_step))
    reverse!(first_order_coeffs)
    isodd(flag) ? negate!(first_order_coeffs) : nothing

    copy!(original_coeffs, calculate_weights(derivative_order, (boundary_point_count-1)*grid_step,
                                             collect(zero(T) : grid_step : (boundary_length-1) * grid_step)))

    reverse!(original_coeffs)
    isodd(flag) ? negate!(original_coeffs) : nothing

    r_diff = original_coeffs[1]/first_order_coeffs[1]
    scale!(first_order_coeffs, original_coeffs[1]/first_order_coeffs[1])
    # scale!(original_coeffs, first_order_coeffs[1]/original_coeffs[1])
    @. original_coeffs = original_coeffs - first_order_coeffs
    # copy!(first_order_coeffs, first_order_coeffs[1:end-1])

    for i in 2 : boundary_point_count
        #=
            this means that a stencil will suffice ie. we dont't need to worry about the boundary point
            being considered in the high_boundary_coefs. Same code for low_boundary_coefs but reversed
            at the end
        =#
        if i > mid
            pos=i-1
            push!(high_boundary_coefs, calculate_weights(derivative_order, pos*grid_step,
                                                         collect(zero(T) : grid_step : (boundary_length-1) * grid_step)))
        else
            pos=i-2
            push!(high_boundary_coefs, append!([zero(T)],
                                               calculate_weights(derivative_order, pos*grid_step,
                                               collect(zero(T) : grid_step : (boundary_length-1) * grid_step))))
        end
    end
    if flag == 1
        negate!(high_boundary_coefs)
    end
    reverse!(high_boundary_coefs)
    push!(high_boundary_coefs, original_coeffs[2:end])
    return r_diff
end


function left_Robin_BC!(::Type{Val{:LO}},low_boundary_coefs,stencil_length,params,
                        derivative_order,grid_step::T,boundary_length,dx) where T
    boundary_point_count = stencil_length - div(stencil_length,2) + 1
    first_order_coeffs   = zeros(T,boundary_length)
    original_coeffs      = zeros(T,boundary_length)
    l_diff               = one(T)
    mid                  = div(stencil_length,2)+1

    # in Robin BC the left boundary has opposite sign by convention
    first_order_coeffs = -params[2]*calculate_weights(1, (0)*grid_step, collect(zero(T) : grid_step : (boundary_length-1)* grid_step))
    first_order_coeffs[1] += dx*params[1]
    original_coeffs =  calculate_weights(derivative_order, (0)*grid_step, collect(zero(T) : grid_step : (boundary_length-1) * grid_step))

    l_diff = original_coeffs[end]/first_order_coeffs[end]
    scale!(first_order_coeffs, original_coeffs[end]/first_order_coeffs[end])
    # scale!(original_coeffs, first_order_coeffs[end]/original_coeffs[end])
    @. original_coeffs = original_coeffs - first_order_coeffs
    # copy!(first_order_coeffs, first_order_coeffs[1:end-1])
    push!(low_boundary_coefs, original_coeffs[1:end-1])

    for i in 2 : boundary_point_count
        #=
            this means that a stencil will suffice ie. we dont't need to worry about the boundary point
            being considered in the low_boundary_coefs
        =#
        if i > mid
            pos=i-1
            push!(low_boundary_coefs, calculate_weights(derivative_order, pos*grid_step, collect(zero(T) : grid_step : (boundary_length-1) * grid_step)))
        else
            pos=i-2
            push!(low_boundary_coefs, append!([zero(T)],calculate_weights(derivative_order, pos*grid_step, collect(zero(T) : grid_step : (boundary_length-1) * grid_step))))
        end
    end

    return l_diff
end


function right_Robin_BC!(::Type{Val{:LO}},high_boundary_coefs,stencil_length,params,
                        derivative_order,grid_step::T,boundary_length,dx) where T
    boundary_point_count = stencil_length - div(stencil_length,2) + 1
    flag                 = derivative_order*boundary_point_count%2
    original_coeffs      = zeros(T,boundary_length)
    r_diff               = one(T)
    mid                  = div(stencil_length,2)+1

    first_order_coeffs = params[2]*calculate_weights(1, (boundary_point_count-1)*grid_step,
                                                     collect(zero(T) : grid_step : (boundary_length-1) * grid_step))
    first_order_coeffs[end] += dx*params[1]
    reverse!(first_order_coeffs)
    isodd(flag) ? negate!(first_order_coeffs) : nothing

    copy!(original_coeffs, calculate_weights(derivative_order, (boundary_point_count-1)*grid_step,
                                             collect(zero(T) : grid_step : (boundary_length-1) * grid_step)))
    reverse!(original_coeffs)
    isodd(flag) ? negate!(original_coeffs) : nothing

    r_diff = original_coeffs[1]/first_order_coeffs[1]
    scale!(first_order_coeffs, original_coeffs[1]/first_order_coeffs[1])
    # scale!(original_coeffs, first_order_coeffs[1]/original_coeffs[1])
    @. original_coeffs = original_coeffs - first_order_coeffs
    # copy!(first_order_coeffs, first_order_coeffs[1:end-1])

    for i in 2 : boundary_point_count
        #=
            this means that a stencil will suffice ie. we dont't need to worry about the boundary point
            being considered in the high_boundary_coefs. Same code for low_boundary_coefs but reversed
            at the end
        =#
        if i > mid
            pos=i-1
            push!(high_boundary_coefs, calculate_weights(derivative_order, pos*grid_step,
                                                         collect(zero(T) : grid_step : (boundary_length-1) * grid_step)))
        else
            pos=i-2
            push!(high_boundary_coefs, append!([zero(T)],
                                               calculate_weights(derivative_order,pos*grid_step,
                                                                 collect(zero(T) : grid_step : (boundary_length-1) * grid_step))))
        end
    end
    if flag == 1
        negate!(high_boundary_coefs)
    end
    reverse!(high_boundary_coefs)
    push!(high_boundary_coefs, original_coeffs[2:end])
    return r_diff
end

#################################################################################################


(L::DerivativeOperator)(u,p,t) = L*u
(L::DerivativeOperator)(du,u,p,t) = A_mul_B!(du,L,u)
get_LBC(::DerivativeOperator{A,B,C,D}) where {A,B,C,D} = C
get_RBC(::DerivativeOperator{A,B,C,D}) where {A,B,C,D} = D


# ~ bound checking functions ~
checkbounds(A::AbstractDerivativeOperator, k::Integer, j::Integer) =
    (0 < k ≤ size(A, 1) && 0 < j ≤ size(A, 2) || throw(BoundsError(A, (k,j))))

checkbounds(A::AbstractDerivativeOperator, kr::Range, j::Integer) =
    (checkbounds(A, first(kr), j); checkbounds(A,  last(kr), j))

checkbounds(A::AbstractDerivativeOperator, k::Integer, jr::Range) =
    (checkbounds(A, k, first(jr)); checkbounds(A, k,  last(jr)))

checkbounds(A::AbstractDerivativeOperator, kr::Range, jr::Range) =
    (checkbounds(A, kr, first(jr)); checkbounds(A, kr,  last(jr)))

checkbounds(A::AbstractDerivativeOperator, k::Colon, j::Integer) =
    (0 < j ≤ size(A, 2) || throw(BoundsError(A, (size(A,1),j))))

checkbounds(A::AbstractDerivativeOperator, k::Integer, j::Colon) =
    (0 < k ≤ size(A, 1) || throw(BoundsError(A, (k,size(A,2)))))


# BandedMatrix{A,B,C,D}(A::DerivativeOperator{A,B,C,D}) = BandedMatrix(full(A, A.stencil_length), A.stencil_length, div(A.stencil_length,2), div(A.stencil_length,2))

# ~~ getindex ~~
@inline function getindex(A::AbstractDerivativeOperator, i::Int, j::Int)
    @boundscheck checkbounds(A, i, j)
    mid = div(A.stencil_length, 2) + 1
    bpc = A.stencil_length - mid
    l = max(1, low(j, mid, bpc))
    h = min(A.stencil_length, high(j, mid, bpc, A.stencil_length, A.dimension))
    slen = h - l + 1
    if abs(i - j) > div(slen, 2)
        return 0
    else
        return A.stencil_coefs[mid + j - i]
    end
end

# scalar - colon - colon
@inline getindex(A::AbstractDerivativeOperator, kr::Colon, jr::Colon) = full(A)

@inline function getindex(A::AbstractDerivativeOperator, rc::Colon, j)
    T = eltype(A.stencil_coefs)
    v = zeros(T, A.dimension)
    v[j] = one(T)
    copy!(v, A*v)
    return v
end


# symmetric right now
@inline function getindex(A::AbstractDerivativeOperator, i, cc::Colon)
    T = eltype(A.stencil_coefs)
    v = zeros(T, A.dimension)
    v[i] = one(T)
    copy!(v, A*v)
    return v
end


# UnitRanges
@inline function getindex(A::AbstractDerivativeOperator, rng::UnitRange{Int}, cc::Colon)
    m = full(A)
    return m[rng, cc]
end


@inline function getindex(A::AbstractDerivativeOperator, rc::Colon, rng::UnitRange{Int})
    m = full(A)
    return m[rnd, cc]
end

@inline function getindex(A::AbstractDerivativeOperator, r::Int, rng::UnitRange{Int})
    m = A[r, :]
    return m[rng]
end


@inline function getindex(A::AbstractDerivativeOperator, rng::UnitRange{Int}, c::Int)
    m = A[:, c]
    return m[rng]
end


@inline function getindex(A::AbstractDerivativeOperator{T}, rng::UnitRange{Int}, cng::UnitRange{Int}) where T
    N = A.dimension
    if (rng[end] - rng[1]) > ((cng[end] - cng[1]))
        mat = zeros(T, (N, length(cng)))
        v = zeros(T, N)
        for i = cng
            v[i] = one(T)
            #=
                calculating the effect on a unit vector to get the matrix of transformation
                to get the vector in the new vector space.
            =#
            A_mul_B!(view(mat, :, i - cng[1] + 1), A, v)
            v[i] = zero(T)
        end
        return mat[rng, :]

    else
        mat = zeros(T, (length(rng), N))
        v = zeros(T, N)
        for i = rng
            v[i] = one(T)
            #=
                calculating the effect on a unit vector to get the matrix of transformation
                to get the vector in the new vector space.
            =#
            A_mul_B!(view(mat, i - rng[1] + 1, :), A, v)
            v[i] = zero(T)
        end
        return mat[:, cng]
    end
end

#=
    This the basic A_Mul_B! function which is broken up into 3 parts ie. handling the left
    boundary, handling the interior and handling the right boundary. Finally the vector is
    scaled appropriately according to the derivative order and the degree of discretizaiton.
    We also update the time stamp of the DerivativeOperator inside to manage time dependent
    boundary conditions.
=#
function Base.A_mul_B!(x_temp::AbstractVector{T}, A::AbstractDerivativeOperator{T}, x::AbstractVector{T}) where T<:Real
    convolve_BC_left!(x_temp, x, A)
    convolve_interior!(x_temp, x, A)
    convolve_BC_right!(x_temp, x, A)
    scale!(x_temp, 1/(A.dx^A.derivative_order))
    A.t[] += 1 # incrementing the internal time stamp
end

#=
    This definition of the A_mul_B! function makes it possible to apply the LinearOperator on
    a matrix and not just a vector. It basically transforms the rows one at a time.
=#
function Base.A_mul_B!(x_temp::AbstractArray{T,2}, A::AbstractDerivativeOperator{T}, M::AbstractMatrix{T}) where T<:Real
    if size(x_temp) == reverse(size(M))
        for i = 1:size(M,1)
            A_mul_B!(view(x_temp,i,:), A, view(M,i,:))
        end
    else
        for i = 1:size(M,2)
            A_mul_B!(view(x_temp,:,i), A, view(M,:,i))
        end
    end
end


# Base.length(A::AbstractDerivativeOperator) = A.stencil_length
Base.ndims(A::AbstractDerivativeOperator) = 2
Base.size(A::AbstractDerivativeOperator) = (A.dimension, A.dimension)
Base.length(A::AbstractDerivativeOperator) = reduce(*, size(A))


#=
    Currently, for the evenly spaced grid we have a symmetric matrix
=#
Base.transpose(A::AbstractDerivativeOperator) = A
Base.ctranspose(A::AbstractDerivativeOperator) = A
Base.issymmetric(::AbstractDerivativeOperator) = true

#=
    This function ideally should give us a matrix which when multiplied with the input vector
    returns the derivative. But the presence of different boundary conditons complicates the
    situation. It is not possible to incorporate the full information of the boundary conditions
    in the matrix as they are additive in nature. So in this implementation we will just
    return the inner stencil of the matrix transformation. The user will have to manually
    incorporate the BCs at the ends.
=#
function Base.full(A::AbstractDerivativeOperator{T}, N::Int=A.dimension) where T
    @assert N >= A.stencil_length # stencil must be able to fit in the matrix
    mat = zeros(T, (N, N))
    v = zeros(T, N)
    for i=1:N
        v[i] = one(T)
        #=
            calculating the effect on a unit vector to get the matrix of transformation
            to get the vector in the new vector space.
        =#
        A_mul_B!(view(mat,:,i), A, v)
        v[i] = zero(T)
    end
    return mat
end


#=
    This function ideally should give us a matrix which when multiplied with the input vector
    returns the derivative. But the presence of different boundary conditons complicates the
    situation. It is not possible to incorporate the full information of the boundary conditions
    in the matrix as they are additive in nature. So in this implementation we will just
    return the inner stencil of the matrix transformation. The user will have to manually
    incorporate the BCs at the ends.
=#
function Base.sparse(A::AbstractDerivativeOperator{T}) where T
    N = A.dimension
    mat = spzeros(T, N, N)
    v = zeros(T, N)
    row = zeros(T, N)
    for i=1:N
        v[i] = one(T)
        #=
            calculating the effect on a unit vector to get the matrix of transformation
            to get the vector in the new vector space.
        =#
        A_mul_B!(row, A, v)
        copy!(view(mat,:,i), row)
        row .= 0.*row;
        v[i] = zero(T)
    end
    return mat
end
