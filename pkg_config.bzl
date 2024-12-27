def _success(value):
    """Returns a successful result struct with the given `value`."""
    return struct(error = None, value = value)


def _error(message):
    """Returns a failure result struct with the given `message`."""
    return struct(error = message, value = None)


def _split(result):
    """Returns a list from splitting the value of `result` on space characters.

    If `result` is an error, it is propagated.

    Empty list elements are dropped."""
    if result.error != None:
        return result
    return _success([arg for arg in result.value.strip().split(" ") if arg])


def _find_binary(ctx, binary_name):
    binary = ctx.which(binary_name)
    if binary == None:
        return _error("Unable to find binary: {}".format(binary_name))
    return _success(binary)


def _execute(ctx, binary, args):
    result = ctx.execute([binary] + args)
    if result.return_code != 0:
        return _error("Failed execute {} {}".format(binary, args))
    return _success(result.stdout)


def _pkg_config(ctx, pkg_config, pkg_name, args):
    return _execute(ctx, pkg_config, [pkg_name] + args)


def _check(ctx, pkg_config, pkg_name):
    exist = _pkg_config(ctx, pkg_config, pkg_name, ["--exists"])
    if exist.error != None:
        return _error("Package {} does not exist".format(pkg_name))

    if ctx.attr.version != "":
        version = _pkg_config(ctx, pkg_config, pkg_name, ["--exact-version", ctx.attr.version])
        if version.error != None:
            return _error("Require {} version = {}".format(pkg_name, ctx.attr.version))

    if ctx.attr.min_version != "":
        version = _pkg_config(ctx, pkg_config, pkg_name, ["--atleast-version", ctx.attr.min_version])
        if version.error != None:
            return _error("Require {} version >= {}".format(pkg_name, ctx.attr.min_version))

    if ctx.attr.max_version != "":
        version = _pkg_config(ctx, pkg_config, pkg_name, ["--max-version", ctx.attr.max_version])
        if version.error != None:
            return _error("Require {} version <= {}".format(pkg_name, ctx.attr.max_version))

    return _success(None)


def _drop_prefix(flags, prefix):
    """Returns items of `flags` that start with `prefix`, with `prefix` dropped.
    """
    return [x[len(prefix):] for x in flags if x.startswith(prefix)]


def _includes(ctx, pkg_config, pkg_name):
    includes = _split(_pkg_config(ctx, pkg_config, pkg_name, ["--cflags-only-I"]))
    if includes.error != None:
        return includes
    includes = _drop_prefix(includes.value, "-I")
    return _success(includes)


def _copts(ctx, pkg_config, pkg_name):
    return _split(_pkg_config(ctx, pkg_config, pkg_name, [
        "--cflags-only-other",
        "--libs-only-L",
        "--static",
    ]))


def _linkopts(ctx, pkg_config, pkg_name):
    return _split(_pkg_config(ctx, pkg_config, pkg_name, [
        "--libs-only-other",
        "--libs-only-l",
        "--static",
    ]))


def _ignore_opts(opts, ignore_opts):
    remain = []
    for opt in opts:
        if opt not in ignore_opts:
            remain += [opt]
    return remain


def _path_to_identifier(path):
    return path.replace("_", "__").replace("/", "_slash_").replace(".", "_dot_")


def _symlink_includes(ctx, src_paths):
    """Creates symlinks `include/a/b/foo` for each `a/b/foo` under each of `src_paths`.

    This effectively merges the directories in `src_paths`. This should avoid
    collisions if there are multiple directories with the same name under
    different `src_paths`.

    Due to Starlark limitations, we cannot recursively traverse the entire
    directory tree for each of `src_paths`. As a result, this operation will
    fail if there are collisions in file names after the first few levels of
    directory structure. (It is okay if `src_paths[0]/a/foo.h` and
    `src_paths[1]/a/bar.h` both exist. The common `a` subdirectories will be
    merged. It is not okay if `src_paths[0]/a/b/c/d/e/f/g/foo.h` and
    `src_paths[1]/a/b/c/d/e/f/g/bar.h` both exist. The manually unrolled
    recursion will error out because the naming collisions go too deep.)

    Returns a success wrapping a list of the files (not including directories)
    symlinked under `include/`, or an error explaining why the process failed.
    """
    # print("will symlink each of {} items: {}".format(len(src_paths), src_paths))
    includes = []
    for src_root in src_paths:
        # print("working on src_root: {}".format(src_root))
        result = _symlink_tree_depth_0(ctx, ctx.path(src_root), includes)
        if result.error != None:
            return result
    # print("finished symlinking {}, includes: {}".format(src_paths, includes))
    return _success(includes)


