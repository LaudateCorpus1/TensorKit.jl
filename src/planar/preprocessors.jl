@noinline not_planar_err() = throw(ArgumentError("not a planar diagram expression"))
@noinline not_planar_err(ex) = throw(ArgumentError("not a planar diagram expression: $ex"))

# Preprocessors used by `@planar` and `@plansor`
function _conj_to_adjoint(ex::Expr)
    if ex.head == :call && ex.args[1] == :conj && TO.istensor(ex.args[2])
        obj, leftind, rightind = TO.decomposetensor(ex.args[2])
        return Expr(:typed_vcat, Expr(TO.prime, obj),
                        Expr(:tuple, rightind...), Expr(:tuple, leftind...))
    else
        return Expr(ex.head, [_conj_to_adjoint(a) for a in ex.args]...)
    end
end
_conj_to_adjoint(ex) = ex

# replacement of TensorOperations functionality:
# adds checks for matching number of domain and codomain indices
# special cases adjoints so that t and t' are considered the same object
# ignore braiding tensors
function _extract_tensormap_objects(ex)
    inputtensors = collect(filter(!=(:τ), _remove_adjoint.(TO.getinputtensorobjects(ex))))
    outputtensors = _remove_adjoint.(TO.getoutputtensorobjects(ex))
    newtensors = TO.getnewtensorobjects(ex)
    (any(==(:τ), newtensors) || any(==(:τ), outputtensors)) &&
        throw(ArgumentError("The name τ is reserved for the braiding, and should not be assigned to."))
    @assert !any(_is_adjoint, newtensors)
    existingtensors = unique!(vcat(inputtensors, outputtensors))
    alltensors = unique!(vcat(existingtensors, newtensors))
    tensordict = Dict{Any,Any}(a => gensym() for a in alltensors)
    pre = Expr(:block, [Expr(:(=), tensordict[a], a) for a in existingtensors]...)
    pre2 = Expr(:block)
    ex = TO.replacetensorobjects(ex) do obj, leftind, rightind
        _is_adj = _is_adjoint(obj)
        if _is_adj
            leftind, rightind = rightind, leftind
            obj = _remove_adjoint(obj)
        end
        newobj = get(tensordict, obj, obj)
        if (obj in existingtensors)
            nl = length(leftind)
            nr = length(rightind)
            nlsym = gensym()
            nrsym = gensym()
            objstr = string(obj)
            errorstr1 = "incorrect number of input-output indices: ($nl, $nr) instead of "
            errorstr2 = " for $objstr."
            checksize = quote
                $nlsym, $nrsym = numout($newobj), numin($newobj)
                ($nlsym == $nl && $nrsym == $nr) ||
                    throw(IndexError($errorstr1 * string(($nlsym, $nrsym)) * $errorstr2))
            end
            push!(pre2.args, checksize)
        end
        return _is_adj ? _add_adjoint(newobj) : newobj
    end
    post = Expr(:block, [Expr(:(=), a, tensordict[a]) for a in newtensors]...)
    pre = Expr(:macrocall, Symbol("@notensor"), LineNumberNode(@__LINE__, Symbol(@__FILE__)), pre)
    pre2 = Expr(:macrocall, Symbol("@notensor"), LineNumberNode(@__LINE__, Symbol(@__FILE__)), pre2)
    post = Expr(:macrocall, Symbol("@notensor"), LineNumberNode(@__LINE__, Symbol(@__FILE__)), post)
    return Expr(:block, pre, pre2, ex, post)
end
_is_adjoint(ex) = isa(ex, Expr) && ex.head == TO.prime
_remove_adjoint(ex) = _is_adjoint(ex) ? ex.args[1] : ex
_add_adjoint(ex) = Expr(TO.prime, ex)

