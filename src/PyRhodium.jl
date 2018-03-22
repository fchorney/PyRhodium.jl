module PyRhodium

using PyCall
using PyPlot
using IterableTables
using NamedTuples
using Distributions

@pyimport rhodium

export
    Model, Parameter, Response, Lever, RealLever, IntegerLever, CategoricalLever, 
    PermutationLever, SubsetLever, Constraint, Brush, optimize, scatter2d, scatter3d, 
    pairs, parallel_coordinates, apply, evaluate, sample_lhs, set_parameters!, 
    set_levers!, set_responses!, set_constraints!, set_uncertainties!

# TBD: see if it works to simply call __init__(function) without storing the function
py"""
from rhodium import *
class JuliaModel(Model):
    
    def __init__(self, function, **kwargs):
        super(JuliaModel, self).__init__(self._evaluate)
        self.j_function = function
        
    def _evaluate(self, **kwargs):
        result = self.j_function(**kwargs)
        return result
"""

# Wrapper classes have a pyo field that holds a PyObject
abstract type Wrapper end

# Helper function for use with map(pyo, list-of-Wrappers)
pyo(obj) = obj.pyo

#
# Wrap Python objects in a thin julia wrapper so we can use the type system
#
struct Model <: Wrapper
    pyo::PyObject

    function Model(f)
        return new(py"JuliaModel($f)")
    end
end

struct Parameter <: Wrapper
    pyo::PyObject
    
    function Parameter(name::AbstractString, default_value::Any=nothing)
        return new(rhodium.Parameter(name, default_value=default_value))
    end
end

Parameter(name::Symbol, default_value::Any=nothing) = Parameter(String(name), default_value)

Parameter(pair::Pair{Symbol, Any}) = Parameter(pair.first, pair.second)


struct Response <: Wrapper
    pyo::PyObject

    function Response(name::AbstractString, kind::Symbol)
        kind in (:MAXIMIZE, :MINIMIZE, :INFO) || error("The kind argument must be either :MAXIMIZE or :MINIMIZE")

        return new(rhodium.Response(name, rhodium.Response[kind]))
    end
    
end

abstract type Lever  <: Wrapper end

struct IntegerLever <: Lever
    pyo::PyObject

    function IntegerLever(name::AbstractString, min_value::Int, max_value::Int; length::Int=1)
        return new(rhodium.IntegerLever(name, min_value, max_value, length=length))
    end
end

struct RealLever <: Lever
    pyo::PyObject

    function RealLever(name::AbstractString, min_value::Float64, max_value::Float64; length::Int=1)
        return new(rhodium.RealLever(name, min_value, max_value, length=length))
    end
end

struct CategoricalLever <: Lever
    pyo::PyObject

    function CategoricalLever(name::AbstractString, categories)
        return new(rhodium.CategoricalLever(name, categories))
    end
end

struct PermutationLever <: Lever
    pyo::PyObject

    function PermutationLever(name::AbstractString, options)
        return new(rhodium.PermutationLever(name, options))
    end
end

struct SubsetLever <: Lever
    pyo::PyObject

    function SubsetLever(name::AbstractString, options, size)
        return new(rhodium.SubsetLever(name, options, size))
    end
end

struct Constraint <: Wrapper
    pyo::PyObject

    function Constraint(con::AbstractString)
        return new(rhodium.Constraint(con))
    end

end

Constraint(con::Symbol) = Constraint(String(con))

struct Brush <: Wrapper
    pyo::PyObject

    function Brush(def::AbstractString)
        return new(rhodium.Brush(def))
    end
end

struct Output{T} <: Wrapper
    model::Model
    pyo::PyObject
end

# In rhodium, a dataset is a subclass of list that holds only dicts.
struct DataSet <: Wrapper
    pyo::PyObject   # a python DataSet

    function DataSet(pyo::PyObject)
        return new(pyo)
    end

    # A string argument is interpreted in the python func as a file to load
    function DataSet(data::Union{AbstractString, AbstractArray}=nothing)
        new(rhodium.DataSet(data))
    end
end

@generated function Base.getindex{T}(o::Output{T}, i::Int)
    expr = Expr(:call, :($T))
    for (i, t) in enumerate(T.parameters)
        push!(expr.args, :(o.pyo[i][$( String(fieldnames(T)[i]) )]))
    end

    quote        
        return $expr
    end
end

# Convert a dict to NamedTuple of type `T`
@generated function convert_to_NT{T}(::Type{T}, d::Dict)
    expr = Expr(:call, :($T))
    append!(expr.args, [:(d[$(String(name))]) for name in fieldnames(T)])
    return expr
end

function Base.length{T}(o::Output{T})
    return length(o.pyo)
end

function Base.eltype{T}(o::Output{T})
    return T
end

function Base.start{T}(iter::Output{T})
    return 1
end

function Base.findmax{T}(o::Output{T}, key::Symbol)
    res = o.pyo[:find_max](String(key))
    return convert_to_NT(T, res)
end

function Base.findmin{T}(o::Output{T}, key::Symbol)
    res = o.pyo[:find_min](String(key))
    return convert_to_NT(T, res)
end

function Base.find{T}(o::Output{T}, expr; inverse=false)
    res = o.pyo[:find](expr, inverse=inverse)
    return convert_to_NT.(T, res)
end

@generated function Base.next{T}(o::Output{T}, state)
    expr = Expr(:call, :($T))
    for (i, t) in enumerate(T.parameters)
        push!(expr.args, :(source[i][$( String(fieldnames(T)[i]) )]))
    end

    quote
        i = state
        source = o.pyo
        a = $expr
        return a, state + 1
    end
end

function Base.done{T}(o::Output{T}, state)
    return state > length(o)
end

