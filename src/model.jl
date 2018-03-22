include("fpump.jl")

type SolutionObj
    solution    :: Vector{Float64}
    objval      :: Float64
end

type JuniperModel <: MathProgBase.AbstractNonlinearModel
    nl_solver       :: MathProgBase.AbstractMathProgSolver
   
    model           :: JuMP.Model
        
    status          :: Symbol
    objval          :: Float64
    best_bound      :: Float64

    x               :: Vector{JuMP.Variable}
    num_constr      :: Int64
    num_nl_constr   :: Int64
    num_l_constr    :: Int64
    num_var         :: Int64
    l_var           :: Vector{Float64}
    u_var           :: Vector{Float64}
    l_constr        :: Vector{Float64}
    u_constr        :: Vector{Float64}

    int2var_idx     :: Vector{Int64}
    var2int_idx     :: Vector{Int64}

    var_type        :: Vector{Symbol}
    isconstrlinear  :: Vector{Bool}
    obj_sense       :: Symbol
    d               :: MathProgBase.AbstractNLPEvaluator
    num_int_bin_var :: Int64

    solution        :: Vector{Float64}

    soltime         :: Float64
    options         :: SolverOptions
    solutions       :: Vector{SolutionObj}
    nsolutions      :: Int64

    mip_solver      :: MathProgBase.AbstractMathProgSolver

    relaxation_time :: Float64
    start_time      :: Float64

    # Info
    nintvars        :: Int64
    nbinvars        :: Int64
    nnodes          :: Int64
    ncuts           :: Int64
    nbranches       :: Int64
    nlevels         :: Int64

    fpump_info      :: Dict{Symbol,Float64}

    JuniperModel() = new()
end

"""
    MathProgBase.NonlinearModel(s::JuniperSolverObj)

Generate NonLinearModel and specify nl solver
"""
function MathProgBase.NonlinearModel(s::JuniperSolverObj)
    return JuniperNonlinearModel(s)
end

"""
    JuniperNonlinearModel(lqps::MathProgBase.AbstractMathProgSolver)

Initialize the NonLinearModel with the solver, set status, objval and solution
"""
function JuniperNonlinearModel(s::JuniperSolverObj)
    m = JuniperModel() # don't initialise everything yet

    m.nl_solver = s.nl_solver
    m.options = s.options
    m.status = :None
    m.objval = NaN
    m.best_bound = NaN
    m.solution = Float64[]
    m.nsolutions = 0
    m.solutions = []
    m.num_int_bin_var = 0
    m.num_nl_constr = 0
    m.num_l_constr = 0
    m.nintvars = 0
    m.nbinvars = 0
    m.nnodes = 1 # is set to one for the root node
    m.ncuts = 0
    m.nbranches = 0
    m.nlevels = 1
    m.relaxation_time = 0.0
    if m.options.mip_solver != nothing
        m.mip_solver = m.options.mip_solver
    end

    return m
end

"""
    MathProgBase.loadproblem!(m,num_var,num_constr,l_var,u_var,l_constr,u_constr,sense,d)

Initialize other fields JuniperModel after all variables, constraints and the objective is set
"""
function MathProgBase.loadproblem!(
    m::JuniperModel,
    num_var::Int, num_constr::Int,
    l_var::Vector{Float64}, u_var::Vector{Float64},
    l_constr::Vector{Float64}, u_constr::Vector{Float64},
    sense::Symbol, d::MathProgBase.AbstractNLPEvaluator)

    # initialise other fields
    m.num_var = num_var
    m.num_constr = num_constr
    m.l_var    = l_var
    m.u_var    = u_var
    m.l_constr = l_constr
    m.u_constr = u_constr
    m.d = d
    m.obj_sense = sense
    m.solution = fill(NaN, m.num_var)
    m.var_type = fill(:Cont,num_var)

    nw = nworkers()
    if nw < m.options.processors
        m.options.processors = nw
        warn("Julia was started with less processors then you define in your options")
    end

    MathProgBase.initialize(m.d, [:ExprGraph,:Jac,:Grad])
