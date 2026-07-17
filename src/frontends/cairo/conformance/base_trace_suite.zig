//! Complete Fib25k Cairo base-trace conformance against the Rust receipt.
//!
//! Component runners own value comparison. This module only composes their
//! results and proves that their disjoint ownership covers the receipt exactly.

const std = @import("std");
const adapter = @import("../adapter/mod.zig");
const feed_bundle = @import("../witness/feed_bundle.zig");
const fixed_table_bundle = @import("../witness/fixed_table_bundle.zig");
const witness_bundle = @import("../witness/bundle.zig");
const checkpoint = @import("checkpoint.zig");
const direct_trace = @import("direct_trace.zig");
const fixed_trace = @import("fixed_trace.zig");
const memory_trace = @import("memory_trace.zig");

pub const direct_component_count = 10;
pub const memory_component_count = 3;
pub const fixed_component_count = 17;
pub const component_count = direct_component_count + memory_component_count + fixed_component_count;

pub const Summary = struct {
    components: usize,
    columns: usize,
    final_accumulator: checkpoint.Digest,
};

pub const Outcome = union(enum) {
    success: Summary,
    direct_mismatch: direct_trace.Mismatch,
    memory_mismatch: memory_trace.Mismatch,
    fixed_mismatch: fixed_trace.Mismatch,
};

pub const Error = error{
    DuplicateComponent,
    MissingComponent,
    UnexpectedComponent,
    UnexpectedComponentGroupCount,
    UnexpectedReceiptComponentCount,
};

/// Runs every implemented Fib25k base-trace lane and accepts success only when
/// their results form an exact, non-overlapping cover of the Rust receipt.
pub fn compare(
    allocator: std.mem.Allocator,
    input: *const adapter.ProverInput,
    witnesses: *const witness_bundle.Bundle,
    feeds: *const feed_bundle.Bundle,
    fixed: *const fixed_table_bundle.Bundle,
    expected: []const checkpoint.Component,
    final_accumulator: checkpoint.Digest,
) !Outcome {
    var direct = try direct_trace.compare(allocator, input, witnesses, expected);
    defer direct.deinit();
    if (direct.mismatch) |mismatch| return .{ .direct_mismatch = mismatch };

    const memory = try memory_trace.compare(allocator, input, witnesses, feeds, expected);
    if (memory.mismatch) |mismatch| return .{ .memory_mismatch = mismatch };

    var fixed_report = try fixed_trace.compare(allocator, input, witnesses, feeds, fixed, expected);
    defer fixed_report.deinit();
    if (fixed_report.mismatch) |mismatch| return .{ .fixed_mismatch = mismatch };

    if (direct.matches.len != direct_component_count or
        memory.match_count != memory_component_count or
        fixed_report.matches.len != fixed_component_count)
        return Error.UnexpectedComponentGroupCount;

    var coverage = try Coverage.init(expected);
    for (direct.matches) |matched| try coverage.account(
        matched.ordinal,
        matched.label,
        matched.column_count,
    );
    for (memory.matches[0..memory.match_count]) |matched| try coverage.account(
        matched.ordinal,
        matched.label,
        matched.column_count,
    );
    for (fixed_report.matches) |matched| try coverage.account(
        matched.ordinal,
        matched.label,
        matched.column_count,
    );
    const summary = try coverage.finish();
    return .{ .success = .{
        .components = summary.components,
        .columns = summary.columns,
        .final_accumulator = final_accumulator,
    } };
}

const Coverage = struct {
    expected: []const checkpoint.Component,
    seen: [component_count]bool = [_]bool{false} ** component_count,
    matched_components: usize = 0,
    matched_columns: usize = 0,

    const Result = struct { components: usize, columns: usize };

    fn init(expected: []const checkpoint.Component) Error!Coverage {
        if (expected.len != component_count) return Error.UnexpectedReceiptComponentCount;
        return .{ .expected = expected };
    }

    fn account(self: *Coverage, ordinal: u32, label: []const u8, columns: u32) Error!void {
        const index = std.math.cast(usize, ordinal) orelse return Error.UnexpectedComponent;
        if (index >= self.expected.len) return Error.UnexpectedComponent;
        const expected = self.expected[index];
        if (expected.ordinal != ordinal or
            !std.mem.eql(u8, expected.label, label) or
            expected.columns.len != columns)
            return Error.UnexpectedComponent;
        if (self.seen[index]) return Error.DuplicateComponent;
        self.seen[index] = true;
        self.matched_components += 1;
        self.matched_columns += columns;
    }

    fn finish(self: Coverage) Error!Result {
        if (self.matched_components != self.expected.len) return Error.MissingComponent;
        for (self.seen) |seen| if (!seen) return Error.MissingComponent;
        return .{ .components = self.matched_components, .columns = self.matched_columns };
    }
};

fn testComponents() [component_count]checkpoint.Component {
    var components: [component_count]checkpoint.Component = undefined;
    for (&components, 0..) |*component, index| component.* = .{
        .ordinal = @intCast(index),
        .label = test_labels[index],
        .columns = test_columns[0 .. index % test_columns.len + 1],
        .accumulator = [_]u8{0} ** 32,
    };
    return components;
}

const test_columns = [_]checkpoint.Column{
    .{ .ordinal = 0, .row_count = 1, .sha256 = [_]u8{0} ** 32 },
    .{ .ordinal = 1, .row_count = 1, .sha256 = [_]u8{0} ** 32 },
    .{ .ordinal = 2, .row_count = 1, .sha256 = [_]u8{0} ** 32 },
};

const test_labels = blk: {
    var labels: [component_count][]const u8 = undefined;
    for (&labels, 0..) |*label, index| label.* = std.fmt.comptimePrint("component-{d}", .{index});
    break :blk labels;
};

test "Cairo base trace coverage accounts for every component and column once" {
    const components = testComponents();
    var coverage = try Coverage.init(&components);
    var expected_columns: usize = 0;
    for (components) |component| {
        try coverage.account(component.ordinal, component.label, @intCast(component.columns.len));
        expected_columns += component.columns.len;
    }
    const result = try coverage.finish();
    try std.testing.expectEqual(@as(usize, component_count), result.components);
    try std.testing.expectEqual(expected_columns, result.columns);
}

test "Cairo base trace coverage rejects missing components" {
    const components = testComponents();
    var coverage = try Coverage.init(&components);
    for (components[0 .. components.len - 1]) |component|
        try coverage.account(component.ordinal, component.label, @intCast(component.columns.len));
    try std.testing.expectError(Error.MissingComponent, coverage.finish());
}

test "Cairo base trace coverage rejects duplicate components" {
    const components = testComponents();
    var coverage = try Coverage.init(&components);
    const component = components[0];
    try coverage.account(component.ordinal, component.label, @intCast(component.columns.len));
    try std.testing.expectError(
        Error.DuplicateComponent,
        coverage.account(component.ordinal, component.label, @intCast(component.columns.len)),
    );
}

test "Cairo base trace coverage rejects unexpected components" {
    const components = testComponents();
    var coverage = try Coverage.init(&components);
    try std.testing.expectError(
        Error.UnexpectedComponent,
        coverage.account(0, "not-component-0", @intCast(components[0].columns.len)),
    );
    try std.testing.expectError(
        Error.UnexpectedComponent,
        coverage.account(component_count, "out-of-range", 1),
    );
}
