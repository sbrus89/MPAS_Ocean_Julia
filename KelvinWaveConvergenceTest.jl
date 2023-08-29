#   Coastal Kelvin Wave Test Case
#   ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡

#   simulating a coastal kelvin wave

CODE_ROOT = pwd() * "/"

include(CODE_ROOT * "mode_init/MPAS_Ocean.jl")
include(CODE_ROOT * "mode_forward/time_steppers.jl")
include(CODE_ROOT * "visualization.jl")
include(CODE_ROOT * "mode_init/exactsolutions.jl")

using PyPlot
using PyCall

animation  = pyimport("matplotlib.animation")
ipydisplay = pyimport("IPython.display")

using LinearAlgebra # for norm()
import Dates
using DelimitedFiles



function model_run(mesh_directory, mesh_file_name, periodicity, T, output_path, nSaves=1;
        plot=false, animate=false, nvlevels=1)

    mpasOcean = MPAS_Ocean(mesh_directory, mesh_file_name, periodicity=periodicity, nvlevels=nvlevels)
    
    meanCoriolisParameterf = sum(mpasOcean.fEdge) / length(mpasOcean.fEdge)
    meanFluidThicknessH = sum(mpasOcean.bottomDepth)/length(mpasOcean.bottomDepth)
    c = sqrt(mpasOcean.gravity*meanFluidThicknessH)
    
    println("simulating for T: $T")
    lYedge = maximum(mpasOcean.yEdge) - minimum(mpasOcean.yEdge)

    println("generating exact methods for mesh")
    exactNormalVelocity, exactSSH, exactSolution!, boundaryCondition! = kelvinWaveGenerator(mpasOcean)
    #exactNormalVelocity, exactSSH, exactSolution! = inertiaGravityWaveGenerator(mpasOcean)
    
    println("setting up initial condition")
    exactSolution!(mpasOcean)
    mpasOcean.layerThicknessOld = copy(mpasOcean.layerThickness)
    mpasOcean.normalVelocityOld = copy(mpasOcean.normalVelocity)
    mpasOcean.layerThicknessNew = copy(mpasOcean.layerThickness)
    mpasOcean.normalVelocityNew = copy(mpasOcean.normalVelocity)
    
    sshExact = zeros(Float64, (mpasOcean.nCells))
    
    if plot
        calculate_ssh_new!(mpasOcean)
        sshExact = exactSSH(mpasOcean, 1:mpasOcean.nCells)
        plotSSHs(1, mpasOcean, sshExact, "Initial Condition", output_path)
    end
    
    println("original dt $(mpasOcean.dt)")
    nSteps = Int(round(T/mpasOcean.dt/nSaves))
    mpasOcean.dt = T / nSteps / nSaves
    
    println("dx $(mpasOcean.dcEdge[1]) \t dt $(mpasOcean.dt) \t dx/c $(maximum(mpasOcean.dcEdge) / c) \t dx/dt $(mpasOcean.dcEdge[1]/mpasOcean.dt)")
    
    t = 0
    for i in 1:nSaves
        for j in 1:nSteps
             
            forward_rk4!(mpasOcean,  t)
            #forward_backward_step!(mpasOcean)

            t += mpasOcean.dt

        end
        println("t: $t")
        if plot
            calculate_ssh_new!(mpasOcean)
            sshExact = exactSSH(mpasOcean, 1:mpasOcean.nCells, t)
            plotSSHs(i+1, mpasOcean, sshExact, "T = $(t)", output_path)
        end
    end

    sshExact = exactSSH(mpasOcean, 1:mpasOcean.nCells, t) 
    error = mpasOcean.ssh .- sshExact
    MaxErrorNorm = norm(error, Inf)
    L2ErrorNorm = norm(error/sqrt(float(mpasOcean.nCells)))
    
    return mpasOcean.nCells, mpasOcean.dt, MaxErrorNorm, L2ErrorNorm
end

function wrap_regex(str::AbstractString, maxlen = 92)
    replace(str, Regex(".{1,$maxlen}( |\$)") => @s_str "\\0\n")
end

