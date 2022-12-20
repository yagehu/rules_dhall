load("//:defs.bzl", "ARCHS", "OSS")

DEFAULT = struct(
    release = "1.41.2",
    version = "1.7.11",
    archs = {
        "x86_64": {
            "linux": struct(
                sha256 = "2a83666ad5cd51ec73ce7ade29294bd2d7a9d44dc91502eb0d6a3008ebb7f4a9",
            ),
            "osx": struct(
                sha256 = "970f2a20e35b326f02b2ca7d28b227905b7eaa614e11a2239a3fff15d2495b82",
            ),
            "windows": struct(
                sha256 = "fbf48bb1c365cdd389ed32d1515e72f1766510395813bec5a92c74daa247aa24",
            ),
        },
    },
)

def _dhall_yaml_impl(ctx):
    dhall_to_yaml = ctx.toolchains[":toolchain_type"].dhall_to_yaml

    out = ctx.actions.declare_file(ctx.label.name + ".yaml")
    ctx.actions.run(
        outputs = [out],
        inputs = ctx.files.srcs,
        executable = dhall_to_yaml,
        arguments = ["--file", ctx.file.main.path, "--output", out.path],
    )

    return [
        DefaultInfo(files = depset([out])),
    ]

dhall_yaml = rule(
    implementation = _dhall_yaml_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "main": attr.label(allow_single_file = True),
    },
    toolchains = [":toolchain_type"],
)

def _dhall_json_toolchain_impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        dhall_to_json = ctx.file.dhall_to_json,
        dhall_to_yaml = ctx.file.dhall_to_yaml,
    )

    return [toolchain_info]

dhall_json_toolchain = rule(
    implementation = _dhall_json_toolchain_impl,
    attrs = {
        "dhall_to_json": attr.label(
            doc = "The location of the `dhall-to-json` binary. Can be a direct source or a filegroup containing one item.",
            allow_single_file = True,
            cfg = "exec",
            mandatory = True,
        ),
        "dhall_to_yaml": attr.label(
            doc = "The location of the `dhall-to-yaml` binary. Can be a direct source or a filegroup containing one item.",
            allow_single_file = True,
            cfg = "exec",
            mandatory = True,
        ),
    },
    provides = [platform_common.ToolchainInfo],
)

def _toolchain_repository_impl(repository_ctx):
    sha256 = repository_ctx.attr.sha256

    if repository_ctx.attr.release == DEFAULT.release and repository_ctx.attr.version == DEFAULT.version:
        sha256 = DEFAULT.archs[repository_ctx.attr.arch][repository_ctx.attr.os].sha256

    repository_ctx.download_and_extract(
        [
            "https://github.com/dhall-lang/dhall-haskell/releases/download/{release}/dhall-json-{version}-{arch}-{os}.tar.bz2".format(
                release = repository_ctx.attr.release,
                version = repository_ctx.attr.version,
                arch = repository_ctx.attr.arch,
                os = repository_ctx.attr.os_url,
            ),
        ],
        sha256 = sha256,
    )
    repository_ctx.file("WORKSPACE.bazel", "")
    repository_ctx.file("BUILD.bazel", _build_file_for_toolchain_template.format(
        main_workspace = repository_ctx.attr.main_workspace,
        toolchain_name = repository_ctx.attr.toolchain_name,
    ))

toolchain_repository = repository_rule(
    implementation = _toolchain_repository_impl,
    attrs = {
        "main_workspace": attr.string(
            doc = "Name of the Dhall rules workspace.",
        ),
        "toolchain_name": attr.string(
            doc = "Name of the toolchain declaration.",
        ),
        "arch": attr.string(doc = "CPU architecture.", mandatory = True),
        "os": attr.string(doc = "Operating system.", mandatory = True),
        "os_url": attr.string(doc = "Operating system URL string.", mandatory = True),
        "release": attr.string(default = DEFAULT.release),
        "version": attr.string(default = DEFAULT.version),
        "sha256": attr.string(default = ""),
    },
)

_build_file_for_toolchain_template = """\
load("@{main_workspace}//dhall-json:defs.bzl", "dhall_json_toolchain")

dhall_json_toolchain(
    name = "{toolchain_name}",
    dhall_to_json = "bin/dhall-to-json",
    dhall_to_yaml = "bin/dhall-to-yaml",
    visibility = ["//visibility:public"],
)
"""

_build_file_for_toolchain_proxy_template = """\
toolchain(
    name = "{toolchain_target}",
    exec_compatible_with = {exec_compatible_with},
    target_compatible_with = {target_compatible_with},
    toolchain = "{toolchain}",
    toolchain_type = "{toolchain_type}",
)
"""

def _toolchain_repository_proxy_impl(repository_ctx):
    repository_ctx.file("WORKSPACE.bazel", """workspace(name = "{}")""".format(
        repository_ctx.name,
    ))
    repository_ctx.file(
        "BUILD.bazel",
        _build_file_for_toolchain_proxy_template.format(
            name = repository_ctx.attr.toolchain_target,
            toolchain = repository_ctx.attr.toolchain,
            toolchain_target = repository_ctx.attr.toolchain_target,
            toolchain_type = repository_ctx.attr.toolchain_type,
            target_compatible_with = json.encode(repository_ctx.attr.target_compatible_with),
            exec_compatible_with = json.encode(repository_ctx.attr.exec_compatible_with),
        ),
    )

toolchain_repository_proxy = repository_rule(
    doc = "Generates a toolchain-bearing repository that declares the toolchain.",
    implementation = _toolchain_repository_proxy_impl,
    attrs = {
        "exec_compatible_with": attr.string_list(
            doc = "A list of constraints for the execution platform for this toolchain.",
        ),
        "target_compatible_with": attr.string_list(
            doc = "A list of constraints for the target platform for this toolchain.",
        ),
        "toolchain": attr.string(
            doc = "The name of the toolchain implementation target.",
            mandatory = True,
        ),
        "toolchain_target": attr.string(mandatory = True),
        "toolchain_type": attr.string(
            doc = "The toolchain type of the toolchain to declare",
            mandatory = True,
        ),
    },
)

def dhall_json_register_toolchains(workspace = "rules_dhall"):
    toolchain_name = "toolchain"
    toolchain_target = "toolchain"
    toolchains = []

    for arch in ARCHS:
        for os in OSS:
            name = "dhall_json_{}_{}".format(arch, os.name)
            real_repository_name = "{}_real".format(name)

            toolchain_repository(
                name = real_repository_name,
                main_workspace = workspace,
                toolchain_name = toolchain_name,
                arch = arch,
                os = os.name,
                os_url = os.url,
            )
            toolchain_repository_proxy(
                name = name,
                toolchain = "@{}//:{}".format(real_repository_name, toolchain_name),
                toolchain_target = toolchain_target,
                toolchain_type = "@{}//dhall-json:toolchain_type".format(workspace),
                exec_compatible_with = [
                    "@platforms//cpu:{}".format(arch),
                    "@platforms//os:{}".format(os.name),
                ],
                target_compatible_with = [],
            )

            toolchains.append("@{}//:{}".format(name, toolchain_target))

    native.register_toolchains(*toolchains)
