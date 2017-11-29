# Canonical Correlation Analysis

#### CCA Type

type CCA{T<:Real}
    xmean::Vector{T}  # sample mean of X: of length dx (can be empty)
    ymean::Vector{T}  # sample mean of Y: of length dy (can be empty)  
    xproj::Matrix{T}  # projection matrix for X, of size (dx, p)
    yproj::Matrix{T}  # projection matrix for Y, of size (dy, p)
    corrs::Vector{T}  # correlations, of length p

    function CCA(xm::Vector{T}, 
                 ym::Vector{T}, 
                 xp::Matrix{T},
                 yp::Matrix{T}, 
                 crs::Vector{T}) where T <:Real

        dx, px = size(xp)
        dy, py = size(yp)

        isempty(xm) || length(xm) == dx ||
            throw(DimensionMismatch("Incorrect length of xmean."))

        isempty(ym) || length(ym) == dy ||
            throw(DimensionMismatch("Incorrect length of ymean."))

        px == py || 
            throw(DimensionMismatch("xproj and yproj should have the same number of columns."))

        length(crs) == px ||
            throw(DimensionMismatch("Incorrect length of corrs."))

        new{T}(xm, ym, xp, yp, crs)
    end
end

## properties

xindim(M::CCA) = size(M.xproj, 1)
yindim(M::CCA) = size(M.yproj, 1)
outdim(M::CCA) = size(M.xproj, 2)

xmean(M::CCA) = fullmean(xindim(M), M.xmean)
ymean(M::CCA) = fullmean(yindim(M), M.ymean)

xprojection(M::CCA) = M.xproj
yprojection(M::CCA) = M.yproj

correlations(M::CCA) = M.corrs

## use

xtransform(M::CCA, X::AbstractVecOrMat{<:Real}) = At_mul_B(M.xproj, centralize(X, M.xmean))
ytransform(M::CCA, Y::AbstractVecOrMat{<:Real}) = At_mul_B(M.yproj, centralize(Y, M.ymean))

## show & dump

function show(io::IO, M::CCA)
    print(io, "CCA (xindim = $(xindim(M)), yindim = $(yindim(M)), outdim = $(outdim(M)))")
end

function dump(io::IO, M::CCA)
    show(io, M)
    println(io)
    println(io, "correlations: ")
    printvecln(io, correlations(M))
    println(io, "xmean:")
    printvecln(io, xmean(M))
    println(io, "ymean:")
    printvecln(io, ymean(M))
    println(io, "xprojection:")
    printarrln(io, xprojection(M))
    println(io, "yprojection:")
    printarrln(io, yprojection(M))
end


#### Perform CCA on data

## ccacov

function ccacov(Cxx::DenseMatrix{<:Real}, 
                Cyy::DenseMatrix{<:Real},
                Cxy::DenseMatrix{<:Real}, 
                xmean::Vector{<:Real},
                ymean::Vector{<:Real},
                p::Int)

    # argument checking
    dx, dx2 = size(Cxx)
    dy, dy2 = size(Cyy)
    dx == dx2 || error("Cxx must be a square matrix.")
    dy == dy2 || error("Cyy must be a square matrix.")
    size(Cxy) == (dx, dy) || 
        throw(DimensionMismatch("size(Cxy) should be equal to (dx, dy)"))

    isempty(xmean) || length(xmean) == dx || 
        throw(DimensionMismatch("Incorrect length of xmean."))

    isempty(ymean) || length(ymean) == dy ||
        throw(DimensionMismatch("Incorrect length of ymean."))

    1 <= p <= min(dx, dy) ||
        throw(DimensionMismatch(""))

    _ccacov(Cxx, Cyy, Cxy, xmean, ymean, p)
end

