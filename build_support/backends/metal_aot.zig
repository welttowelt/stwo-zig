const std = @import("std");

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shader_manifest_module: *std.Build.Module,
};

pub fn addProducts(context: Context) void {
    const b = context.b;
    const tool_module = b.createModule(.{
        .root_source_file = b.path("src/tools/metal_core_aot/main.zig"),
        .target = context.target,
        .optimize = context.optimize,
    });
    tool_module.addImport("shader_manifest", context.shader_manifest_module);
    // The catalog's platform-blind construction contract declares one
    // generated options root for the metal_tools scope; keep it observable on
    // every host by recording the acceptance partition itself as build options.
    const platform_options = b.addOptions();
    platform_options.addOption(
        bool,
        "hosted_acceptance_available",
        context.target.result.os.tag == .macos,
    );
    tool_module.addOptions("aot_platform", platform_options);
    const tool = b.addExecutable(.{
        .name = "metal-core-aot",
        .root_module = tool_module,
    });
    const install_tool = b.addInstallArtifact(tool, .{});
    const tool_step = b.step(
        "metal-core-aot",
        "Build the deterministic, fail-closed core Metal AOT tool",
    );
    tool_step.dependOn(&install_tool.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/metal_core_aot/main.zig"),
        .target = context.target,
        .optimize = context.optimize,
    });
    test_module.addImport("shader_manifest", context.shader_manifest_module);
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step(
        "test-metal-core-aot",
        "Run deterministic core Metal AOT tooling tests without compiling shaders",
    );
    test_step.dependOn(&run_tests.step);

    if (context.target.result.os.tag != .macos) {
        addUnavailableAcceptance(b);
        return;
    }
    addHostedAcceptance(context, tool);
}

/// Fail-closed stubs so the platform-blind product catalog's configure
/// closure holds on every host: the step names exist everywhere, and
/// invoking one off macOS fails with the real reason (mirrors
/// build_support/benchmarks/metal.zig's convention).
fn addUnavailableAcceptance(b: *std.Build) void {
    const reason = "Native core metallib probe and acceptance require a macOS host with Metal";
    const failure = b.addFail(reason);
    inline for (.{
        "metal-core-aot-probe",
        "test-metal-core-aot-probe",
        "metal-core-aot-acceptance",
    }) |name| {
        b.step(name, reason).dependOn(&failure.step);
    }
}

fn addHostedAcceptance(context: Context, tool: *std.Build.Step.Compile) void {
    const b = context.b;
    const host_transcript_module = b.createModule(.{
        .root_source_file = b.path("src/tools/metal_core_aot/host_transcript.zig"),
        .target = context.target,
        .optimize = context.optimize,
    });
    const probe_module = b.createModule(.{
        .root_source_file = b.path("src/tools/metal_core_aot/probe.zig"),
        .target = context.target,
        .optimize = context.optimize,
    });
    probe_module.addImport("shader_manifest", context.shader_manifest_module);
    probe_module.addImport("host_transcript", host_transcript_module);
    const probe = b.addExecutable(.{
        .name = "metal-core-aot-probe",
        .root_module = probe_module,
    });
    linkProbe(b, probe);
    const install_probe = b.addInstallArtifact(probe, .{});
    const probe_step = b.step(
        "metal-core-aot-probe",
        "Build the authenticated Native core metallib acceptance probe",
    );
    probe_step.dependOn(&install_probe.step);

    const probe_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/metal_core_aot/probe.zig"),
        .target = context.target,
        .optimize = context.optimize,
    });
    probe_test_module.addImport("shader_manifest", context.shader_manifest_module);
    probe_test_module.addImport("host_transcript", host_transcript_module);
    const probe_tests = b.addTest(.{ .root_module = probe_test_module });
    linkProbe(b, probe_tests);
    const run_probe_tests = b.addRunArtifact(probe_tests);
    const probe_test_step = b.step(
        "test-metal-core-aot-probe",
        "Run Native core metallib probe contract tests without compiling shaders",
    );
    probe_test_step.dependOn(&run_probe_tests.step);

    const build_bundle = b.addRunArtifact(tool);
    build_bundle.addArgs(&.{ "build", "--output-dir" });
    const bundle = build_bundle.addOutputDirectoryArg("native-metal-core-aot");

    const run_probe = b.addRunArtifact(probe);
    run_probe.addArg("--bundle-dir");
    run_probe.addDirectoryArg(bundle);
    run_probe.addArg("--trust-anchor");
    run_probe.addFileArg(bundle.path(b, "stwo_zig_core.manifest.sha256"));

    const acceptance_step = b.step(
        "metal-core-aot-acceptance",
        "Build, authenticate, and inspect the linked Native core metallib",
    );
    acceptance_step.dependOn(&run_probe.step);
}

fn linkProbe(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    artifact.addCSourceFile(.{
        .file = b.path("src/tools/metal_core_aot/probe.m"),
        .flags = &.{ "-fobjc-arc", "-fblocks" },
    });
    artifact.linkLibC();
    artifact.linkFramework("Foundation");
    artifact.linkFramework("Metal");
}