def _symlink_tree_depth_0(ctx, root, acc):
    # print("enter depth 0: {}".format(root))
    prefix = str(root.dirname)
    if prefix[-1] != "/":
        prefix += "/"
    for child in root.readdir():
        # print("depth 0 examining: {}".format(child))
        if child.is_dir:
            # print("{} is dir".format(child))
            result = _symlink_tree_depth_1(ctx, child, acc)
            if result.error != None:
                return result
        else:
            # print("{} is not dir".format(child))
            local_path = str(child)[len(prefix):]
            # TODO: error if local_path exists.
            acc.append(local_path)
            _symlink_tolerate_redundancy(ctx, child, ctx.path("include").get_child(local_path))
    return _success(None)

def _symlink_tree_depth_1(ctx, root, acc):
    # print("enter depth 1: {}".format(root))
    prefix = str(root.dirname)
    if prefix[-1] != "/":
        prefix += "/"
    children = root.readdir()
    # print("depth 1 {} has {} children: {}".format(root, len(children), children))
    for child in children:
        # print("depth 1 examining: {}".format(child))
        if child.is_dir:
            # print("{} is dir".format(child))
            result = _symlink_tree_depth_2(ctx, child, acc)
            if result.error != None:
                return result
        else:
            # print("{} is not dir".format(child))
            local_path = str(child)[len(prefix):]
            # TODO: error if local_path exists.
            acc.append(local_path)
            _symlink_tolerate_redundancy(ctx, child, ctx.path("include").get_child(local_path))
    return _success(None)


def _symlink_tree_depth_2(ctx, root, acc):
    # print("enter depth 2: {}".format(root))
    prefix = str(root.dirname.dirname)
    if prefix[-1] != "/":
        prefix += "/"
    for child in root.readdir():
        # print("depth 2 examining: {}".format(child))
        local_path = str(child)[len(prefix):]
        # TODO: error if local_path exists.
        acc.append(local_path)
        _symlink_tolerate_redundancy(ctx, child, ctx.path("include").get_child(local_path))
    return _success(None)

# def _symlink_tree_a(recur, ctx, root, frontier, acc):
#     if frontier:
#         path = frontier.pop(0)
#         if path.is_dir:
#             for c in path.readdir():
#                 frontier.append(c)
#         else:
#             local_path = str(path)[len(root):]
#             acc.append(local_path)
#             ctx.symlink(path, ctx.path("includes").get_child(local_path))
#         return recur(ctx, root, frontier, acc)
#     else:
#         return acc


# def _symlink_tree_b(ctx, root, frontier, acc):
#     if frontier:
#         path = frontier.pop(0)
#         if path.is_dir:
#             for c in path.readdir():
#                 frontier.append(c)
#         else:
#             local_path = str(path)[len(root):]
#             acc.append(local_path)
#             ctx.symlink(path, ctx.path("includes").get_child(local_path))
#         return _symlink_tree_a(ctx, root, frontier, acc)
#     else:
#         return acc


def _symlink_tolerate_redundancy(ctx, src, dest):
    """Symlinks `src` to `dest`, unless `src` already exists and points to `dest`."""
    if dest.exists and src.realpath == dest.realpath:
        return
    # print("symlink {} to {}".format(src, dest))
    ctx.symlink(src, dest)


