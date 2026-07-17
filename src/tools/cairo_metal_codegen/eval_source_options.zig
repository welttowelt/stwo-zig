const std = @import("std");

pub const FusionMode = enum {
    capped,
    experimental_hybrid_source_diagnostic,
};

pub const Options = struct {
    fusion_mode: FusionMode = .capped,
    fusion_cap: usize,
    selected_only: bool = false,
    component_limit: ?usize = null,
};

pub fn parse(
    arguments: []const []const u8,
    default_fusion_cap: usize,
    maximum_fusion_cap: usize,
) !Options {
    var options = Options{ .fusion_cap = default_fusion_cap };
    var fusion_cap_explicit = false;
    var fusion_mode_explicit = false;
    var argument_index: usize = 0;

    // Preserve the historical positional cap while preferring --fusion-cap.
    if (argument_index < arguments.len and
        !std.mem.startsWith(u8, arguments[argument_index], "--"))
    {
        options.fusion_cap = try parseFusionCap(arguments[argument_index], maximum_fusion_cap);
        fusion_cap_explicit = true;
        argument_index += 1;
    }

    while (argument_index < arguments.len) : (argument_index += 1) {
        const argument = arguments[argument_index];
        if (std.mem.eql(u8, argument, "--fusion-cap")) {
            if (fusion_cap_explicit or argument_index + 1 >= arguments.len)
                return error.InvalidArguments;
            argument_index += 1;
            options.fusion_cap = try parseFusionCap(
                arguments[argument_index],
                maximum_fusion_cap,
            );
            fusion_cap_explicit = true;
        } else if (std.mem.eql(u8, argument, "--experimental-hybrid-source-diagnostic")) {
            if (fusion_mode_explicit) return error.InvalidArguments;
            options.fusion_mode = .experimental_hybrid_source_diagnostic;
            fusion_mode_explicit = true;
        } else if (std.mem.eql(u8, argument, "--selected-only")) {
            if (options.selected_only) return error.InvalidArguments;
            options.selected_only = true;
        } else if (std.mem.eql(u8, argument, "--component-limit")) {
            if (options.component_limit != null or argument_index + 1 >= arguments.len)
                return error.InvalidArguments;
            argument_index += 1;
            options.component_limit = try std.fmt.parseUnsigned(
                usize,
                arguments[argument_index],
                10,
            );
            if (options.component_limit.? == 0) return error.InvalidComponentLimit;
        } else {
            return error.InvalidArguments;
        }
    }
    if (options.fusion_mode == .experimental_hybrid_source_diagnostic and fusion_cap_explicit)
        return error.HybridFusionConflictsWithCap;
    return options;
}

fn parseFusionCap(encoded: []const u8, maximum: usize) !usize {
    const cap = try std.fmt.parseUnsigned(usize, encoded, 10);
    if (cap == 0 or cap > maximum) return error.InvalidFusionInstructionCap;
    return cap;
}

test "Metal eval source options preserve the default and positional cap" {
    const defaults = try parse(&.{}, 512, 4096);
    try std.testing.expectEqual(FusionMode.capped, defaults.fusion_mode);
    try std.testing.expectEqual(@as(usize, 512), defaults.fusion_cap);
    try std.testing.expect(!defaults.selected_only);
    try std.testing.expectEqual(@as(?usize, null), defaults.component_limit);

    const positional = try parse(&.{ "2048", "--selected-only" }, 512, 4096);
    try std.testing.expectEqual(FusionMode.capped, positional.fusion_mode);
    try std.testing.expectEqual(@as(usize, 2048), positional.fusion_cap);
    try std.testing.expect(positional.selected_only);
}

test "Metal eval source options expose named capped and hybrid modes" {
    const capped = try parse(&.{ "--fusion-cap", "1024", "--component-limit", "8" }, 512, 4096);
    try std.testing.expectEqual(FusionMode.capped, capped.fusion_mode);
    try std.testing.expectEqual(@as(usize, 1024), capped.fusion_cap);
    try std.testing.expectEqual(@as(?usize, 8), capped.component_limit);

    const hybrid = try parse(&.{"--experimental-hybrid-source-diagnostic"}, 512, 4096);
    try std.testing.expectEqual(FusionMode.experimental_hybrid_source_diagnostic, hybrid.fusion_mode);
    try std.testing.expectEqual(@as(usize, 512), hybrid.fusion_cap);
}

test "Metal eval source options reject hybrid cap ambiguity" {
    try std.testing.expectError(
        error.HybridFusionConflictsWithCap,
        parse(&.{ "--experimental-hybrid-source-diagnostic", "--fusion-cap", "2048" }, 512, 4096),
    );
    try std.testing.expectError(
        error.HybridFusionConflictsWithCap,
        parse(&.{ "2048", "--experimental-hybrid-source-diagnostic" }, 512, 4096),
    );
}
