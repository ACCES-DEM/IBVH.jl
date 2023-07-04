"""
    $(TYPEDEF)

Alias for a tuple of two indices representing e.g. a contacting pair.
"""
const IndexPair = Tuple{Int, Int}


"""
    $(TYPEDEF)

Collected BVH traversal `contacts` vector, some stats, plus the two buffers `cache1` and `cache2`
which can be reused for future traversals to minimise memory allocations.

# Fields
- `start_level::Int`: the level at which the traversal started.
- `num_checks::Int`: the total number of contact checks done.
- `num_contacts::Int`: the number of contacts found.
- `contacts::view(cache1, 1:num_contacts)`: the contacting pairs found, as a view into `cache1`.
- `cache1::C1{IndexPair} <: AbstractVector`: first BVH traversal buffer.
- `cache2::C2{IndexPair} <: AbstractVector`: second BVH traversal buffer.
"""
struct BVHTraversal{C1 <: AbstractVector, C2 <: AbstractVector}
    # Stats
    start_level::Int
    num_checks::Int

    # Data
    num_contacts::Int
    cache1::C1
    cache2::C2
end


# Custom pretty-printing
function Base.show(io::IO, t::BVHTraversal{C1, C2}) where {C1, C2}
    print(
        io,
        """
        BVHTraversal
          start_level:  $(typeof(t.start_level)) $(t.start_level)
          num_checks:   $(typeof(t.num_checks)) $(t.num_checks)
          num_contacts: $(typeof(t.num_contacts)) $(t.num_contacts)
          contacts:     $(Base.typename(typeof(t.contacts)).wrapper){IndexPair}($(size(t.contacts)))
          cache1:       $C1($(size(t.cache1)))
          cache2:       $C2($(size(t.cache2)))
        """
    )
end


function Base.getproperty(bt::BVHTraversal, sym::Symbol)
   if sym === :contacts
       return @view bt.cache1[1:bt.num_contacts]
   else
       return getfield(bt, sym)
   end
end

Base.propertynames(::BVHTraversal) = (:start_level, :num_checks, :contacts,
                                      :num_contacts, :cache1, :cache2)


"""
    traverse(
        bvh::BVH,
        start_level=max(bvh.tree.levels ÷ 2, bvh.built_level),
        cache::Union{Nothing, BVHTraversal}=nothing,
    )::BVHTraversal

Traverse `bvh` downwards from `start_level`, returning all contacting bounding volume leaves. The
returned [`BVHTraversal`](@ref) also contains two contact buffers that can be reused on future
traversals.
    
# Examples

```jldoctest
using ImplicitBVH
using ImplicitBVH: BBox, BSphere
using StaticArrays

# Generate some simple bounding spheres
bounding_spheres = [
    BSphere{Float32}(SA[0., 0., 0.], 0.5),
    BSphere{Float32}(SA[0., 0., 1.], 0.6),
    BSphere{Float32}(SA[0., 0., 2.], 0.5),
    BSphere{Float32}(SA[0., 0., 3.], 0.4),
    BSphere{Float32}(SA[0., 0., 4.], 0.6),
]

# Build BVH
bvh = BVH(bounding_spheres, BBox{Float32}, UInt32)

# Traverse BVH for contact detection
traversal = traverse(bvh, 2)

# Reuse traversal buffers for future contact detection - possibly with different BVHs
traversal = traverse(bvh, 2, traversal)
@show traversal.contacts;
;

# output
traversal.contacts = [(4, 5), (1, 2), (2, 3)]
```
"""
function traverse(
    bvh,
    start_level=max(bvh.tree.levels ÷ 2, bvh.built_level),
    cache::Union{Nothing, BVHTraversal}=nothing,
)

    @assert bvh.tree.levels >= start_level >= bvh.built_level

    # No contacts / traversal for a single node
    if bvh.tree.real_nodes <= 1
        return BVHTraversal(start_level, 0, 0,
                            similar(bvh.nodes, IndexPair, 0),
                            similar(bvh.nodes, IndexPair, 0))
    end

    # Allocate and add all possible BVTT contact pairs to start with
    bvtt1, bvtt2, num_bvtt = initial_bvtt(bvh, start_level, cache)
    num_checks = num_bvtt

    level = start_level
    while level < bvh.tree.levels
        # We can have maximum 4 new checks per contact-pair; resize destination BVTT accordingly
        length(bvtt2) < 4 * num_bvtt && resize!(bvtt2, 4 * 4 * num_bvtt)

        # Check contacts in bvtt1 and add future checks in bvtt2; only sprout self-checks before
        # second-to-last level as leaf self-checks are pointless
        self_checks = level < bvh.tree.levels - 1
        num_bvtt = traverse_nodes_atomic!(bvh, bvtt1, bvtt2, num_bvtt, self_checks)

        num_checks += num_bvtt

        # Swap source and destination buffers for next iteration
        bvtt1, bvtt2 = bvtt2, bvtt1
        level += 1
    end

    # Arrived at final leaf level, now populating contact list
    length(bvtt2) < num_bvtt && resize!(bvtt2, num_bvtt)
    num_bvtt = traverse_leaves_atomic!(bvh, bvtt1, bvtt2, num_bvtt)

    # Return contact list and the other buffer as possible cache
    BVHTraversal(start_level, num_checks, num_bvtt, bvtt2, bvtt1)
