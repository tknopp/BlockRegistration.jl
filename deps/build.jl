if Base.find_in_path("RFFT") == nothing
    Pkg.clone("git@github.com:HolyLab/RFFT.jl.git")
end

Pkg.checkout("Optim", "teh/constrained")
lines = cd(Pkg.dir("NLsolve")) do
    readstring(`git remote`)
end
if isempty(search(lines, "timfork"))
    cd(Pkg.dir("NLsolve")) do
        run(`git remote add timfork https://github.com/timholy/NLsolve.jl.git`)
        run(`git fetch timfork`)
        run(`git checkout -b old-optim timfork/old-optim`)
    end
else
    cd(Pkg.dir("NLsolve")) do
        run(`git checkout old-optim`)
    end
end

basedir = splitdir(splitdir(@__FILE__)[1])[1]
cd(joinpath(basedir, "src")) do
    run(`make`)
end
