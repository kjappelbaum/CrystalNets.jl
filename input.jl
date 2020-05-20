
"""
    nextword(l, k)

Return the triplet of indices (i, j, x) such that l[i:j] is the next word in the
string l after position k.
Use k = x to get the following word, and so forth.

(0, 0, 0) is returned if there is no next word.
"""
function nextword(l, i)
    n = lastindex(l)
    i == n && return (0, 0, 0)

    i = nextind(l, i)
    start = 0
    while i <= n
        if isspace(l[i])
            i = nextind(l, i)
        else
            if l[i] == '#'
                i = findnext(isequal('\n'), l, i)
                i == nothing && return (0, 0, 0)
            else
                start = i
                break
            end
        end
    end
    start == 0 && return (0, 0, 0)

    inquote = l[start] == '\'' || l[start] == '"'
    quotesymb = l[start]
    inmultiline = l[start] == ';' && l[prevind(l,start)] == '\n'
    instatus = inmultiline | inquote
    instatus && (start = nextind(l, start); i = start)
    while i <= n
        c = l[i]
        if !isspace(c)
            if instatus
                if inmultiline && c == ';' && l[prevind(l,i)] == '\n'
                    return (start, prevind(l, i-1), i)
                elseif inquote && c == quotesymb && i != n &&
                        (isspace(l[nextind(l, i)]) || l[nextind(l, i)] == '#')
                    return (start, prevind(l, i), i)
                end
            elseif c == '#'
                return (start, prevind(l, i), prevind(l, i))
            end
            i = nextind(l, i)
        elseif !instatus
            return (start, prevind(l, i), i)
        else
            i = nextind(l, i)
        end
    end
    if instatus
        if inmultiline
            throw("Invalid syntax: opening multiline field at position $start is not closed")
        end
        if inquote
            throw("Invalid syntax: opening quote $quotesymb at position $start is not closed")
        end
    end
    return (start, n, n)
end

"""
    parse_cif(file)

Parse a CIF file and return a dictionary where each identifier (without the
starting '_' character) is linked to its value.
Values are either a string or a vector of string (if defined in a loop).
"""
function parse_cif(file)
    all_data = Dict{String, Union{String, Vector{String}}}()
    inloop = false
    loopisspecified = false
    loopspec = String[]
    loop_n = 0

    l = read(file, String)
    i, j, x = nextword(l, 0)
    while i != 0

        if inloop
            if !loopisspecified
                if l[i] != '_' # This indicates the start of the values
                    loop_n = length(loopspec)
                    loopisspecified = true
                else # The identifier is part of the loop specification
                    push!(loopspec, l[i+1:j])
                    all_data[l[i+1:j]] = String[]
                    i, j, x = nextword(l, x); continue
                end
            end

            # From this point, the loop has been specified
            @assert loopisspecified
            if l[i] != '_' && l[i:j] != "loop_"
                for k in 1:loop_n
                    push!(all_data[loopspec[k]], l[i:j])
                    i, j, x = nextword(l, x)
                end
                continue
            end
            if l[i:j] == "loop_"
                loopisspecified = false
                loopspec = String[]
                i, j, x = nextword(l, x); continue
            end

            # This point can only be reached if we just quitted a loop
            inloop = false
        end

        @assert !inloop
        if l[i] == '_' # Simple identifier definition
            next_i, next_j, next_x = nextword(l, x)
            @assert next_i != 0
            all_data[l[i+1:j]] = l[next_i:next_j]
            x = next_x
        else
            if l[i:j] == "loop_"
                inloop = true
                loopisspecified = false
                loopspec = String[]
            elseif j-i > 4 && l[i:i+4] == "data_"
                @assert !haskey(all_data, "data")
                all_data["data"] = l[i+5:j]
            else
                k = findprev(isequal('\n'), l, i)
                n = count("\n", l[1:k])
                throw("Unkown word \"$(l[i:j])\" at line $(n+1), position $(i-k):$(j-k)")
            end
        end

        i, j, x = nextword(l, x)
    end

    return all_data
end