end


@inline function initial_bvtt(bvh, start_level, cache)
    # Generate all possible contact checks for the given start_level to avoid the very little
    # work to do at the top
    level_nodes = 2^(start_level - 1)
    level_checks = level_nodes * (level_nodes + 1) ÷ 2

    # If we're not at leaf-level, allocate enough memory for next BVTT expansion
    initial_number = start_level == bvh.tree.levels ? level_checks : 4 * level_checks

    if isnothing(cache)
        bvtt1 = similar(bvh.nodes, IndexPair, initial_number)
        bvtt2 = similar(bvh.nodes, IndexPair, initial_number)
    else
        bvtt1 = cache.cache1
        bvtt2 = cache.cache2

        length(bvtt1) < initial_number && resize!(bvtt1, initial_number)
        length(bvtt2) < initial_number && resize!(bvtt2, initial_number)
    end

    # Insert all node-node checks - i.e. no self-checks
    num_bvtt = 0
    num_real = level_nodes - bvh.tree.virtual_leaves >> (bvh.tree.levels - start_level)
    @inbounds for i in level_nodes:level_nodes + num_real - 2
        for j in i + 1:level_nodes + num_real - 1
            num_bvtt += 1
            bvtt1[num_bvtt] = (i, j)
        end
    end

    # Only insert self-checks if we still have nodes below us; leaf-level self-checks aren't needed
    if start_level != bvh.tree.levels
        @inbounds for i in level_nodes:level_nodes + num_real - 1
            num_bvtt += 1
            bvtt1[num_bvtt] = (i, i)
        end
    end

    bvtt1, bvtt2, num_bvtt
end


function traverse_nodes_atomic_range!(
    bvh, src, dst, num_written, self_checks, irange,
)
    # Check src[irange[1]:irange[2]] and write to dst[1:num_dst]; dst should be given as a view
    num_dst = 0

    # For each BVTT pair of nodes, check for contact
    @inbounds for i in irange[1]:irange[2]
        # Extract implicit indices of BVH nodes to test
        implicit1, implicit2 = src[i]

        # If self-check (1, 1), sprout children self-checks (2, 2) (3, 3) and pair children (2, 3)
        if implicit1 == implicit2

            # If the right child is virtual, only add left child self-check
            if isvirtual(bvh.tree, 2 * implicit1 + 1)
                if self_checks
                    dst[num_dst + 1] = (implicit1 * 2, implicit1 * 2)
                    num_dst += 1
                end
            else
                if self_checks
                    dst[num_dst + 1] = (implicit1 * 2, implicit1 * 2)
                    dst[num_dst + 2] = (implicit1 * 2 + 1, implicit1 * 2 + 1)
                    dst[num_dst + 3] = (implicit1 * 2, implicit1 * 2 + 1)
                    num_dst += 3
                else
                    dst[num_dst + 1] = (implicit1 * 2, implicit1 * 2 + 1)
                    num_dst += 1
                end
            end

        # Otherwise pair children of the two nodes
        else
            node1 = bvh.nodes[memory_index(bvh.tree, implicit1)]
            node2 = bvh.nodes[memory_index(bvh.tree, implicit2)]

            # If the two nodes are touching, expand BVTT with new possible contacts - i.e. pair
            # the nodes' children
            if iscontact(node1, node2)
                # If the right node's right child is virtual, don't add that check. Guaranteed to
                # always have node1 to the left of node2, hence its children will always be real
                if isvirtual(bvh.tree, 2 * implicit2 + 1)
                    dst[num_dst + 1] = (implicit1 * 2, implicit2 * 2)
                    dst[num_dst + 2] = (implicit1 * 2 + 1, implicit2 * 2)
                    num_dst += 2
                else
                    dst[num_dst + 1] = (implicit1 * 2, implicit2 * 2)
                    dst[num_dst + 2] = (implicit1 * 2, implicit2 * 2 + 1)
                    dst[num_dst + 3] = (implicit1 * 2 + 1, implicit2 * 2)
                    dst[num_dst + 4] = (implicit1 * 2 + 1, implicit2 * 2 + 1)
                    num_dst += 4
                end
            end
        end
    end

    # Known at compile-time; no return if called in multithreaded context
    if isnothing(num_written)
        return num_dst
    else
        num_written[] = num_dst
        return nothing
    end
