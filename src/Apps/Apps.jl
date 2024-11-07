module Apps

using Pkg
using Pkg.Types: AppInfo, PackageSpec, Context, EnvCache, PackageEntry, Manifest, handle_repo_add!, handle_repo_develop!, write_manifest, write_project,
                 pkgerror, projectfile_path, manifestfile_path
using Pkg.Operations: print_single, source_path, update_package_add
using Pkg.API: handle_package_input!
using TOML, UUIDs
import Pkg.Registry

app_env_folder() = joinpath(first(DEPOT_PATH), "environments", "apps")
app_manifest_file() = joinpath(app_env_folder(), "AppManifest.toml")
julia_bin_path() = joinpath(first(DEPOT_PATH), "bin")

app_context() = Context(env=EnvCache(joinpath(app_env_folder(), "Project.toml")))


function rm_shim(name; kwargs...)
    Base.rm(joinpath(julia_bin_path(), name); kwargs...)
end

function get_project(sourcepath)
    project_file = projectfile_path(sourcepath)

    isfile(project_file) || error("Project file not found: $project_file")

    project = Pkg.Types.read_project(project_file)
    isempty(project.apps) && error("No apps found in Project.toml for package $(project.name) at version $(project.version)")
    return project
end


function overwrite_file_if_different(file, content)
    if !isfile(file) || read(file, String) != content
        mkpath(dirname(file))
        write(file, content)
    end
end

function get_max_version_register(pkg::PackageSpec, regs)
    max_v = nothing
    tree_hash = nothing
    for reg in regs
        if get(reg, pkg.uuid, nothing) !== nothing
            reg_pkg = get(reg, pkg.uuid, nothing)
            reg_pkg === nothing && continue
            pkg_info = Registry.registry_info(reg_pkg)
            for (version, info) in pkg_info.version_info
                info.yanked && continue
                if pkg.version isa VersionNumber
                    pkg.version == version || continue
                else
                    version in pkg.version || continue
                end
                if max_v === nothing || version > max_v
                    max_v = version
                    tree_hash = info.git_tree_sha1
                end
            end
        end
    end
    if max_v === nothing
        error("Suitable package version for $(pkg.name) not found in any registries.")
    end
    return (max_v, tree_hash)
end


##################
# Main Functions #
##################


function _resolve(manifest::Manifest, pkgname=nothing)
    for (uuid, pkg) in manifest.deps
        if pkgname !== nothing && pkg.name !== pkgname
            continue
        end
        if pkg.path == nothing
            projectfile = joinpath(app_env_folder(), pkg.name, "Project.toml")
            sourcepath = source_path(app_manifest_file(), pkg)
            project = get_project(sourcepath)
            project.entryfile = joinpath(sourcepath, "src", "$(project.name).jl")
            mkpath(dirname(projectfile))
            write_project(project, projectfile)
            package_manifest_file = manifestfile_path(sourcepath; strict=true)
            if package_manifest_file !== nothing
                cp(package_manifest_file, joinpath(app_env_folder(), pkg.name, basename(package_manifest_file)); force=true)
            end
            # Move manifest if it exists here.

            Pkg.activate(joinpath(app_env_folder(), pkg.name)) do
                Pkg.instantiate()
            end
        else
            # TODO: Not hardcode Project.toml
            projectfile = projectfile_path(source_path(app_manifest_file(), pkg))
        end

        # TODO: Julia path
        generate_shims_for_apps(pkg.name, pkg.apps, dirname(projectfile), joinpath(Sys.BINDIR, "julia"))
    end

    write_manifest(manifest, app_manifest_file())
end

function _gc()

end

function add(pkg::String)
    pkg = PackageSpec(pkg)
    add(pkg)
end

function add(pkg::Vector{PackageSpec})
    for p in pkg
        add(p)
    end
end


function add(pkg::PackageSpec)
    handle_package_input!(pkg)

    ctx = app_context()
    manifest = ctx.env.manifest
    new = false

    # Download package
    if pkg.repo.source !== nothing || pkg.repo.rev !== nothing
        entry = Pkg.API.manifest_info(ctx.env.manifest, pkg.uuid)
        pkg = update_package_add(ctx, pkg, entry, false)
        new = handle_repo_add!(ctx, pkg)
    else
        pkgs = [pkg]
        Pkg.Operations.registry_resolve!(ctx.registries, pkgs)
        Pkg.Operations.ensure_resolved(ctx, manifest, pkgs, registry=true)

        pkg.version, pkg.tree_hash = get_max_version_register(pkg, ctx.registries)

        new = Pkg.Operations.download_source(ctx, pkgs)
    end

    sourcepath = source_path(ctx.env.manifest_file, pkg)
    project = get_project(sourcepath)
    # TODO: Wrong if package itself has a sourcepath?

    entry = PackageEntry(;apps = project.apps, name = pkg.name, version = project.version, tree_hash = pkg.tree_hash, path = pkg.path, repo = pkg.repo, uuid=pkg.uuid)
    manifest.deps[pkg.uuid] = entry

    _resolve(manifest, pkg.name)
    @info "For package: $(pkg.name) installed apps $(join(keys(project.apps), ","))"