# used by `@planar`: realize explicit braiding tensors
function _construct_braidingtensors(ex::Expr)
    if TO.isdefinition(ex) || TO.isassignment(ex)
        lhs, rhs = TO.getlhs(ex), TO.getrhs(ex)
        if TO.istensorexpr(rhs)
            list = TO.gettensors(_conj_to_adjoint(rhs))
            if TO.isassignment(ex) && TO.istensor(lhs)
                obj, l, r = TO.decomposetensor(lhs)
                lhs_as_rhs = Expr(:typed_vcat, _add_adjoint(obj),
                                    Expr(:tuple, r...), Expr(:tuple, l...))
                push!(list, lhs_as_rhs)
            end
        else
            return ex
        end
    elseif TO.istensorexpr(ex)
        list = TO.gettensors(_conj_to_adjoint(ex))
    else
        return Expr(ex.head, map(_construct_braidingtensors, ex.args)...)
    end

    i = 1
    translatebraidings = Dict{Any,Any}()
    while i <= length(list)
        t = list[i]
        if _remove_adjoint(TO.gettensorobject(t)) == :τ
            translatebraidings[t] = Expr(:call, GlobalRef(TensorKit, :BraidingTensor))
            deleteat!(list, i)
        else
            i += 1
        end
    end

    unresolved = Any[] # list of indices that we couldn't yet figure out
    indexmap = Dict{Any,Any}()
    # indexmap[i] contains the expression to resolve the space for index i
    for (t, construct_expr) in translatebraidings
        obj, leftind, rightind = TO.decomposetensor(t)
        length(leftind) == length(rightind) == 2 ||
            throw(ArgumentError("The name τ is reserved for the braiding, and should have two input and two output indices."))
        if _is_adjoint(obj)
            i1b, i2b, = leftind
            i2a, i1a, = rightind
        else
            i2b, i1b, = leftind
            i1a, i2a, = rightind
        end

        obj_and_pos1a = _findindex(i1a, list)
        obj_and_pos2a = _findindex(i2a, list)
        obj_and_pos1b = _findindex(i1b, list)
        obj_and_pos2b = _findindex(i2b, list)

        if !isnothing(obj_and_pos1a)
            indexmap[i1b] = Expr(:call, :space, obj_and_pos1a...)
            indexmap[i1a] = Expr(:call, :space, obj_and_pos1a...)
        elseif !isnothing(obj_and_pos1b)
            indexmap[i1b] = Expr(TO.prime, Expr(:call, :space, obj_and_pos1b...))
            indexmap[i1a] = Expr(TO.prime, Expr(:call, :space, obj_and_pos1b...))
        else
            push!(unresolved,(i1a,i1b))
        end

        if !isnothing(obj_and_pos2a)
            indexmap[i2b] = Expr(:call, :space, obj_and_pos2a...)
            indexmap[i2a] = Expr(:call, :space, obj_and_pos2a...)
        elseif !isnothing(obj_and_pos2b)
            indexmap[i2b] = Expr(TO.prime, Expr(:call, :space, obj_and_pos2b...))
            indexmap[i2a] = Expr(TO.prime, Expr(:call, :space, obj_and_pos2b...))
        else
            push!(unresolved,(i2a,i2b))
        end
    end
    # simple loop that tries to resolve as many indices as possible
    changed = true
    while changed == true
        changed = false
        i = 1
        while i <= length(unresolved)
            (i1, i2) = unresolved[i]
            if i1 in keys(indexmap)
                changed = true
                indexmap[i2] = indexmap[i1]
                deleteat!(unresolved, i)
            elseif i2 in keys(indexmap)
                changed = true
                indexmap[i1] = indexmap[i2]
                deleteat!(unresolved, i)
            else
                i += 1
            end
        end
    end
    !isempty(unresolved) &&
        throw(ArgumentError("cannot determine the spaces of indices " *
                                string(tuple(unresolved...)) *
                                    "for the braiding tensors in $(ex)"))

    pre = Expr(:block)
    for (t, construct_expr) in translatebraidings
        obj, leftind, rightind = TO.decomposetensor(t)
        if _is_adjoint(obj)
            i1b, i2b, = leftind
            i2a, i1a, = rightind
        else
            i2b, i1b, = leftind
            i1a, i2a, = rightind
        end
        push!(construct_expr.args, indexmap[i1b])
        push!(construct_expr.args, indexmap[i2b])
        s = gensym()
        push!(pre.args, Expr(:(=), s, construct_expr))
        ex = TO.replacetensorobjects(ex) do o, l, r
            if o == obj && l == leftind && r == rightind
                return obj  == :τ ? s : Expr(TO.prime, s)
            else
                return o
            end
        end
    end
    return Expr(:block, pre, ex)
