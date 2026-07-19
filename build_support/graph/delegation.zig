//! Focused sub-build command construction and product-scoped cache policy.

const std = @import("std");

pub const Options = struct {
    aggregate_metal: bool,
    riscv_release_phase: []const u8,
    riscv_evidence_dir: []const u8,
    implementation_commit: ?[]const u8,
    implementation_dirty: ?bool,
    implementation_tree: ?[]const u8,
    dirty_content_sha256: ?[]const u8,

    pub fn read(b: *std.Build) Options {
        return .{
            .aggregate_metal = b.option(bool, "aggregate-metal", "Explicitly link Metal into aggregate test roots") orelse false,
            .riscv_release_phase = b.option([]const u8, "riscv-release-phase", "CP-13 phase: candidate or promoted") orelse "candidate",
            .riscv_evidence_dir = b.option([]const u8, "riscv-evidence-dir", "Fresh CP-13 evidence directory") orelse "zig-out/release-evidence/riscv",
            .implementation_commit = b.option([]const u8, "implementation-commit", "Exact lowercase 40-hex source commit embedded in the production CLI"),
            .implementation_dirty = b.option(bool, "implementation-dirty", "Whether the source embedded in the production CLI has local modifications"),
            .implementation_tree = b.option([]const u8, "implementation-tree", "Exact lowercase 40-hex source tree for an identity override"),
            .dirty_content_sha256 = b.option([]const u8, "implementation-dirty-content-sha256", "Canonical dirty-content digest required for a diagnostic dirty override"),
        };
    }
};

pub fn addProxy(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: Options,
    name: []const u8,
    description: []const u8,
    scope: []const u8,
) void {
    const command = commandFor(b, target, optimize, options, scope, name);
    b.step(name, description).dependOn(&command.step);
}

pub fn addInstallProxy(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: Options,
) void {
    const command = commandFor(b, target, optimize, options, "aggregate", "stwo-zig");
    b.getInstallStep().dependOn(&command.step);
}

fn commandFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: Options,
    scope: []const u8,
    step_name: []const u8,
) *std.Build.Step.Run {
    const triple = target.result.zigTriple(b.allocator) catch @panic("cannot format build target");
    const command = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        step_name,
        "--build-file",
        b.pathFromRoot("build_support/internal_build.zig"),
        "--cache-dir",
        productCacheDir(b, scope),
        "-p",
        b.install_path,
        b.fmt("-Drepository-root={s}", .{b.pathFromRoot(".")}),
        b.fmt("-Dproduct-scope={s}", .{scope}),
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
    });
    if (std.mem.eql(u8, scope, "aggregate"))
        command.addArg(b.fmt("-Daggregate-metal={s}", .{if (options.aggregate_metal) "true" else "false"}));
    if (std.mem.eql(u8, scope, "verification")) {
        command.addArg(b.fmt("-Driscv-release-phase={s}", .{options.riscv_release_phase}));
        command.addArg(b.fmt("-Driscv-evidence-dir={s}", .{options.riscv_evidence_dir}));
    }
    if (b.user_input_options.get("target") != null or b.user_input_options.get("cpu") != null)
        command.addArg(b.fmt("-Dtarget={s}", .{triple}));
    if (options.implementation_commit) |value|
        command.addArg(b.fmt("-Dimplementation-commit={s}", .{value}));
    if (options.implementation_dirty) |value|
        command.addArg(b.fmt("-Dimplementation-dirty={s}", .{if (value) "true" else "false"}));
    if (options.implementation_tree) |value|
        command.addArg(b.fmt("-Dimplementation-tree={s}", .{value}));
    if (options.dirty_content_sha256) |value|
        command.addArg(b.fmt("-Dimplementation-dirty-content-sha256={s}", .{value}));
    return command;
}

fn productCacheDir(b: *std.Build, scope: []const u8) []const u8 {
    if (b.graph.env_map.get("STWO_CI_CACHE_DIR")) |configured| {
        return if (std.fs.path.isAbsolute(configured)) configured else b.pathFromRoot(configured);
    }
    return b.pathFromRoot(b.fmt(".zig-cache/products/{s}", .{scope}));
}
