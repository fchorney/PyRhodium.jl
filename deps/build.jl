using PyCall
using Conda

Conda.add("seaborn")
Conda.add("scikit-learn")
Conda.add("qt")
Conda.add("graphviz")
Conda.add("pydot")
Conda.add("platypus-opt", channel="conda-forge")

Conda.pip_interop(true)
Conda.pip("install", ["SALib", "mpldatacursor", "git+https://github.com/Project-Platypus/PRIM.git#egg=prim", "git+https://github.com/Project-Platypus/Rhodium.git#egg=rhodium"])