function _ccacov(Cxx, Cyy, Cxy, xmean, ymean, p::Int)
    dx = size(Cxx, 1)
    dy = size(Cyy, 1)

    # solve Px and Py

    if dx <= dy
        # solve Px: (Cxy * inv(Cyy) * Cyx) Px = λ Cxx * Px
        # compute Py: inv(Cyy) * Cyx * Px

        G = cholfact(Cyy) \ Cxy'
        Ex = eigfact(Symmetric(Cxy * G), Symmetric(Cxx))
        ord = sortperm(Ex.values; rev=true)
        vx, Px = extract_kv(Ex, ord, p)
        Py = qnormalize!(G * Px, Cyy)
    else
        # solve Py: (Cyx * inv(Cxx) * Cxy) Py = λ Cyy Py
        # compute Px: inv(Cx) * Cxy * Py

        H = cholfact(Cxx) \ Cxy
        Ey = eigfact(Symmetric(Cxy'H), Symmetric(Cyy))
        ord = sortperm(Ey.values; rev=true)
        vy, Py = extract_kv(Ey, ord, p)
        Px = qnormalize!(H * Py, Cxx)
    end

    # compute correlations
    # Note: Px' * Cxx * Px == I
    #       Py' * Cyy * Py == I
    crs = coldot(Px, Cxy * Py)

    # construct CCA model
    CCA(xmean, ymean, Px, Py, crs)
end

## ccasvd

function ccasvd(Zx::DenseMatrix{<:Real}, 
                Zy::DenseMatrix{<:Real}, 
                xmean::Vector{<:Real}, 
                ymean::Vector{<:Real}, 
                p::Int)

    dx, n = size(Zx)
    dy, n2 = size(Zy)
    n == n2 || 
        throw(DimensionMismatch("Zx and Zy must have the same number of columns."))

    isempty(xmean) || length(xmean) == dx || 
        throw(DimensionMismatch("Incorrect length of xmean."))

    isempty(ymean) || length(ymean) == dy ||
        throw(DimensionMismatch("Incorrect length of ymean."))

    1 <= p <= min(dx, dy) ||
        throw(DimensionMismatch(""))

    _ccasvd(Zx, Zy, xmean, ymean, p)
end

# The implementation is partly based on:
#
#   David Weenink.
#   Canonical Correlation Analysis.
#   Institute of Phonetic Sciences, Univ. of Amsterdam, 
#   Proceedings 25 (2003), 81-99.
#
#   Note: in this paper, each row is considered as an observation.
#   The algorithm is adpated to the column-major format here.
#
function _ccasvd(Zx, Zy, xmean, ymean, p::Int)
    # svd factorization of Z

    n = size(Zx, 2)

    # svd decomposition
    Sx = svdfact(Zx)
    Sy = svdfact(Zy)
    S = svdfact!(A_mul_Bt(Sx.Vt, Sy.Vt)) # svd of Vx * Vy'

    # compute Px and Py
    ord = sortperm(S.S; rev=true)
    si = ord[1:p]
    Px = scale!(Sx.U, 1.0 ./ Sx.S) * S.U[:, si]
    Py = A_mul_Bt(scale!(Sy.U, 1.0 ./ Sy.S), S.Vt[si, :])

    # scale so that Px' * Cxx * Py == I 
    #           and Py' * Cyy * Py == I, 
    #
    # with Cxx = Zx * Zx' / (n - 1)
    #      Cyy = Zy * Zy' / (n - 1)
    #
    scale!(Px, sqrt(n-1))
    scale!(Py, sqrt(n-1))

    # compute correlations
    crs = scale!(coldot(Zx'Px, Zy'Py), inv(n-1))

    # construct CCA model
    CCA(xmean, ymean, Px, Py, crs)
end

## interface functions

function fit(::Type{CCA{<:Real}}, X::DenseMatrix{<:Real}, Y::DenseMatrix{<:Real};
             outdim::Int=min(min(size(X)...), min(size(Y)...)),
             method::Symbol=:svd, 
             xmean=nothing, 
             ymean=nothing)

    dx, n = size(X)
    dy, n2 = size(Y)

    n2 == n || 
        throw(DimensionMismatch("X and Y should have the same number of columns."))

    (n >= dx && n >= dy) || 
        warn("CCA would be numerically instable when n < dx or n < dy.")

    xmv = preprocess_mean(X, xmean)
    ymv = preprocess_mean(Y, ymean)

    Zx = centralize(X, xmv)
    Zy = centralize(Y, ymv)

    if method == :cov
        Cxx = scale!(A_mul_Bt(Zx, Zx), inv(n - 1))
        Cyy = scale!(A_mul_Bt(Zy, Zy), inv(n - 1))
        Cxy = scale!(A_mul_Bt(Zx, Zy), inv(n - 1))
        M = ccacov(Cxx, Cyy, Cxy, xmv, ymv, outdim)
    elseif method == :svd
        M = ccasvd(Zx, Zy, xmv, ymv, outdim)
    else
        error("Invalid method name $(method)")
    end

    return M::CCA
end