end
_construct_braidingtensors(x) = x

# used by non-planar parser of `@plansor`: remove explicit braiding tensors
function _remove_braidingtensors(ex::Expr)
    outgoing = []

    if TO.isdefinition(ex) || TO.isassignment(ex)
        lhs, rhs = TO.getlhs(ex), TO.getrhs(ex)
        if TO.istensorexpr(rhs)
            list = TO.gettensors(_conj_to_adjoint(rhs))
            if TO.istensor(lhs)
                obj, l, r = TO.decomposetensor(lhs)
                outgoing = [l; r]
            end
        else
            return ex
        end
    elseif TO.istensorexpr(ex)
        list = TO.gettensors(_conj_to_adjoint(ex))
    else
        return Expr(ex.head, map(_remove_braidingtensors, ex.args)...)
    end

    τs = Any[]
    i = 1
    while i <= length(list)
        t = list[i]
        if _remove_adjoint(TO.gettensorobject(t)) == :τ
            push!(τs, t)
            deleteat!(list, i)
        else
            i += 1
        end
    end

    indexmap = Dict{Any,Any}()
    # to remove the braidingtensors, we need to map certain indices to other indices
    for t in τs
        obj, leftind, rightind = TO.decomposetensor(t)
        length(leftind) == length(rightind) == 2 ||
            throw(ArgumentError("The name τ is reserved for the braiding, and should have two input and two output indices."))
        if _is_adjoint(obj)
            i1b, i2b, = leftind
            i2a, i1a, = rightind
        else
            i2b, i1b, = leftind
            i1a, i2a, = rightind
        end

        i1a = get(indexmap, i1a, i1a)
        i1b = get(indexmap, i1b, i1b)
        i2a = get(indexmap, i2a, i2a)
        i2b = get(indexmap, i2b, i2b)

        obj_and_pos1a = _findindex(i1a, list)
        obj_and_pos2a = _findindex(i2a, list)
        obj_and_pos1b = _findindex(i1b, list)
        obj_and_pos2b = _findindex(i2b, list)

        if i1a in outgoing
            indexmap[i1a] = i1a
            indexmap[i1b] = i1a
        elseif i1b in outgoing
            indexmap[i1a] = i1b
            indexmap[i1b] = i1b
        else
            if i1a isa Int && i1b isa Int
                indexmap[i1a] = max(i1a, i1b)
                indexmap[i1b] = max(i1a, i1b)
            else
                indexmap[i1a] = i1a
                indexmap[i1b] = i1a
            end
        end

        if i2a in outgoing
            indexmap[i2a] = i2a
            indexmap[i2b] = i2a
        elseif i2b in outgoing
            indexmap[i2a] = i2b
            indexmap[i2b] = i2b
        else
            if i2a isa Int && i2b isa Int
                indexmap[i2a] = max(i2a, i2b)
                indexmap[i2b] = max(i2a, i2b)
            else
                indexmap[i2a] = i2a
                indexmap[i2b] = i2a
            end
        end
    end

    # simple loop that tries to simplify the indicemaps (a=>b,b=>c -> a=>c,b=>c)
    changed = true
    while changed == true
        changed = false
        i = 1
        for (k,v) in indexmap
            if v in keys(indexmap) && indexmap[v] != v
                changed = true
                indexmap[k] = indexmap[v]
            end
        end
    end

    ex = TO.replaceindices(i -> get(indexmap, i, i), ex)
    return _purge_braidingtensors(ex)
end
_remove_braidingtensors(x) = x