def _symlink_libs(ctx, lib_paths):
    libs = []
    for path in lib_paths:
        id = _path_to_identifier(path)
        local_lib_path = "libs/{}".format(id)
        _symlink_tolerate_redundancy(ctx, path, ctx.path("").get_child(local_lib_path))
        libs.append(local_lib_path)
    return libs


def _deps(ctx, pkg_config, pkg_name):
    deps = _split(_pkg_config(ctx, pkg_config, pkg_name, [
        "--libs-only-L",
        "--static",
    ]))
    if deps.error != None:
        return deps
    deps = _drop_prefix(deps.value, "-L")
    result = _symlink_libs(ctx, {d: True for d in deps}.keys())
    return _success(result)


def _fmt_array(array):
    return ",".join(['"{}"'.format(a) for a in array])


def _fmt_glob(array):
    return _fmt_array(["{}/**/*.h".format(a) for a in array])


def _pkg_config_impl(ctx):
    pkg_name = ctx.attr.pkg_name
    if pkg_name == "":
        pkg_name = ctx.attr.name

    pkg_config = _find_binary(ctx, "pkg-config")
    if pkg_config.error != None:
        return pkg_config
    pkg_config = pkg_config.value

    check = _check(ctx, pkg_config, pkg_name)
    if check.error != None:
        return check

    include_paths = _includes(ctx, pkg_config, pkg_name)
    if include_paths.error != None:
        return include_paths
    include_paths = include_paths.value
    includes = _symlink_includes(ctx, include_paths)
    if includes.error != None:
        return includes
    includes = includes.value
        
    ignore_opts = ctx.attr.ignore_opts
    copts = _copts(ctx, pkg_config, pkg_name)
    if copts.error != None:
        return copts
    copts = _ignore_opts(copts.value, ignore_opts)

    linkopts = _linkopts(ctx, pkg_config, pkg_name)
    if linkopts.error != None:
        return linkopts
    linkopts = _ignore_opts(linkopts.value, ignore_opts)

    deps = _deps(ctx, pkg_config, pkg_name)
    if deps.error != None:
        return deps
    deps = deps.value

    if ctx.attr.strip_include != "":
        strip_include_prefix = "include/{}".format(ctx.attr.strip_include_prefix)
    else:
        strip_include_prefix = "include/"

    # print("includes: {}".format(includes))
    build = ctx.template("BUILD", Label("//:BUILD.tmpl"), substitutions = {
        "%{name}": ctx.attr.name,
        "%{includes}": _fmt_array(include_paths),
        "%{copts}": _fmt_array(copts),
        "%{extra_copts}": _fmt_array(ctx.attr.copts),
        "%{deps}": _fmt_array(deps),
        "%{extra_deps}": _fmt_array(ctx.attr.deps),
        "%{linkopts}": _fmt_array(linkopts),
        "%{extra_linkopts}": _fmt_array(ctx.attr.linkopts),
        "%{strip_include_prefix}": strip_include_prefix,
        "%{include_prefix}": ctx.attr.include_prefix,
    }, executable = False)


pkg_config = repository_rule(
    attrs = {
        "pkg_name": attr.string(doc = "Package name for pkg-config query, default to name."),
        "include_prefix": attr.string(doc = "Additional prefix when including file, e.g. third_party. Compatible with strip_include option to produce desired include paths."),
        "strip_include": attr.string(doc = "Strip prefix when including file, e.g. libs, files not included will be invisible. Compatible with include_prefix option to produce desired include paths."),
        "version": attr.string(doc = "Exact package version."),
        "min_version": attr.string(doc = "Minimum package version."),
        "max_version": attr.string(doc = "Maximum package version."),
        "deps": attr.string_list(doc = "Dependency targets."),
        "linkopts": attr.string_list(doc = "Extra linkopts value."),
        "copts": attr.string_list(doc = "Extra copts value."),
        "ignore_opts": attr.string_list(doc = "Ignore listed opts in copts or linkopts."),
    },
    local = True,
    implementation = _pkg_config_impl,
)