function parsestrip(s)
    s = s[end] == ')' ? s[1:prevind(s, findlast('(', s))] : s
    return parse(BigFloat, s)
end


"""
    CIF(parsed_data)

Make a CIF object out of the parsed file.
"""
function CIF(parsed)
    natoms = length(parsed["atom_site_label"])
    cell = Cell(Symbol(haskey(parsed, "symmetry_cell_setting") ?
                            pop!(parsed, "symmetry_cell_setting") : ""),
                pop!(parsed, "symmetry_space_group_name_H-M"),
                haskey(parsed, "symmetry_Int_Tables_number") ?
                    parse(Int, pop!(parsed, "symmetry_Int_Tables_number")) : 0,
                parsestrip(pop!(parsed, "cell_length_a")),
                parsestrip(pop!(parsed, "cell_length_b")),
                parsestrip(pop!(parsed, "cell_length_c")),
                parsestrip(pop!(parsed, "cell_angle_alpha")),
                parsestrip(pop!(parsed, "cell_angle_beta")),
                parsestrip(pop!(parsed, "cell_angle_gamma")),
                parse.(EquivalentPosition, pop!(parsed,
                 haskey(parsed, "symmetry_equiv_pos_as_xyz") ?
                 "symmetry_equiv_pos_as_xyz" : "space_group_symop_operation_xyz"
                )))

    haskey(parsed, "symmetry_equiv_pos_site_id") && pop!(parsed, "symmetry_equiv_pos_site_id")
    removed_identity = false
    for i in eachindex(cell.equivalents)
        eq = cell.equivalents[i]
        if isone(eq.mat) && iszero(eq.ofs)
            deleteat!(cell.equivalents, i)
            removed_identity = true
            break
        end
    end
    @assert removed_identity

    labels =  pop!(parsed, "atom_site_label")
    _symbols = haskey(parsed, "atom_site_type_symbol") ?
                    pop!(parsed, "atom_site_type_symbol") : copy(labels)
    symbols = String[]
    @inbounds for x in _symbols
        i = findfirst(!isletter, x)
        push!(symbols, isnothing(i) ? x : x[1:i-1])
    end
    pos_x = pop!(parsed, "atom_site_fract_x")
    pos_y = pop!(parsed, "atom_site_fract_y")
    pos_z = pop!(parsed, "atom_site_fract_z")


    types = Symbol[]
    pos = Matrix{Float64}(undef, 3, natoms)
    correspondence = Dict{String, Int}()
    for i in 1:natoms
        @assert !haskey(correspondence, labels[i])
        correspondence[labels[i]] = i
        push!(types, Symbol(symbols[i]))
        pos[:,i] = parsestrip.([pos_x[i], pos_y[i], pos_z[i]])
    end
    ids = sortperm(types)
    types = types[ids]
    pos .= pos[:,ids]
    invids = invperm(ids)
    bonds = falses(natoms, natoms)
    if haskey(parsed, "geom_bond_atom_site_label_1") &&
       haskey(parsed, "geom_bond_atom_site_label_2")
        bond_a = pop!(parsed, "geom_bond_atom_site_label_1")
        bond_b = pop!(parsed, "geom_bond_atom_site_label_2")
        for i in 1:length(bond_a)
            x = invids[correspondence[bond_a[i]]]
            y = invids[correspondence[bond_b[i]]]
            bonds[x,y] = bonds[y,x] = 1
        end
    end
    return CIF(parsed, cell, ids, types, pos, bonds)
end

Crystal(parsed::Dict) = Crystal(CIF(parsed))



function parse_arc(file)
    pairs = Tuple{String,String}[]
    curr_key = ""
    counter = 1
    for l in eachline(file)
        if length(l) > 3 && l[1:3] == "key"
            @assert isempty(curr_key)
            i = 4
            while isspace(l[i])
                i += 1
            end
            curr_key = l[i:end]
        elseif length(l) > 2 && l[1:2] == "id"
            @assert !isempty(curr_key)
            i = 3
            while isspace(l[i])
                i += 1
            end
            push!(pairs, (l[i:end], curr_key))
            curr_key = ""
        end
    end
    return pairs
end