end

function develop(pkg::String)
    develop(PackageSpec(pkg))
end

function develop(pkg::Vector{PackageSpec})
    for p in pkg
        develop(p)
    end
end

function develop(pkg::PackageSpec)
    if pkg.path !== nothing
        pkg.path == abspath(pkg.path)
    end
    handle_package_input!(pkg)
    ctx = app_context()
    handle_repo_develop!(ctx, pkg, #=shared =# true)
    sourcepath = abspath(source_path(ctx.env.manifest_file, pkg))
    project = get_project(sourcepath)

    # Seems like the `.repo.source` field is not cleared.
    # At least repo-url is still in the manifest after doing a dev with a path
    # Figure out why for normal dev this is not needed.
    # XXX: Why needed?
    if pkg.path !== nothing
        pkg.repo.source = nothing
    end


    entry = PackageEntry(;apps = project.apps, name = pkg.name, version = project.version, tree_hash = pkg.tree_hash, path = sourcepath, repo = pkg.repo, uuid=pkg.uuid)
    manifest = ctx.env.manifest
    manifest.deps[pkg.uuid] = entry

    _resolve(manifest, pkg.name)
    @info "For package: $(pkg.name) installed apps: $(join(keys(project.apps), ","))"
end

function status(pkgs_or_apps::Vector)
    if isempty(pkgs_or_apps)
        status()
    else
        for pkg_or_app in pkgs_or_apps
            if pkg_or_app isa String
                pkg_or_app = PackageSpec(pkg_or_app)
            end
            status(pkg_or_app)
        end
    end
end

function status(pkg_or_app::Union{PackageSpec, Nothing}=nothing)
    # TODO: Sort.
    # TODO: Show julia version
    pkg_or_app = pkg_or_app === nothing ? nothing : pkg_or_app.name
    manifest = Pkg.Types.read_manifest(joinpath(app_env_folder(), "AppManifest.toml"))
    deps = Pkg.Operations.load_manifest_deps(manifest)

    is_pkg = pkg_or_app !== nothing && any(dep -> dep.name == pkg_or_app, values(manifest.deps))

    for dep in deps
        info = manifest.deps[dep.uuid]
        if is_pkg && dep.name !== pkg_or_app
            continue
        end
        if !is_pkg && pkg_or_app !== nothing
            if !(pkg_or_app in keys(info.apps))
                continue
            end
        end

        printstyled("[", string(dep.uuid)[1:8], "] "; color = :light_black)
        print_single(stdout, dep)
        println()
        for (appname, appinfo) in info.apps
            if !is_pkg && pkg_or_app !== nothing && appname !== pkg_or_app
                continue
            end
            printstyled("  $(appname) $(appinfo.julia_command) \n", color=:green)
        end
    end
end

#=
function precompile(pkg::Union{Nothing, String}=nothing)
    manifest = Pkg.Types.read_manifest(joinpath(app_env_folder(), "AppManifest.toml"))
    deps = Pkg.Operations.load_manifest_deps(manifest)
    for dep in deps
        # TODO: Parallel app compilation..?
        info = manifest.deps[dep.uuid]
        if pkg !== nothing && info.name !== pkg
            continue
        end
        Pkg.activate(joinpath(app_env_folder(), info.name)) do
            @info "Precompiling $(info.name)..."
            Pkg.precompile()
        end
    end
end
=#

function require_not_empty(pkgs, f::Symbol)
    pkgs === nothing && return
    isempty(pkgs) && pkgerror("app $f requires at least one package")
end

function rm(pkgs_or_apps::Union{Vector, Nothing})
    if pkgs_or_apps === nothing
        rm(nothing)
    else
        for pkg_or_app in pkgs_or_apps
            if pkg_or_app isa String
                pkg_or_app = PackageSpec(pkg_or_app)
            end
            rm(pkg_or_app)
        end
    end
end

function rm(pkg_or_app::Union{PackageSpec, Nothing}=nothing)
    pkg_or_app = pkg_or_app === nothing ? nothing : pkg_or_app.name

    require_not_empty(pkg_or_app, :rm)

    manifest = Pkg.Types.read_manifest(joinpath(app_env_folder(), "AppManifest.toml"))
    dep_idx = findfirst(dep -> dep.name == pkg_or_app, manifest.deps)
    if dep_idx !== nothing
        dep = manifest.deps[dep_idx]
        @info "Deleting all apps for package $(dep.name)"
        delete!(manifest.deps, dep.uuid)
        for (appname, appinfo) in dep.apps
            @info "Deleted $(appname)"
            rm_shim(appname; force=true)
        end
        if dep.path === nothing
            Base.rm(joinpath(app_env_folder(), dep.name); recursive=true)
        end
    else
        for (uuid, pkg) in manifest.deps
            app_idx = findfirst(app -> app.name == pkg_or_app, pkg.apps)
            if app_idx !== nothing
                app = pkg.apps[app_idx]
                @info "Deleted app $(app.name)"
                delete!(pkg.apps, app.name)
                rm_shim(app.name; force=true)
            end
            if isempty(pkg.apps)
                delete!(manifest.deps, uuid)
                Base.rm(joinpath(app_env_folder(), pkg.name); recursive=true)
            end
        end
    end

    Pkg.Types.write_manifest(manifest, app_manifest_file())
    return
end


#########
# Shims #
#########

const SHIM_COMMENT = Sys.iswindows() ? "REM " : "#"
const SHIM_VERSION = 1.0
const SHIM_HEADER = """$SHIM_COMMENT This file is generated by the Julia package manager.
                       $SHIM_COMMENT Shim version: $SHIM_VERSION"""


function generate_shims_for_apps(pkgname, apps, env, julia)
    for (_, app) in apps
        generate_shim(pkgname, app, env, julia)
    end
end

function generate_shim(pkgname, app::AppInfo, env, julia)
    filename = app.name * (Sys.iswindows() ? ".bat" : "")
    julia_bin_filename = joinpath(julia_bin_path(), filename)
    mkpath(dirname(filename))
    content = if Sys.iswindows()
        windows_shim(pkgname, julia, env)
    else
        bash_shim(pkgname, julia, env)
    end
    overwrite_file_if_different(julia_bin_filename, content)
    if Sys.isunix()
        chmod(julia_bin_filename, 0o755)
    end
end


function bash_shim(pkgname, julia::String, env)
    return """
        #!/usr/bin/env bash

        $SHIM_HEADER

        export JULIA_LOAD_PATH=$(repr(env))
        exec $julia \\
            --startup-file=no \\
            -m $(pkgname) \\
            "\$@"
        """
end

function windows_shim(pkgname, julia::String, env)
    return """
        @echo off
        set JULIA_LOAD_PATH=$(repr(env))

        $julia ^
            --startup-file=no ^
            -m $(pkgname) ^
            %*
        """
end


#=
#################
# PATH handling #
#################

function add_bindir_to_path()
    if Sys.iswindows()
        update_windows_PATH()
    else
        update_unix_PATH()
    end
end

function get_shell_config_file(julia_bin_path())
    home_dir = ENV["HOME"]
    # Check for various shell configuration files
    if occursin("/zsh", ENV["SHELL"])
        return (joinpath(home_dir, ".zshrc"), "path=('$julia_bin_path()' \$path)\nexport PATH")
    elseif occursin("/bash", ENV["SHELL"])
        return (joinpath(home_dir, ".bashrc"), "export PATH=\"\$PATH:$julia_bin_path()\"")
    elseif occursin("/fish", ENV["SHELL"])
        return (joinpath(home_dir, ".config/fish/config.fish"), "set -gx PATH \$PATH $julia_bin_path()")
    elseif occursin("/ksh", ENV["SHELL"])
        return (joinpath(home_dir, ".kshrc"), "export PATH=\"\$PATH:$julia_bin_path()\"")
    elseif occursin("/tcsh", ENV["SHELL"]) || occursin("/csh", ENV["SHELL"])
        return (joinpath(home_dir, ".tcshrc"), "setenv PATH \$PATH:$julia_bin_path()") # or .cshrc
    else
        return (nothing, nothing)
    end
end

function update_unix_PATH()
    shell_config_file, path_command = get_shell_config_file(julia_bin_path())
    if shell_config_file === nothing
        @warn "Failed to insert `.julia/bin` to PATH: Failed to detect shell"
        return
    end

    if !isfile(shell_config_file)
        @warn "Failed to insert `.julia/bin` to PATH: $(repr(shell_config_file)) does not exist."
        return
    end
    file_contents = read(shell_config_file, String)

    # Check for the comment fence
    start_fence = "# >>> julia apps initialize >>>"
    end_fence = "# <<< julia apps initialize <<<"
    fence_exists = occursin(start_fence, file_contents) && occursin(end_fence, file_contents)

    if !fence_exists
        open(shell_config_file, "a") do file
            print(file, "\n$start_fence\n\n")
            print(file, "# !! Contents within this block are managed by Julia's package manager Pkg !!\n\n")
            print(file, "$path_command\n\n")
            print(file, "$end_fence\n\n")
        end
    end
end

function update_windows_PATH()
    current_path = ENV["PATH"]
    occursin(julia_bin_path(), current_path) && return
    new_path = "$current_path;$julia_bin_path()"
    run(`setx PATH "$new_path"`)
end
=#

end