end

#=
    Used from https://github.com/lanl-ansi/POD.jl
=# 
function expr_dereferencing!(expr, m)
    for i in 2:length(expr.args)
        if isa(expr.args[i], Union{Float64,Int64})
            k = 0
        elseif expr.args[i].head == :ref
            @assert isa(expr.args[i].args[2], Int)
            expr.args[i] = Variable(m, expr.args[i].args[2])
        elseif expr.args[i].head == :call
            expr_dereferencing!(expr.args[i], m)
        else
            error("expr_dereferencing :: Unexpected term in expression tree.")
        end
    end
end

"""
    divide_nl_l_constr(m::JuniperModel)

Get # of linear and non linear constraints and save for each index if linear or non linear    
"""
function divide_nl_l_constr(m::JuniperModel)
    isconstrlinear = Array{Bool}(m.num_constr)
    m.num_l_constr = 0
    for i = 1:m.num_constr
        isconstrlinear[i] = MathProgBase.isconstrlinear(m.d, i)
        if isconstrlinear[i]
            m.num_l_constr += 1
        end
    end
    m.num_nl_constr = m.num_constr - m.num_l_constr  
    m.isconstrlinear = isconstrlinear
end

function replace_solution!(m::JuniperModel, best_known)
    m.solution = best_known.solution
    m.objval = best_known.objval
    m.status = best_known.status
    m.best_bound = best_known.best_bound # is reasonable for gap or time limit
end

function print_info(m::JuniperModel)
    println("#Variables: ", m.num_var)
    println("#IntBinVar: ", m.num_int_bin_var)
    println("#Constraints: ", m.num_constr)
    println("#Linear Constraints: ", m.num_l_constr)
    println("#NonLinear Constraints: ", m.num_nl_constr)
    println("Obj Sense: ", m.obj_sense)
    println()
end

function print_dict(d)
    longest_key_name = maximum([length(string(key)) for key in keys(d)])+2
    for key in keys(d)
        skey = string(key)
        pkey = skey*repeat(" ", longest_key_name-length(skey))
        println(pkey, ": ",d[key])
    end
end

function get_non_default_options(options)
    defaults = Juniper.get_default_options()
    non_defaults = Dict{Symbol,Any}()
    for fname in fieldnames(SolverOptions)
        # doesn't work for arrays but the only array atm is log_levels 
        # and the default doesn't include :Options therefore !== should work...
        if getfield(options,fname) !== getfield(defaults,fname)
            non_defaults[fname] = getfield(options,fname)
        end
    end
    return non_defaults
end

function print_options(m::JuniperModel;all=true)
    if all
        println(m.options)
    else
        print_dict(get_non_default_options(m.options))
    end
    println()
end

function parallel_init(m::JuniperModel)
    np = m.options.processors+1
    for p=2:np
        remotecall_fetch(srand, p, 1)
        sendto(p, m=m)
        sendto(p, is_newincumbent=false)
    end
end

function update_processor(relaxation_time, solution, objval, status)
    global m
    m.relaxation_time = relaxation_time
    m.solution = solution
    m.objval = objval
    m.status = status
end

"""
    parallel_update(m::JuniperModel)

Update relaxation_time, solution, objval and status on the processors
"""
function parallel_update(m::JuniperModel)
    np = m.options.processors+1
    @sync begin
        for p=1:np
            if p != myid() || np == 1
                @async begin
                    remotecall_fetch(update_processor, p, m.relaxation_time, m.solution, m.objval, m.status)
                end
            end
        end
    end
end