"""
    set_parameters!(m::Model, parameters::Vector{Parameter})
    set_parameters!{T<:Union{Symbol,Pair{Symbol,Any}}}(m::Model, parameters::Vector{T})

Set model parameters using one of these forms:

  set_parameters!(m, [Parameter("a"), Parameter("b")...])

  # create parameters with the given names. Default values are `nothing`
  set_parameters!(m, [:a, :b, "c", ...])

  # create parameters with default values
  set_parameters!(m, [:name => 1, :name2 => 10.6])

"""
function set_parameters!(m::Model, parameters::Vector{Parameter})
    m.pyo[:parameters] = map(pyo, parameters)
    return nothing
end

set_parameters!{T<:Union{Symbol,Pair{Symbol,Any}}}(m::Model, v::Vector{T}) = set_parameters!(m, map(Parameter, v))

function set_responses!(m::Model, responses::Vector{Response})
    m.pyo[:responses] = map(pyo, responses)
    return nothing
end

function set_responses!(m::Model, responses::Vector{Pair{Symbol,Symbol}})
    m.pyo[:responses] = map(responses) do i        
        i.second in (:MAXIMIZE, :MINIMIZE, :INFO) || error("The kind argument must be either :MAXIMIZE or :MINIMIZE")
        return rhodium.Response(String(i.first), rhodium.Response[i.second])
    end
    nothing
end

function set_levers!(m::Model, levers::Vector{T}) where T <: Lever
    m.pyo[:levers] = map(pyo, levers)
    return nothing
end

function set_constraints!(m::Model, constraints::Vector{Constraint})
    m.pyo[:constraints] = map(pyo, constraints)
    return nothing
end

set_constraints!(m::Model, v::Vector) = set_constraints!(m, map(Constraint, v))

function set_uncertainties!(m::Model, uncertainties::Vector{Pair{Symbol,T}} where T)
    m.pyo[:uncertainties] = map(uncertainties) do i
        if i.second isa Uniform{Float64}
            rhodium.UniformUncertainty(string(i.first), i.second.a, i.second.b)
        else
            error("Distribution type $(typeof(i.second)) is not currently supported by Rhodium")
        end
    end
    return nothing
end

# Create a NamedTuple type expression from the contents of the given dict,
# returning the type or, if evaluate == false, the type expression.
function make_NT_type(dict::Dict; evaluate=true)
    names = map(Symbol, keys(dict))
    types = map(typeof, values(dict))
    col_exprs = [:($name::$etype) for (etype, name) in zip(types, names)]
    t_expr = NamedTuples.make_tuple(col_exprs)
    return evaluate ? eval(t_expr) : t_expr
end

function sample_lhs(m::Model, nsamples::Int)
    # returns a rhodium DataSet (a subclass of list), which holds (python) OrderedDicts
    py_output = pycall(rhodium.sample_lhs, PyAny, m.pyo, nsamples)
    
    # Use first result dict as template to create named tuple type, T
    T = make_NT_type(py_output[1])
    output = [T(values(i)...) for i in py_output]

    return output
end

function optimize(m::Model, algorithm, trials)
    py_output = pycall(rhodium.optimize, PyObject, m.pyo, algorithm, trials)

    T = length(py_output) > 0 ? make_NT_type(py_output[1]) : Any
    output = Output{T}(m, py_output)

    return output
end

function evaluate(m::Model, policy::Dict{Symbol,T} where T)
    py_output = pycall(rhodium.evaluate, PyDict, m.pyo, policy)

    T = make_NT_type(py_output[1])
    output = T(values(py_output)...)

    return output
end

function evaluate(m::Model, policies::Vector{Dict{Symbol,T}} where T)
    py_output = pycall(rhodium.evaluate, PyAny, m.pyo, policies)

    T = make_NT_type(py_output[1])
    output = [T(values(dict)...) for dict in py_output]

    return output
end

evaluate(m::Model, policy::NamedTuple) = evaluate(m, Dict(k=>v for (k,v) in zip(keys(policy), values(policy))))

evaluate(m::Model, policies::Vector{T} where T<:NamedTuple) = evaluate(m, [Dict(k => v for (k,v) in zip(keys(policy), values(policy))) for policy in policies])

function apply{T}(o::Output{T}, expr; update=true)
    println("apply($expr)")
    # In Rhodium, apply is a one-liner calling _evaluate_all(expr, self, update)
    res = pycall(o.pyo[:apply], PyAny, expr, update)
    # res = o.pyo[:apply](expr, update=update)
    return res
end

# function apply(m::Model, results::Vector{T} where T<:NamedTuple, expr; update=false)
#     x = [Dict(k => v for (k,v) in zip(keys(result), values(result))) for result in results])
#     res = apply(whatever, expr, update=update)
#     return res
# end

function _add_brush!(kwargs, brush)
    if brush != nothing
        push!(kwargs, (:brush, map(pyo, brush)))
    end
end

function scatter2d(o::Output; brush=nothing, kwargs...)
    _add_brush!(kwargs, brush)
    return rhodium.scatter2d(o.model.pyo, o.pyo; kwargs...)
end

function scatter3d(o::Output; brush=nothing, kwargs...)
    _add_brush!(kwargs, brush)
    return rhodium.scatter3d(o.model.pyo, o.pyo; kwargs...)
end

function pairs(o::Output; brush=nothing, kwargs...)
    _add_brush!(kwargs, brush)
    return rhodium.pairs(o.model.pyo, o.pyo; kwargs...)
end

function parallel_coordinates(o::Output; brush=nothing, kwargs...)
    _add_brush!(kwargs, brush)
    return rhodium.parallel_coordinates(o.model.pyo, o.pyo; kwargs...)
end

function use_seaborn(style="darkgrid")
    @pyimport seaborn as sns
    sns.set()
    sns.set_style(style)
end

end # module