function _purge_braidingtensors(ex::Expr) # actually remove the braidingtensors
    args = collect(filter(ex.args) do a
        if a isa Expr && a.head == :call && a.args[1] == :conj
            a = a.args[2]
        end
        if a isa Expr && TO.istensor(a) && _remove_adjoint(TO.gettensorobject(a)) == :τ
            _, leftind, rightind = TO.decomposetensor(a)
            (leftind[1] == rightind[2] && leftind[2] == rightind[1]) ||
                throw(ArgumentError("unable to remove braiding tensor $a"))
            return false
        end
        return true
    end)

    # multiplication with only a single argument is (rightfully) seen as invalid syntax
    if ex.head == :call && args[1] == :* && length(args) == 2
        return _purge_braidingtensors(args[2])
    else
        return Expr(ex.head, map(_purge_braidingtensors, args)...)
    end
end
_purge_braidingtensors(x) = x

function _check_planarity(ex::Expr)
    if ex.head == :macrocall && ex.args[1] == Symbol("@notensor")
    elseif TO.isassignment(ex) || TO.isdefinition(ex)
        lhs, rhs = TO.getlhs(ex), TO.getrhs(ex)
        if TO.istensorexpr(rhs)
            if TO.istensorexpr(lhs)
                @assert TO.istensor(lhs)
                indlhs = only(get_possible_planar_indices(lhs)) # should have only one element
            else
                indlhs = Any[]
            end
            indsrhs = get_possible_planar_indices(rhs)
            isempty(indsrhs) && not_planar_err(rhs)
            i = findfirst(ind -> iscyclicpermutation(ind, indlhs), indsrhs)
            i === nothing && not_planar_err(ex)
        end
    else
        foreach(ex.args) do a
            _check_planarity(a)
        end
    end
    return ex
end
_check_planarity(ex) = ex

# decompose contraction trees in order to fix index order of temporaries
# to ensure that planarity is guaranteed
_decompose_planar_contractions(ex, temporaries) = ex
function _decompose_planar_contractions(ex::Expr, temporaries)
    if ex.head == :macrocall && ex.args[1] == Symbol("@notensor")
        return ex
    end
    if TO.isassignment(ex) || TO.isdefinition(ex)
        lhs, rhs = TO.getlhs(ex), TO.getrhs(ex)
        if TO.istensorexpr(rhs)
            pre = Vector{Any}()
            rhs = _extract_contraction_pairs(rhs, lhs, pre, temporaries)
            return Expr(:block, pre..., Expr(ex.head, lhs, rhs))
        else
            return ex
        end
    end
    if TO.istensorexpr(ex)
        pre = Vector{Any}()
        rhs = _extract_contraction_pairs(ex, (Any[], Any[]), pre, temporaries)
        return Expr(:block, pre..., rhs)
    end
    if ex.head == :block
        return Expr(ex.head,
                    [_decompose_planar_contractions(a, temporaries) for a in ex.args]...)
    end
    if ex.head == :for || ex.head == :function
        return Expr(ex.head, ex.args[1],
                        _decompose_planar_contractions(ex.args[2], temporaries))
    end
    return ex
end