"""
    solve_relaxation(restart_values)

Solve the root relaxation using restart_values on a processor. The global JuniperModel is used.
"""
function solve_relaxation(restart_values)
    global m
    for i=1:m.num_var      
        setvalue(m.x[i], restart_values[i])
    end

    solve_start = time()
    status = solve(m.model)
    solve_time = time()-solve_start
    internal_model = internalmodel(m.model)
    if method_exists(MathProgBase.freemodel!, Tuple{typeof(internal_model)})
        MathProgBase.freemodel!(internal_model)
    end
    sol = getvalue(m.x)
    obj = getobjectivevalue(m.model)
    return status, obj, sol, solve_time
end

"""
    parallel_root_relaxation!(m::JuniperModel)

Calls solve_relaxation at least once on every processor so that every processor solved a model at least once.
If the number of `num_resolve_root_relaxation` is bigger than the number of processors and no feasible solution was 
found so far. Solve parallel with different restart values until Optimal or `num_resolve_root_relaxation` is reached.
"""
function parallel_root_relaxation!(m::JuniperModel)
    nw = m.options.processors
    np = nw+1
    opt_restarts = m.options.num_resolve_root_relaxation
    nrestarts = opt_restarts > nw ? opt_restarts : nw
    restart_values = Vector{Vector{Float64}}()
    for i=1:nrestarts
        push!(restart_values, generate_random_restart(m))
    end

    start_idx = 1

    nextidx() = (idx=start_idx; start_idx+=1; idx)

    worked_processors = falses(nw)

    best_sol = zeros(m.num_var)
    best_obj = m.obj_sense == :Max ? -Inf : Inf
    best_status = :None
    t_one_solve = 0.0

    @sync begin
        for p=1:np
            if p != myid() || np == 1
                @async begin
                    while true
                        idx = nextidx()
                        if idx > nrestarts || (best_status == :Optimal && sum(worked_processors) == nw) || time()-m.start_time >= m.options.time_limit
                            break
                        end
                        status, obj, sol, solve_time = remotecall_fetch(solve_relaxation, p, restart_values[idx])
                        worked_processors[p-1] = true
                        if best_status != :Optimal || (status == :Optimal && ((m.obj_sense == :Max && obj > best_obj) || (m.obj_sense == :Min && obj < best_obj)))
                            best_sol = sol
                            best_obj = obj
                            best_status = status
                            t_one_solve = solve_time
                        end
                    end
                end
            end
        end
    end
    return best_status, best_obj, best_sol, t_one_solve, nrestarts
end