end



function traverse_nodes_atomic!(bvh, src, dst, num_src, self_checks=true)
    # Traverse levels above leaves => no contacts, only further BVTT sprouting

    # Split computation into contiguous ranges of minimum 100 elements each; if only single thread
    # is needed, inline call
    tp = TaskPartitioner(num_src, Threads.nthreads(), 100)
    if tp.num_tasks == 1
        num_dst = traverse_nodes_atomic_range!(
            bvh,
            src, view(dst, :), nothing,
            self_checks,
            (1, num_src),
        )
    else
        num_dst = 0

        # Keep track of tasks launched and number of elements written by each task in their unique
        # memory region. The unique region is equal to 4 dst elements per src element
        tasks = Vector{Task}(undef, tp.num_tasks)
        num_written = Vector{Int}(undef, tp.num_tasks)
        @inbounds for i in 1:tp.num_tasks
            istart, iend = tp[i]
            tasks[i] = Threads.@spawn traverse_nodes_atomic_range!(
                bvh,
                src, view(dst, 4istart - 3:4iend), view(num_written, i),
                self_checks,
                (istart, iend),
            )
        end
        @inbounds for i in 1:tp.num_tasks
            wait(tasks[i])
            task_num_written = num_written[i]

            # Repack written contacts by the second, third thread, etc.
            if i > 1
                istart, iend = tp[i]
                for j in 1:task_num_written
                    dst[num_dst + j] = dst[4istart - 3 + j - 1]
                end
            end
            num_dst += task_num_written
        end
    end

    num_dst
end



@inline function traverse_leaves_atomic_range!(
    bvh, src, contacts, num_written, irange
)
    # Check src[irange[1]:irange[2]] and write to dst[1:num_dst]; dst should be given as a view
    num_dst = 0

    # Number of indices above leaf-level to subtract from real index
    num_above = bvh.tree.real_nodes - bvh.tree.real_leaves

    # For each BVTT pair of nodes, check for contact
    @inbounds for i in irange[1]:irange[2]
        # Extract implicit indices of BVH leaves to test
        implicit1, implicit2 = src[i]

        real1 = bvh.order[memory_index(bvh.tree, implicit1) - num_above]
        real2 = bvh.order[memory_index(bvh.tree, implicit2) - num_above]

        leaf1 = bvh.leaves[real1]
        leaf2 = bvh.leaves[real2]

        # If two leaves are touching, save in contacts
        if iscontact(leaf1, leaf2)
            contacts[num_dst + 1] = real1 < real2 ? (real1, real2) : (real2, real1)
            num_dst += 1
        end
    end

    # Known at compile-time; no return if called in multithreaded context
    if isnothing(num_written)
        return num_dst
    else
        num_written[] = num_dst
        return nothing
    end
end


function traverse_leaves_atomic!(bvh, src, contacts, num_src)
    # Traverse final level, only doing leaf-leaf checks

    # Split computation into contiguous ranges of minimum 100 elements each; if only single thread
    # is needed, inline call
    tp = TaskPartitioner(num_src, Threads.nthreads(), 100)
    if tp.num_tasks == 1
        num_contacts = traverse_leaves_atomic_range!(
            bvh,
            src, view(contacts, :), nothing,
            (1, num_src),
        )
    else
        num_contacts = 0

        # Keep track of tasks launched and number of elements written by each task in their unique
        # memory region. The unique region is equal to 1 dst elements per src element
        tasks = Vector{Task}(undef, tp.num_tasks)
        num_written = Vector{Int}(undef, tp.num_tasks)
        @inbounds for i in 1:tp.num_tasks
            istart, iend = tp[i]
            tasks[i] = Threads.@spawn traverse_leaves_atomic_range!(
                bvh,
                src, view(contacts, istart:iend), view(num_written, i),
                (istart, iend),
            )
        end
        @inbounds for i in 1:tp.num_tasks
            wait(tasks[i])
            task_num_written = num_written[i]

            # Repack written contacts by the second, third thread, etc.
            if i > 1
                istart, iend = tp[i]
                for j in 1:task_num_written
                    contacts[num_contacts + j] = contacts[istart + j - 1]
                end
            end
            num_contacts += task_num_written
        end
    end

    num_contacts
end
