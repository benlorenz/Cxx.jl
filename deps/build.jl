using Compat

if haskey(ENV, "PREBUILT_CI_BINARIES") && ENV["PREBUILT_CI_BINARIES"] == "1"
    # Try to download pre-built binaries
    if !isdir("build") || length(readdir("build")) == 0
        os_tag = Compat.Sys.isapple() ? "osx" : "linux"
        run(`rm -rf build/ src/`)
        filename = "llvm-$(os_tag)-$(Base.libllvm_version).tgz"
        run(`wget https://s3.amazonaws.com/julia-cxx/$filename`)
        run(`tar xzf $filename --strip-components=1`)
    end
end

#in case we have specified the path to the julia installation
#that contains the headers etc, use that
BASE_JULIA_BIN = get(ENV, "BASE_JULIA_BIN", JULIA_HOME)
if (BASE_JULIA_BIN == "/usr/bin")
    # system-wide installation
    BASE_JULIA_SRC = get(ENV, "BASE_JULIA_SRC", "/usr/share/julia")
else
    BASE_JULIA_SRC = get(ENV, "BASE_JULIA_SRC", joinpath(BASE_JULIA_BIN, "..", ".."))
end

#write a simple include file with that path
println("writing path.jl file")
s = """
const BASE_JULIA_BIN=$(sprint(show, BASE_JULIA_BIN))
export BASE_JULIA_BIN

const BASE_JULIA_SRC=$(sprint(show, BASE_JULIA_SRC))
export BASE_JULIA_SRC
"""
f = open(joinpath(dirname(@__FILE__),"path.jl"), "w")
write(f, s)
close(f)

println("Tuning for julia installation at $BASE_JULIA_BIN with sources possibly at $BASE_JULIA_SRC")

# Try to autodetect llvm directory and C++ ABI in use
llvm_path = (Compat.Sys.isapple() && VersionNumber(Base.libllvm_version) >= v"3.8") ? "libLLVM" : "libLLVM-$(Base.libllvm_version)"

try
    # needs LLVM_BUILD_LLVM_DYLIB
    llvm_lib_path = Libdl.dlpath(llvm_path)
catch
    # it seems there is no libLLVM, llvm might have been built with BUILD_SHARED_LIBS instead
    # this is the case for the gentoo sys-devel/llvm ebuild
    # lets try libLLVMSupport instead
    llvm_path = "libLLVMSupport.so"
    llvm_lib_path = Libdl.dlpath(llvm_path)
end

old_cxx_abi = searchindex(open(read, llvm_lib_path),Vector{UInt8}("_ZN4llvm3sys16getProcessTripleEv"),0) != 0
old_cxx_abi && (ENV["OLD_CXX_ABI"] = "1")

# FIXME: better detection whether USE_SYSTEM_LLVM was used
if BASE_JULIA_BIN != "/usr/bin" && BASE_JULIA_BIN != "/usr/local/bin"
    llvm_config_path = joinpath(BASE_JULIA_BIN,"..","tools","llvm-config")
    if isfile(llvm_config_path)
        info("Building julia source build")
        ENV["LLVM_CONFIG"] = llvm_config_path
        delete!(ENV,"LLVM_VER")
    else
        info("Building julia binary build")
        ENV["LLVM_VER"] = Base.libllvm_version
        ENV["JULIA_BINARY_BUILD"] = "1"
        ENV["PATH"] = string(JULIA_HOME,":",ENV["PATH"])
    end
else
    info("Building with system LLVM installation")
    ENV["LLVM_VER"] = Base.libllvm_version
    if haskey(ENV, "LLVM_PATH")
        llvm_config_pathjoinpath(ENV["LLVM_PATH"],"bin","llvm-config)
    else
        llvm_config_path = joinpath(Base.Filesystem.dirname(llvm_lib_path),"..","bin","llvm-config")
    end
    if !isfile(llvm_config_path)
        error("could not detect llvm directory, please specify ENV['LLVM_HOME'] manually")
    end
    ENV["USE_SYSTEM_LLVM"] = "1"
    ENV["LLVM_CONFIG"] = llvm_config_path
end

make = Compat.Sys.isbsd() && !Compat.Sys.isapple() ? `gmake` : `make`
run(`$make -j$(Sys.CPU_CORES) -f BuildBootstrap.Makefile BASE_JULIA_BIN=$BASE_JULIA_BIN BASE_JULIA_SRC=$BASE_JULIA_SRC`)