function convergenceplot(nCellsX, errorNorm, normtype, T, decimals, output_path)
    A = [log10.(nCellsX)    ones(length(nCellsX))]
    m, c = A \ log10.(errorNorm)
    y = m*log10.(nCellsX) .+ c
    y = 10 .^ y
    
    slopestr ="$(round(m,digits=decimals))"
    while length(split(slopestr, ".")[end]) < decimals
        slopestr *= "0"
    end

    fig, ax = subplots(1,1, figsize=(9,9))
    tight_layout()
    ax.loglog(nCellsX, errorNorm, label="$normtype Error Norm", marker="s", linestyle="None", color="black")
    ax.loglog(nCellsX, y, label="Best Fit Line, slope=$slopestr", color="black")
    ax.set_title(wrap_regex("Convergence of $normtype Error Norm, Time Horizon = $(T) s", 50), fontsize=22, fontweight="bold")
    ax.legend(loc="upper right", fontsize=20)
    ax.set_xlabel("Number of cells", fontsize=20)
    ax.set_ylabel("$normtype error norm", fontsize=20)
    ax.grid(which="both")
    fname = "$output_path$(Dates.now())_$(normtype)"
    fig.savefig("$(fname)_convergence.png", bbox_inches="tight")
    
    return fig, ax
end

function plotSSHs(frame, mpasOcean, sshExact, desc="", output_path='.')
    fig, axs = plt.subplots(1, 3, figsize=(9,3))

    fig, ax = heatMapMesh(mpasOcean, mpasOcean.ssh, fig=fig, ax=axs[1])
    ax.set_title("Numerical Solution")

    fig, ax = heatMapMesh(mpasOcean, sshExact, fig=fig, ax=axs[2])
    ax.set_title("Exact Solution")
    
    fig, ax = heatMapMesh(mpasOcean, sshExact -  mpasOcean.ssh, fig=fig, ax=axs[3])#, cMin=-0.005, cMax=0.005)
    ax.set_title("Difference")
    
    fig.suptitle("SSH, $desc")
    
    fig.savefig("$(output_path)/ssh_cell_$(frame).png", bbox_inches="tight")
    
    return fig
end

function convergence_test(test_case;
                write_data=false, show_plots=true, decimals=2, resolutions=[64, 128, 256, 512],
                format=(x->string(x)), nvlevels=1)

    nCases = length(resolutions)
    nCellsX = collect(Int.(round.(resolutions)))
    ncells = zeros(Float64, nCases)
    dts = zeros(Float64, nCases)
    MaxErrorNorm = zeros(Float64, nCases)
    L2ErrorNorm = zeros(Float64, nCases)
    
    T = 15000
    
    for iCase = 1:nCases
        if test_case == "inertiaGravityWave"
            periodicity = "Periodic"
            mesh_directory = CODE_ROOT * "/MPAS_Ocean_Shallow_Water_Meshes/InertiaGravityWaveMesh/ConvergenceStudyMeshes"
            output_path = CODE_ROOT * "output/simulation_convergence/inertiagravitywave/timehorizon_$(T)/"
        elseif test_case == "kelvinWave"
            periodicity = "NonPeriodic_x"
            mesh_directory = CODE_ROOT * "/MPAS_Ocean_Shallow_Water_Meshes/CoastalKelvinWaveMesh/ConvergenceStudyMeshes"
            output_path = CODE_ROOT * "output/simulation_convergence/coastal_kelvinwave/timehorizon_$(T)/"
        end
        mkpath(output_path)
        mesh_file_name = "mesh_$(format(nCellsX[iCase])).nc"

        println()
        println("running test $iCase of $nCases, mesh: $mesh_file_name")
        ncells[iCase], dts[iCase], MaxErrorNorm[iCase], L2ErrorNorm[iCase] =
                model_run(mesh_directory, mesh_file_name, periodicity, T, output_path;
                        plot=show_plots, nvlevels=nvlevels)
    end
    
    
    if write_data
        fname = "$output_path$(Dates.now()).txt"
        open(fname, "w") do io
            writedlm(io, [ncells, dts, L2ErrorNorm, MaxErrorNorm])
        end
        println("saved to $fname")
    end
    
    if show_plots
        nCellsX = sqrt.(ncells)
        convergenceplot(nCellsX, MaxErrorNorm, "Maximum", T, 2, output_path)
        convergenceplot(nCellsX, L2ErrorNorm, "\$L^2\$", T, 2, output_path)
    end
end

convergence_test(
            "kelvinWave",
            resolutions=[32, 64, 144, 216, 324],
            format=(x->"$(x)x$(x)"),
            write_data=true, show_plots=true, nvlevels=1)

#convergence_test(
#            "inertiaGravityWave",
#            resolutions=[64, 144, 216, 324],
#            format=(x->"$(x)x$(x)"),
#            write_data=true, show_plots=true, nvlevels=1)