"""
    MathProgBase.optimize!(m::JuniperModel)

Optimize by creating a model based on the variables saved in JuniperModel.
"""
function MathProgBase.optimize!(m::JuniperModel)
    ps = m.options.log_levels
    (:All in ps || :AllOptions in ps) && print_options(m;all=true)
    (:Options in ps) && print_options(m;all=false)

    srand(1)

    m.model = Model(solver=m.nl_solver)
    lb = m.l_var
    ub = m.u_var
    # all continuous we solve relaxation first
    @variable(m.model, lb[i] <= x[i=1:m.num_var] <= ub[i])

    # define the objective function
    obj_expr = MathProgBase.obj_expr(m.d)
    expr_dereferencing!(obj_expr, m.model)
    JuMP.setNLobjective(m.model, m.obj_sense, obj_expr)

    divide_nl_l_constr(m)
    (:All in ps || :Info in ps) && print_info(m)

    # add all constraints
    for i=1:m.num_constr
        constr_expr = MathProgBase.constr_expr(m.d,i)
        expr_dereferencing!(constr_expr, m.model)
        # add NL constraint (even if linear because .addconstraint doesn't work with expression)
        JuMP.addNLconstraint(m.model, constr_expr)
    end

    m.x = x
    m.start_time = time()

    if m.options.processors > 1
        parallel_init(m)
        best_status, best_obj, best_sol, t_one_solve, restarts = parallel_root_relaxation!(m)
        m.status = best_status
        m.relaxation_time = t_one_solve
        m.objval = best_obj
        m.solution = best_sol
        parallel_update(m)
    else
        m.status = solve(m.model)
        m.relaxation_time = time()-m.start_time
        restarts = 0
        max_restarts = m.options.num_resolve_root_relaxation
        while m.status != :Optimal && m.status != :LocalOptimal && 
            restarts < max_restarts && time()-m.start_time < m.options.time_limit

            internal_model = internalmodel(m.model)
            if method_exists(MathProgBase.freemodel!, Tuple{typeof(internal_model)})
                MathProgBase.freemodel!(internal_model)
            end
            restart_values = generate_random_restart(m)
            for i=1:m.num_var      
                setvalue(m.x[i], restart_values[i])
            end
            m.status = solve(m.model)
            restarts += 1
        end
        m.objval   = getobjectivevalue(m.model)
        m.solution = getvalue(m.x)
    end

    (:All in ps || :Info in ps) && println("Status of relaxation: ", m.status)

    m.soltime = time()-m.start_time
    if m.status != :Optimal && m.status != :LocalOptimal
        return m.status
    end
    
    (:All in ps || :Info in ps || :Timing in ps) && println("Time for relaxation: ", m.soltime)
  

    internal_model = internalmodel(m.model)
    if method_exists(MathProgBase.freemodel!, Tuple{typeof(internal_model)})
        MathProgBase.freemodel!(internal_model)
    end

    (:All in ps || :Info in ps || :Timing in ps) && println("Relaxation Obj: ", m.objval)

    inc_sol, inc_obj = nothing, nothing
    if m.num_int_bin_var > 0
        if m.options.feasibility_pump 
            inc_sol, inc_obj = fpump(m)
        end
        bnbtree = init(m.start_time, m; inc_sol = inc_sol, inc_obj = inc_obj)
        best_known = solvemip(bnbtree)

        replace_solution!(m, best_known)
        m.nsolutions = bnbtree.nsolutions
    else
        m.nsolutions = 1
        m.best_bound = getobjbound(m)
    end
    m.soltime = time()-m.start_time
    
    (:All in ps || :Info in ps) && println("Obj: ",m.objval)

    if length(m.solutions) == 0
        push!(m.solutions, SolutionObj(m.solution, m.objval))
    end

    return m.status
end

MathProgBase.setwarmstart!(m::JuniperModel, x) = x

"""
    MathProgBase.setvartype!(m::JuniperModel, v::Vector{Symbol}) 

Is called between loadproblem! and optimize! and has a vector v of types for each variable.
The number of int/bin variables is saved in num_int_bin_var
"""
function MathProgBase.setvartype!(m::JuniperModel, v::Vector{Symbol}) 
    m.var_type = v
    m.nintvars = count(i->(i==:Int), v)
    m.nbinvars = count(i->(i==:Bin), v)
    m.num_int_bin_var =  m.nintvars + m.nbinvars
    for (i,s) in enumerate(v)
        if s==:Bin
            m.l_var[i] = 0
            m.u_var[i] = 1
        end
    end
    m.int2var_idx = zeros(m.num_int_bin_var)
    m.var2int_idx = zeros(m.num_var)
    int_i = 1
    for i=1:m.num_var
        if m.var_type[i] != :Cont
            m.int2var_idx[int_i] = i
            m.var2int_idx[i] = int_i
            int_i += 1
        end
    end
end

MathProgBase.status(m::JuniperModel) = m.status

# any auxiliary variables will need to be filtered from this at some point
MathProgBase.getsolution(m::JuniperModel) = m.solution

MathProgBase.getsolvetime(m::JuniperModel) = m.soltime

MathProgBase.getobjval(m::JuniperModel) = m.objval

MathProgBase.getobjbound(m::JuniperModel) = m.best_bound

function MathProgBase.getobjgap(m::JuniperModel)
    b = m.best_bound
    if isnan(m.objval)
        return NaN
    else
        f = m.objval
        return abs(b-f)/abs(f)
    end
end

getnsolutions(m::JuniperModel) = m.nsolutions
getsolutions(m::JuniperModel) = m.solutions
getnbranches(m::JuniperModel) = m.nbranches