# decompose a contraction into elementary binary contractions of tensors without inner traces
# if lhs is an expression, it contains the existing lhs and thus the index order
# if lhs is a tuple, the result is a temporary object and the tuple (lind, rind) gives a suggestion for the preferred index order
function _extract_contraction_pairs(rhs, lhs, pre, temporaries)
    if TO.isscalarexpr(rhs)
        return rhs
    elseif TO.isgeneraltensor(rhs)
        if TO.hastraceindices(rhs) && lhs isa Tuple
            s = gensym()
            newlhs = Expr(:typed_vcat, s, Expr(:tuple, lhs[1]...), Expr(:tuple, lhs[2]...))
            push!(temporaries, s)
            push!(pre, Expr(:(:=), newlhs, rhs))
            return newlhs
        else
            return rhs
        end
    elseif rhs.head == :call && rhs.args[1] == :*
        @assert length(rhs.args) == 3

        if lhs isa Expr
            _, leftind, rightind = TO.decomposetensor(lhs)
        else
            leftind, rightind = lhs
        end
        lhs_ind = vcat(leftind, reverse(rightind))

        # find possible planar order
        rhs_inds = Any[]
        for ind1 in get_possible_planar_indices(rhs.args[2])
            for ind2 in get_possible_planar_indices(rhs.args[3])
                for (oind1, oind2, cind1, cind2) in possible_planar_complements(ind1, ind2)
                    if iscyclicpermutation(vcat(oind1, oind2), lhs_ind)
                        push!(rhs_inds, (ind1, ind2, oind1, oind2, cind1, cind2))
                    end
                    isempty(rhs_inds) || break
                end
                isempty(rhs_inds) || break
            end
            isempty(rhs_inds) || break
        end
        ind1, ind2, oind1, oind2, cind1, cind2 = only(rhs_inds) # inds_rhs should hold exactly one match
        if all(in(leftind), oind2) && all(in(rightind), oind1) # reverse order
            a1 = _extract_contraction_pairs(rhs.args[3], (oind2, reverse(cind2)), pre, temporaries)
            a2 = _extract_contraction_pairs(rhs.args[2], (cind1, reverse(oind1)), pre, temporaries)
            oind1, oind2 = oind2, oind1
            cind1, cind2 = cind2, cind1
        else
            a1 = _extract_contraction_pairs(rhs.args[2], (oind1, reverse(cind1)), pre, temporaries)
            a2 = _extract_contraction_pairs(rhs.args[3], (cind2, reverse(oind2)), pre, temporaries)
        end

        if TO.isscalarexpr(a1) || TO.isscalarexpr(a2)
            rhs = Expr(:call, :*, a1, a2)
            s = gensym()
            newlhs = Expr(:typed_vcat, s, Expr(:tuple, oind1...),
                                        Expr(:tuple, reverse(oind2)...))
            push!(temporaries, s)
            push!(pre, Expr(:(:=), newlhs, rhs))
            return newlhs
        end

        # note that index order in _extract... is only a suggestion, now we have actual index order
        _, l1, r1, = TO.decomposegeneraltensor(a1)
        _, l2, r2, = TO.decomposegeneraltensor(a2)
        if all(in(r1), oind1) && all(in(l2), oind2) # reverse order
            a1, a2 = a2, a1
            ind1, ind2 = ind2, ind1
            oind1, oind2 = oind2, oind1
        end
        if lhs isa Tuple
            rhs = Expr(:call, :*, a1, a2)
            s = gensym()
            newlhs = Expr(:typed_vcat, s, Expr(:tuple, oind1...),
                                        Expr(:tuple, reverse(oind2)...))
            push!(temporaries, s)
            push!(pre, Expr(:(:=), newlhs, rhs))
            return newlhs
        else
            if leftind == oind1 && rightind == reverse(oind2)
                rhs = Expr(:call, :*, a1, a2)
                return rhs
            elseif leftind == oind2 && rightind == reverse(oind1) # probably this can not happen anymore
                rhs = Expr(:call, :*, a2, a1)
                return rhs
            else
                rhs = Expr(:call, :*, a1, a2)
                s = gensym()
                newlhs = Expr(:typed_vcat, s, Expr(:tuple, oind1...),
                                            Expr(:tuple, reverse(oind2)...))
                push!(temporaries, s)
                push!(pre, Expr(:(:=), newlhs, rhs))
                return newlhs
            end
        end
    elseif rhs.head == :call && rhs.args[1] ∈ (:+, :-)
        args = [_extract_contraction_pairs(a, lhs, pre, temporaries) for
                    a in rhs.args[2:end]]
        return Expr(rhs.head, rhs.args[1], args...)
    else
        throw(ArgumentError("unknown tensor expression"))
    end
end

function _findindex(i, list) # finds an index i in a list of tensor expressions
    for t in list
        obj, l, r = TO.decomposetensor(t)
        pos = findfirst(==(i), l)
        isnothing(pos) || return (obj, pos)
        pos = findfirst(==(i), r)
        isnothing(pos) || return (obj, pos + length(l))
    end
    return nothing
end
