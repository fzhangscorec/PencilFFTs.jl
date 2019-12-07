#!/usr/bin/env julia

# Tests with a 3D Taylor-Green velocity field.
# https://en.wikipedia.org/wiki/Taylor%E2%80%93Green_vortex

using PencilFFTs

import MPI

using Test

include("include/FourierOperations.jl")
using .FourierOperations
import .FourierOperations: VectorField

const SAVE_VTK = false

if SAVE_VTK
    using WriteVTK
end

const DATA_DIMS = (16, 8, 16)
const GEOMETRY = ((0.0, 4pi), (0.0, 2pi), (0.0, 2pi))

const TG_U0 = 3.0
const TG_K0 = 2.0

const DEV_NULL = @static Sys.iswindows() ? "nul" : "/dev/null"

function taylor_green!(u_local::VectorField, g::Grid, u0=TG_U0, k0=TG_K0)
    u = global_view.(u_local)

    @inbounds for I in CartesianIndices(u[1])
        x, y, z = g[I]
        l = LinearIndices(u[1])[I]
        u[1][l] =  u0 * sin(k0 * x) * cos(k0 * y) * cos(k0 * z)
        u[2][l] = -u0 * cos(k0 * x) * sin(k0 * y) * cos(k0 * z)
        u[3][l] = 0
    end

    u_local
end

# Verify vorticity of Taylor-Green flow.
function check_vorticity_TG(ω_local::VectorField, g::Grid, comm,
                            u0=TG_U0, k0=TG_K0)
    ω = global_view.(ω_local)
    diff2 = zero(eltype(ω[1]))

    for I in CartesianIndices(ω[1])
        x, y, z = g[I]
        ω_TG = (
            -u0 * k0 * cos(k0 * x) * sin(k0 * y) * sin(k0 * z),
            -u0 * k0 * sin(k0 * x) * cos(k0 * y) * sin(k0 * z),
            2u0 * k0 * sin(k0 * x) * sin(k0 * y) * cos(k0 * z),
        )
        l = LinearIndices(ω[1])[I]
        for n = 1:3
            diff2 += (ω[n][l] - ω_TG[n])^2
        end
    end

    MPI.Allreduce(diff2, +, comm)
end

function fields_to_vtk(g::Grid, basename, fields::Vararg{Pair})
    isempty(fields) && return
    p = pencil(first(first(fields).second))
    g_pencil = g[p]  # local geometry
    xyz = ntuple(n -> g_pencil[n], 3)
    vtk_grid(basename, xyz) do vtk
        for p in fields
            name = p.first
            u = p.second
            vtk_point_data(vtk, u, name)
        end
    end
end

function main()
    MPI.Init()

    size_in = DATA_DIMS
    comm = MPI.COMM_WORLD
    Nproc = MPI.Comm_size(comm)
    rank = MPI.Comm_rank(comm)

    rank == 0 || redirect_stdout(open(DEV_NULL, "w"))

    pdims_2d = let pdims = zeros(Int, 2)
        MPI.Dims_create!(Nproc, pdims)
        pdims[1], pdims[2]
    end

    plan = PencilFFTPlan(size_in, Transforms.RFFT(), pdims_2d, comm,
                         permute_dims=Val(true))
    u = allocate_input(plan, Val(3))  # allocate vector field

    g = Grid(GEOMETRY, size_in, get_permutation(u[1]))
    taylor_green!(u, g)  # initialise TG velocity field

    uF = plan .* u  # apply 3D FFT

    gF = FourierGrid(GEOMETRY, size_in, get_permutation(uF[1]))
    ωF = similar.(uF)

    let div2 = divergence(uF, gF)
        div2_mean = MPI.Allreduce(div2, +, comm) / prod(size_in)
        @test div2_mean ≈ 0 atol=1e-16
    end

    curl!(ωF, uF, gF)
    ω = plan .\ ωF

    ω_err = check_vorticity_TG(ω, g, comm)
    @test ω_err ≈ 0 atol=1e-16

    if SAVE_VTK
        fields_to_vtk(g, "TG_proc_$(rank + 1)of$(Nproc)",
                      "u" => u, "ω" => ω)
    end

    MPI.Finalize()
end

main()
