//! Ownership-preserving preparation of PCS columns for commitment.

const std = @import("std");
const m31 = @import("../../../core/fields/m31.zig");
const canonic = @import("../../../core/poly/circle/canonic.zig");
const prover_circle = @import("../../poly/circle/mod.zig");
const stage_profile = @import("../../stage_profile.zig");
const twiddle_source_mod = @import("../../poly/twiddle_source.zig");
const commitment_tree = @import("../commitment_tree.zig");
const circle_transforms = @import("circle_transforms.zig");
const column_storage = @import("storage.zig");

const M31 = m31.M31;
const ColumnEvaluation = commitment_tree.ColumnEvaluation;
const CoefficientRetentionPolicy = column_storage.CoefficientRetentionPolicy;
const PreparedCommitmentColumns = column_storage.PreparedCommitmentColumns;
const TwiddleSource = twiddle_source_mod.TwiddleSource;

pub fn columnEvaluationsAreConstant(columns: []const ColumnEvaluation) bool {
    if (columns.len == 0) return false;
    for (columns) |column| {
        if (column.values.len == 0) return false;
        const first = column.values[0];
        for (column.values[1..]) |value| {
            if (!value.eql(first)) return false;
        }
    }
    return true;
}

pub fn prepareConstantColumnsForCommitOwned(
    allocator: std.mem.Allocator,
    owned_columns: []ColumnEvaluation,
    log_blowup_factor: u32,
    retention_policy: CoefficientRetentionPolicy,
) !PreparedCommitmentColumns {
    const retain_coefficients = column_storage.shouldRetainCoefficients(owned_columns, retention_policy);
    const coefficients = if (retain_coefficients)
        try allocator.alloc(prover_circle.CircleCoefficients, owned_columns.len)
    else
        null;
    var initialized_coefficients: usize = 0;
    errdefer if (coefficients) |coeffs| {
        for (coeffs[0..initialized_coefficients]) |*coefficient| coefficient.deinit(allocator);
        allocator.free(coeffs);
    };

    for (owned_columns, 0..) |*column, i| {
        try column.validate();
        const constant = column.values[0];
        if (coefficients) |coeffs| {
            const coefficient_values = try allocator.alloc(M31, column.values.len);
            @memset(coefficient_values, M31.zero());
            coefficient_values[0] = constant;
            coeffs[i] = prover_circle.CircleCoefficients.initOwned(coefficient_values) catch |err| {
                allocator.free(coefficient_values);
                return err;
            };
            initialized_coefficients += 1;
        }

        if (log_blowup_factor != 0) {
            const extended_log_size = std.math.add(u32, column.log_size, log_blowup_factor) catch
                return error.InvalidColumnLogSize;
            if (extended_log_size >= @bitSizeOf(usize)) return error.InvalidColumnLogSize;
            const extended_len = @as(usize, 1) << @intCast(extended_log_size);
            const extended_values = try allocator.alloc(M31, extended_len);
            @memset(extended_values, constant);
            allocator.free(column.values);
            column.* = .{ .log_size = extended_log_size, .values = extended_values };
        }
    }

    return .{ .columns = owned_columns, .coefficients = coefficients };
}

pub fn prepareColumnsForCommitBorrowedForBackend(
    comptime B: type,
    allocator: std.mem.Allocator,
    columns: []const ColumnEvaluation,
    log_blowup_factor: u32,
    retention_policy: CoefficientRetentionPolicy,
    twiddle_source: *TwiddleSource,
) !PreparedCommitmentColumns {
    const owned = try allocator.alloc(ColumnEvaluation, columns.len);
    errdefer allocator.free(owned);

    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |column| allocator.free(column.values);
    }

    for (columns, 0..) |column, i| {
        try column.validate();
        owned[i] = .{
            .log_size = column.log_size,
            .values = try allocator.dupe(M31, column.values),
        };
        initialized += 1;
    }

    return prepareColumnsForCommitOwnedForBackend(
        B,
        allocator,
        owned,
        log_blowup_factor,
        retention_policy,
        twiddle_source,
        null,
    );
}

pub fn prepareColumnsForCommitOwnedForBackend(
    comptime B: type,
    allocator: std.mem.Allocator,
    owned_columns: []ColumnEvaluation,
    log_blowup_factor: u32,
    retention_policy: CoefficientRetentionPolicy,
    twiddle_source: *TwiddleSource,
    recorder: ?*stage_profile.Recorder,
) !PreparedCommitmentColumns {
    const retain_coefficients = column_storage.shouldRetainCoefficients(owned_columns, retention_policy);
    if (log_blowup_factor == 0 and !retain_coefficients) {
        return .{
            .columns = owned_columns,
            .coefficients = null,
        };
    }

    if (log_blowup_factor != 0 and comptime @hasDecl(B, "interpolateAndEvaluateCircleBuffers")) {
        return prepareColumnsCombinedForBackend(
            B,
            allocator,
            owned_columns,
            log_blowup_factor,
            retain_coefficients,
            twiddle_source,
        );
    }

    if (log_blowup_factor == 0) {
        {
            var interpolate_stage = try stage_profile.StageScope.begin(
                recorder,
                "interpolate_columns",
                "Interpolate columns",
            );
            defer interpolate_stage.end();
            const result = try circle_transforms.interpolateCoefficientColumns(allocator, owned_columns, twiddle_source);
            return .{
                .columns = owned_columns,
                .coefficients = result.coefficients,
                .coefficient_backing_buffers = result.backing_buffers,
            };
        }
    }

    const coeffs = blk: {
        var interpolate_stage = try stage_profile.StageScope.begin(
            recorder,
            "interpolate_columns",
            "Interpolate columns",
        );
        defer interpolate_stage.end();
        break :blk try circle_transforms.interpolateOwnedColumnsForExtensionForBackend(B, allocator, owned_columns, twiddle_source);
    };
    errdefer column_storage.deinitOwnedCoefficientColumns(allocator, coeffs);
    allocator.free(owned_columns);

    const extended = blk: {
        var eval_stage = try stage_profile.StageScope.begin(
            recorder,
            "evaluate_extended_domain",
            "Evaluate extended domain",
        );
        defer eval_stage.end();
        break :blk try circle_transforms.extendCoefficientColumnsByGroupForBackend(
            B,
            allocator,
            coeffs,
            log_blowup_factor,
            twiddle_source,
        );
    };

    if (!retain_coefficients) {
        column_storage.deinitOwnedCoefficientColumns(allocator, coeffs);
        return .{
            .columns = extended,
            .coefficients = null,
        };
    }

    return .{
        .columns = extended,
        .coefficients = coeffs,
    };
}

fn prepareColumnsCombinedForBackend(
    comptime B: type,
    allocator: std.mem.Allocator,
    owned_columns: []ColumnEvaluation,
    log_blowup_factor: u32,
    retain_coefficients: bool,
    twiddle_source: *TwiddleSource,
) !PreparedCommitmentColumns {
    const extended = try allocator.alloc(ColumnEvaluation, owned_columns.len);
    for (extended) |*column| column.* = .{ .log_size = 0, .values = &.{} };
    errdefer allocator.free(extended);

    const coefficients = try allocator.alloc(prover_circle.CircleCoefficients, owned_columns.len);
    errdefer allocator.free(coefficients);
    var initialized_indices = std.ArrayList(usize).empty;
    defer initialized_indices.deinit(allocator);
    errdefer for (initialized_indices.items) |index| coefficients[index].deinit(allocator);

    var coefficient_buffers = std.ArrayList([]M31).empty;
    defer coefficient_buffers.deinit(allocator);
    errdefer for (coefficient_buffers.items) |buffer| allocator.free(buffer);
    var column_buffers = std.ArrayList([]M31).empty;
    defer column_buffers.deinit(allocator);
    errdefer for (column_buffers.items) |buffer| allocator.free(buffer);

    var groups = try circle_transforms.buildLogSizeGroupsFromColumns(allocator, owned_columns);
    defer circle_transforms.deinitLogSizeGroups(allocator, &groups);
    for (groups.items) |group| {
        const extended_log_size = std.math.add(u32, group.log_size, log_blowup_factor) catch
            return error.ShapeMismatch;
        const base_domain = canonic.CanonicCoset.new(group.log_size).circleDomain();
        const extended_domain = canonic.CanonicCoset.new(extended_log_size).circleDomain();
        const base_twiddles = try twiddle_source.get(allocator, group.log_size);
        const extended_twiddles = try twiddle_source.get(allocator, extended_log_size);

        const base_buffer = try allocator.alloc(M31, group.indices.items.len * base_domain.size());
        try coefficient_buffers.append(allocator, base_buffer);
        const extended_buffer = try allocator.alloc(M31, group.indices.items.len * extended_domain.size());
        try column_buffers.append(allocator, extended_buffer);

        const base_values = try allocator.alloc([]M31, group.indices.items.len);
        defer allocator.free(base_values);
        const source_values = try allocator.alloc([]const M31, group.indices.items.len);
        defer allocator.free(source_values);
        const extended_values = try allocator.alloc([]M31, group.indices.items.len);
        defer allocator.free(extended_values);
        for (group.indices.items, 0..) |column_index, group_index| {
            const base = base_buffer[group_index * base_domain.size() ..][0..base_domain.size()];
            source_values[group_index] = owned_columns[column_index].values;
            base_values[group_index] = base;
            const values = extended_buffer[group_index * extended_domain.size() ..][0..extended_domain.size()];
            extended_values[group_index] = values;
            extended[column_index] = .{ .log_size = extended_log_size, .values = values };
        }
        try B.interpolateAndEvaluateCircleBuffers(
            allocator,
            source_values,
            base_values,
            extended_values,
            base_domain,
            base_twiddles,
            extended_domain,
            extended_twiddles,
        );

        for (group.indices.items, base_values) |column_index, base| {
            coefficients[column_index] = try prover_circle.CircleCoefficients.initBorrowed(base);
            try initialized_indices.append(allocator, column_index);
        }
    }

    for (owned_columns) |column| allocator.free(column.values);
    allocator.free(owned_columns);

    const owned_column_buffers = try allocator.dupe([]M31, column_buffers.items);
    errdefer allocator.free(owned_column_buffers);

    if (!retain_coefficients) {
        column_storage.deinitOwnedCoefficientColumns(allocator, coefficients);
        for (coefficient_buffers.items) |buffer| allocator.free(buffer);
        coefficient_buffers.clearRetainingCapacity();
        column_buffers.clearRetainingCapacity();
        return .{
            .columns = extended,
            .coefficients = null,
            .column_backing_buffers = owned_column_buffers,
        };
    }
    const owned_coefficient_buffers = try allocator.dupe([]M31, coefficient_buffers.items);
    coefficient_buffers.clearRetainingCapacity();
    column_buffers.clearRetainingCapacity();
    return .{
        .columns = extended,
        .coefficients = coefficients,
        .column_backing_buffers = owned_column_buffers,
        .coefficient_backing_buffers = owned_coefficient_buffers,
    };
}
