//! Sampled-value planning and evaluation for committed PCS trees.
//!
//! This module owns coefficient-plan caching, backend batch dispatch,
//! barycentric fallback, parallel scheduling, and coefficient lifetime release.

const std = @import("std");
const builtin = @import("builtin");
const circle = @import("../../core/circle.zig");
const m31 = @import("../../core/fields/m31.zig");
const qm31 = @import("../../core/fields/qm31.zig");
const pcs_core = @import("../../core/pcs/mod.zig");
const canonic = @import("../../core/poly/circle/canonic.zig");
const prover_circle = @import("../poly/circle/mod.zig");
const prover_circle_eval = @import("../poly/circle/evaluation.zig");
const work_pool_mod = @import("../work_pool.zig");
const commitment_tree = @import("commitment_tree.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;
const CirclePointQM31 = circle.CirclePointQM31;
const TreeVec = pcs_core.TreeVec;

pub fn evaluateAndRelease(
    comptime B: type,
    comptime H: type,
    allocator: std.mem.Allocator,
    trees: []commitment_tree.CommitmentTreeProverForBackend(B, H),
    sampled_points: TreeVec([][]CirclePointQM31),
    lifting_log_size: u32,
) !TreeVec([][]QM31) {
    if (trees.len != sampled_points.items.len) return error.ShapeMismatch;

    const out = try allocator.alloc([][]QM31, trees.len);
    errdefer allocator.free(out);

    var initialized_trees: usize = 0;
    errdefer {
        for (out[0..initialized_trees]) |tree_values| {
            for (tree_values) |column_values| allocator.free(column_values);
            allocator.free(tree_values);
        }
    }

    for (trees, sampled_points.items, 0..) |*tree, tree_points, tree_idx| {
        if (tree.columns.len != tree_points.len) return error.ShapeMismatch;
        if (tree.coefficients) |coeffs| {
            if (coeffs.len != tree.columns.len) return error.ShapeMismatch;
        }

        const tree_values = try allocator.alloc([]QM31, tree.columns.len);
        out[tree_idx] = tree_values;
        initialized_trees += 1;

        var initialized_columns: usize = 0;
        errdefer {
            for (tree_values[0..initialized_columns]) |column_values| allocator.free(column_values);
            allocator.free(tree_values);
        }

        for (tree.columns, tree_points, 0..) |column, points, column_idx| {
            if (column.log_size > lifting_log_size) return error.ShapeMismatch;
            try column.validate();
            tree_values[column_idx] = try allocator.alloc(QM31, points.len);
            initialized_columns += 1;
        }
    }

    if (comptime @hasDecl(B, "evaluateCoefficientPlans")) {
        if (try evaluateCoefficientTreesWithBackend(
            B,
            H,
            trees,
            sampled_points.items,
            out,
            allocator,
            lifting_log_size,
        )) {
            releaseTreeCoefficients(B, H, trees, allocator);
            return TreeVec([][]QM31).initOwned(out);
        }
    }

    if (comptime @hasDecl(B, "recordSampledValueFallback")) {
        B.recordSampledValueFallback();
    }

    var barycentric_cache = std.AutoHashMap(u32, prover_circle_eval.BarycentricContext).init(allocator);
    defer {
        var iterator = barycentric_cache.valueIterator();
        while (iterator.next()) |context| {
            var mutable_context = context.*;
            mutable_context.deinit(allocator);
        }
        barycentric_cache.deinit();
    }

    for (trees) |*tree| {
        if (tree.coefficients != null) continue;
        for (tree.columns) |column| {
            const entry = try barycentric_cache.getOrPut(column.log_size);
            if (!entry.found_existing) {
                entry.value_ptr.* = try prover_circle_eval.BarycentricContext.init(
                    allocator,
                    column.log_size,
                );
            }
        }
    }

    const use_parallel = !builtin.single_threaded and !builtin.is_test and trees.len > 1;
    if (use_parallel) {
        if (work_pool_mod.getGlobalPool()) |pool| {
            const worker_contexts = try allocator.alloc(SampledValueWorkerCtx(B, H), trees.len);
            defer allocator.free(worker_contexts);

            for (trees, sampled_points.items, out, worker_contexts) |
                *tree,
                tree_points,
                tree_values,
                *worker_context,
            | {
                worker_context.* = .{
                    .tree = tree,
                    .tree_points = tree_points,
                    .tree_values = tree_values,
                    .lifting_log_size = lifting_log_size,
                    .barycentric_cache = &barycentric_cache,
                    .parallel_coefficient_plans = false,
                    .failed = false,
                };
            }

            const primary_tree = largestTreeIndex(trees, sampled_points.items);
            worker_contexts[primary_tree].parallel_coefficient_plans = true;

            var wait_group: std.Thread.WaitGroup = .{};
            for (worker_contexts, 0..) |*worker_context, tree_idx| {
                if (tree_idx == primary_tree) continue;
                pool.spawnWg(
                    &wait_group,
                    SampledValueWorkerCtx(B, H).run,
                    .{worker_context},
                );
            }
            SampledValueWorkerCtx(B, H).run(&worker_contexts[primary_tree]);
            wait_group.wait();

            for (worker_contexts) |worker_context| {
                if (worker_context.failed) return error.ShapeMismatch;
            }
        } else {
            try evaluateTreesSequential(
                B,
                H,
                trees,
                sampled_points.items,
                out,
                allocator,
                &barycentric_cache,
                lifting_log_size,
            );
        }
    } else {
        try evaluateTreesSequential(
            B,
            H,
            trees,
            sampled_points.items,
            out,
            allocator,
            &barycentric_cache,
            lifting_log_size,
        );
    }

    releaseTreeCoefficients(B, H, trees, allocator);
    return TreeVec([][]QM31).initOwned(out);
}

fn largestTreeIndex(
    trees: anytype,
    sampled_points: [][][]CirclePointQM31,
) usize {
    var primary_tree: usize = 0;
    var primary_cost: usize = 0;
    for (trees, sampled_points, 0..) |tree, tree_points, tree_idx| {
        var cost: usize = 0;
        for (tree.columns, tree_points) |column, points| {
            const column_cost = std.math.mul(usize, column.values.len, points.len) catch
                std.math.maxInt(usize);
            cost = std.math.add(usize, cost, column_cost) catch std.math.maxInt(usize);
        }
        if (cost > primary_cost) {
            primary_cost = cost;
            primary_tree = tree_idx;
        }
    }
    return primary_tree;
}

const CoefficientEvalPlan = struct {
    coeff_log_size: u32,
    fold_count: u32,
    normalized_points: []CirclePointQM31,
    flat_factors: []QM31,
    column_indices: std.ArrayList(usize),
    next_same_hash: ?usize,

    fn deinit(self: *CoefficientEvalPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.normalized_points);
        allocator.free(self.flat_factors);
        self.column_indices.deinit(allocator);
        self.* = undefined;
    }
};

fn deinitCoefficientEvalPlans(
    allocator: std.mem.Allocator,
    plans: *std.ArrayList(CoefficientEvalPlan),
) void {
    for (plans.items) |*plan| plan.deinit(allocator);
    plans.deinit(allocator);
}

fn getOrCreateCoefficientEvalPlan(
    allocator: std.mem.Allocator,
    index: *std.AutoHashMap(u64, usize),
    plans: *std.ArrayList(CoefficientEvalPlan),
    coeff_log_size: u32,
    fold_count: u32,
    points: []const CirclePointQM31,
) !*CoefficientEvalPlan {
    const plan_hash = hashCoefficientEvalPlanKey(coeff_log_size, fold_count, points);
    var existing_plan_idx = index.get(plan_hash);
    while (existing_plan_idx) |plan_idx| {
        const plan = &plans.items[plan_idx];
        if (plan.coeff_log_size == coeff_log_size and
            plan.fold_count == fold_count and
            coefficientEvalPlanMatchesPoints(plan.*, points))
        {
            return plan;
        }
        existing_plan_idx = plan.next_same_hash;
    }

    const normalized = try buildCoefficientEvalPlanData(
        allocator,
        coeff_log_size,
        fold_count,
        points,
    );
    errdefer allocator.free(normalized.normalized_points);
    errdefer allocator.free(normalized.flat_factors);

    try plans.append(allocator, .{
        .coeff_log_size = coeff_log_size,
        .fold_count = fold_count,
        .normalized_points = normalized.normalized_points,
        .flat_factors = normalized.flat_factors,
        .column_indices = std.ArrayList(usize).empty,
        .next_same_hash = index.get(plan_hash),
    });
    errdefer {
        var plan = plans.items[plans.items.len - 1];
        plans.items.len -= 1;
        plan.deinit(allocator);
    }
    try index.put(plan_hash, plans.items.len - 1);
    return &plans.items[plans.items.len - 1];
}

const CoefficientEvalPlanData = struct {
    normalized_points: []CirclePointQM31,
    flat_factors: []QM31,
};

const coefficient_plan_key_point_bytes =
    2 * qm31.SECURE_EXTENSION_DEGREE * @sizeOf(M31);

fn hashCoefficientEvalPlanKey(
    coeff_log_size: u32,
    fold_count: u32,
    points: []const CirclePointQM31,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var header: [3 * @sizeOf(u32)]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], coeff_log_size, .little);
    std.mem.writeInt(u32, header[4..8], fold_count, .little);
    std.mem.writeInt(u32, header[8..12], @intCast(points.len), .little);
    hasher.update(header[0..]);

    var point_bytes: [coefficient_plan_key_point_bytes]u8 = undefined;
    for (points) |point| {
        packPointKeyBytes(
            point_bytes[0..],
            if (fold_count == 0) point else point.repeatedDouble(fold_count),
        );
        hasher.update(point_bytes[0..]);
    }
    return hasher.final();
}

fn buildCoefficientEvalPlanData(
    allocator: std.mem.Allocator,
    coeff_log_size: u32,
    fold_count: u32,
    points: []const CirclePointQM31,
) !CoefficientEvalPlanData {
    const normalized_points = try allocator.alloc(CirclePointQM31, points.len);
    errdefer allocator.free(normalized_points);

    const flat_factors = try allocator.alloc(QM31, points.len * coeff_log_size);
    errdefer allocator.free(flat_factors);

    var factor_buffer: [circle.M31_CIRCLE_LOG_ORDER]QM31 = undefined;
    var factor_at: usize = 0;
    for (points, 0..) |point, point_idx| {
        const folded_point = if (fold_count == 0) point else point.repeatedDouble(fold_count);
        normalized_points[point_idx] = folded_point;

        if (coeff_log_size == 0) continue;
        const factors = prover_circle.poly.fillEvalFactorsForPoint(
            folded_point,
            coeff_log_size,
            &factor_buffer,
        );
        @memcpy(flat_factors[factor_at .. factor_at + coeff_log_size], factors);
        factor_at += coeff_log_size;
    }

    return .{
        .normalized_points = normalized_points,
        .flat_factors = flat_factors,
    };
}

fn coefficientEvalPlanMatchesPoints(
    plan: CoefficientEvalPlan,
    points: []const CirclePointQM31,
) bool {
    if (plan.normalized_points.len != points.len) return false;
    for (points, plan.normalized_points) |point, normalized_point| {
        const folded_point = if (plan.fold_count == 0)
            point
        else
            point.repeatedDouble(plan.fold_count);
        if (!folded_point.eql(normalized_point)) return false;
    }
    return true;
}

fn packPointKeyBytes(dst: []u8, point: CirclePointQM31) void {
    std.debug.assert(dst.len == coefficient_plan_key_point_bytes);
    var at: usize = 0;
    inline for (.{ point.x, point.y }) |coordinate| {
        const coordinates = coordinate.toM31Array();
        inline for (coordinates) |m31_coordinate| {
            const encoded = m31_coordinate.toBytesLe();
            @memcpy(dst[at .. at + @sizeOf(M31)], encoded[0..]);
            at += @sizeOf(M31);
        }
    }
}

fn evaluateCoefficientPlans(
    allocator: std.mem.Allocator,
    coefficients: []const prover_circle.CircleCoefficients,
    tree_values: [][]QM31,
    plans: []const CoefficientEvalPlan,
    allow_parallel: bool,
) !void {
    var batch_coefficients: []prover_circle.CircleCoefficients =
        &[_]prover_circle.CircleCoefficients{};
    defer if (batch_coefficients.len != 0) allocator.free(batch_coefficients);
    var batch_out: [][]QM31 = &[_][]QM31{};
    defer if (batch_out.len != 0) allocator.free(batch_out);

    for (plans) |plan| {
        if (plan.column_indices.items.len == 0) continue;
        if (plan.column_indices.items.len == 1) {
            const column_idx = plan.column_indices.items[0];
            coefficients[column_idx].evalAtPointsWithFlatFactors(
                plan.flat_factors,
                tree_values[column_idx],
            );
            continue;
        }

        const batch_len = plan.column_indices.items.len;
        if (batch_coefficients.len < batch_len) {
            if (batch_coefficients.len != 0) allocator.free(batch_coefficients);
            if (batch_out.len != 0) allocator.free(batch_out);
            batch_coefficients = try allocator.alloc(prover_circle.CircleCoefficients, batch_len);
            batch_out = try allocator.alloc([]QM31, batch_len);
        }
        const coefficient_view = batch_coefficients[0..batch_len];
        const out_view = batch_out[0..batch_len];

        for (plan.column_indices.items, 0..) |column_idx, batch_idx| {
            coefficient_view[batch_idx] = coefficients[column_idx];
            out_view[batch_idx] = tree_values[column_idx];
        }

        if (!allow_parallel or !evaluateCoefficientBatchParallel(
            coefficient_view,
            plan.flat_factors,
            out_view,
        )) {
            prover_circle.poly.CircleCoefficients.evalManyAtPointsWithFlatFactors(
                coefficient_view,
                plan.flat_factors,
                out_view,
            );
        }
    }
}

const CoefficientEvalWork = struct {
    coefficients: []const prover_circle.CircleCoefficients,
    flat_factors: []const QM31,
    out: []const []QM31,

    fn run(self: *const CoefficientEvalWork) void {
        prover_circle.poly.CircleCoefficients.evalManyAtPointsWithFlatFactors(
            self.coefficients,
            self.flat_factors,
            self.out,
        );
    }
};

fn evaluateCoefficientBatchParallel(
    coefficients: []const prover_circle.CircleCoefficients,
    flat_factors: []const QM31,
    out: []const []QM31,
) bool {
    const min_columns_per_worker: usize = 8;
    const pool = work_pool_mod.getGlobalPool() orelse return false;
    const worker_count = @min(pool.workerCount(), coefficients.len / min_columns_per_worker);
    if (worker_count <= 1) return false;

    var work: [work_pool_mod.MAX_WORKERS]CoefficientEvalWork = undefined;
    const chunk_len = (coefficients.len + worker_count - 1) / worker_count;
    for (0..worker_count) |worker| {
        // Clamp the start as well: with ceiling-divided chunks a trailing
        // worker's nominal start can land past the end of the slice.
        const start = @min(coefficients.len, worker * chunk_len);
        const end = @min(coefficients.len, start + chunk_len);
        work[worker] = .{
            .coefficients = coefficients[start..end],
            .flat_factors = flat_factors,
            .out = out[start..end],
        };
    }

    var wait_group: std.Thread.WaitGroup = .{};
    for (work[1..worker_count]) |*item| {
        pool.spawnWg(&wait_group, CoefficientEvalWork.run, .{@as(*const CoefficientEvalWork, item)});
    }
    work[0].run();
    wait_group.wait();
    return true;
}

fn coefficientsAreZero(coefficients: prover_circle.CircleCoefficients) bool {
    for (coefficients.coeffs) |coefficient| {
        if (!coefficient.isZero()) return false;
    }
    return true;
}

fn SampledValueWorkerCtx(comptime B: type, comptime H: type) type {
    return struct {
        tree: *commitment_tree.CommitmentTreeProverForBackend(B, H),
        tree_points: [][]CirclePointQM31,
        tree_values: [][]QM31,
        lifting_log_size: u32,
        barycentric_cache: *const std.AutoHashMap(u32, prover_circle_eval.BarycentricContext),
        parallel_coefficient_plans: bool,
        failed: bool,

        const WorkerSelf = @This();

        fn run(self: *WorkerSelf) void {
            self.runInner() catch {
                self.failed = true;
            };
        }

        fn runInner(self: *WorkerSelf) !void {
            const scratch_allocator = std.heap.page_allocator;
            var coefficient_plans = std.ArrayList(CoefficientEvalPlan).empty;
            defer deinitCoefficientEvalPlans(scratch_allocator, &coefficient_plans);
            var coefficient_plan_index = std.AutoHashMap(u64, usize).init(scratch_allocator);
            defer coefficient_plan_index.deinit();

            const tree = self.tree;
            for (tree.columns, self.tree_points, 0..) |column, points, column_idx| {
                const values = self.tree_values[column_idx];
                const fold_count = self.lifting_log_size - column.log_size;
                if (tree.coefficients) |coefficients| {
                    const coefficient = coefficients[column_idx];
                    if (coefficientsAreZero(coefficient)) {
                        @memset(values, QM31.zero());
                        continue;
                    }
                    const plan = try getOrCreateCoefficientEvalPlan(
                        scratch_allocator,
                        &coefficient_plan_index,
                        &coefficient_plans,
                        coefficient.logSize(),
                        fold_count,
                        points,
                    );
                    try plan.column_indices.append(scratch_allocator, column_idx);
                } else {
                    const evaluation = try prover_circle.CircleEvaluation.init(
                        canonic.CanonicCoset.new(column.log_size).circleDomain(),
                        column.values,
                    );
                    const context = self.barycentric_cache.getPtr(column.log_size) orelse
                        return error.ShapeMismatch;
                    var workspace = prover_circle_eval.BarycentricWorkspace.init();
                    defer workspace.deinit(scratch_allocator);

                    for (points, 0..) |point, point_idx| {
                        values[point_idx] = try evaluation.barycentricEvalAtPointWithContext(
                            scratch_allocator,
                            context,
                            &workspace,
                            point.repeatedDouble(fold_count),
                        );
                    }
                }
            }

            if (tree.coefficients) |coefficients| {
                try evaluateCoefficientPlans(
                    scratch_allocator,
                    coefficients,
                    self.tree_values,
                    coefficient_plans.items,
                    self.parallel_coefficient_plans,
                );
            }
        }
    };
}

fn evaluateTreesSequential(
    comptime B: type,
    comptime H: type,
    trees: []commitment_tree.CommitmentTreeProverForBackend(B, H),
    tree_points_list: [][][]CirclePointQM31,
    out: [][][]QM31,
    allocator: std.mem.Allocator,
    barycentric_cache: *std.AutoHashMap(u32, prover_circle_eval.BarycentricContext),
    lifting_log_size: u32,
) !void {
    var workspace_cache = std.AutoHashMap(u32, prover_circle_eval.BarycentricWorkspace).init(allocator);
    defer {
        var iterator = workspace_cache.valueIterator();
        while (iterator.next()) |workspace| {
            var mutable_workspace = workspace.*;
            mutable_workspace.deinit(allocator);
        }
        workspace_cache.deinit();
    }

    for (trees, tree_points_list, out) |*tree, tree_points, tree_values| {
        var coefficient_plans = std.ArrayList(CoefficientEvalPlan).empty;
        defer deinitCoefficientEvalPlans(allocator, &coefficient_plans);
        var coefficient_plan_index = std.AutoHashMap(u64, usize).init(allocator);
        defer coefficient_plan_index.deinit();

        for (tree.columns, tree_points, 0..) |column, points, column_idx| {
            const values = tree_values[column_idx];
            const fold_count = lifting_log_size - column.log_size;
            if (tree.coefficients) |coefficients| {
                const coefficient = coefficients[column_idx];
                if (coefficientsAreZero(coefficient)) {
                    @memset(values, QM31.zero());
                    continue;
                }
                const plan = try getOrCreateCoefficientEvalPlan(
                    allocator,
                    &coefficient_plan_index,
                    &coefficient_plans,
                    coefficient.logSize(),
                    fold_count,
                    points,
                );
                try plan.column_indices.append(allocator, column_idx);
            } else {
                const evaluation = try prover_circle.CircleEvaluation.init(
                    canonic.CanonicCoset.new(column.log_size).circleDomain(),
                    column.values,
                );
                const context = barycentric_cache.getPtr(column.log_size) orelse
                    return error.ShapeMismatch;
                const workspace = try workspace_cache.getOrPut(column.log_size);
                if (!workspace.found_existing) {
                    workspace.value_ptr.* = prover_circle_eval.BarycentricWorkspace.init();
                }
                for (points, 0..) |point, point_idx| {
                    values[point_idx] = try evaluation.barycentricEvalAtPointWithContext(
                        allocator,
                        context,
                        workspace.value_ptr,
                        point.repeatedDouble(fold_count),
                    );
                }
            }
        }

        if (tree.coefficients) |coefficients| {
            try evaluateCoefficientPlans(
                allocator,
                coefficients,
                tree_values,
                coefficient_plans.items,
                false,
            );
        }
    }
}

fn evaluateCoefficientTreesWithBackend(
    comptime B: type,
    comptime H: type,
    trees: []commitment_tree.CommitmentTreeProverForBackend(B, H),
    tree_points_list: [][][]CirclePointQM31,
    out: [][][]QM31,
    allocator: std.mem.Allocator,
    lifting_log_size: u32,
) !bool {
    for (trees, 0..) |tree, tree_index| if (tree.coefficients == null) {
        std.log.debug(
            "backend sampled evaluation unavailable: tree {d} has no coefficients",
            .{tree_index},
        );
        return false;
    };

    for (trees, tree_points_list, out) |tree, tree_points, tree_values| {
        const coefficients = tree.coefficients.?;
        var plans = std.ArrayList(CoefficientEvalPlan).empty;
        defer deinitCoefficientEvalPlans(allocator, &plans);
        var plan_index = std.AutoHashMap(u64, usize).init(allocator);
        defer plan_index.deinit();

        for (tree.columns, tree_points, 0..) |column, points, column_idx| {
            const plan = try getOrCreateCoefficientEvalPlan(
                allocator,
                &plan_index,
                &plans,
                coefficients[column_idx].logSize(),
                lifting_log_size - column.log_size,
                points,
            );
            try plan.column_indices.append(allocator, column_idx);
        }
        try B.evaluateCoefficientPlans(allocator, coefficients, tree_values, plans.items);
    }
    return true;
}

fn releaseTreeCoefficients(
    comptime B: type,
    comptime H: type,
    trees: []commitment_tree.CommitmentTreeProverForBackend(B, H),
    allocator: std.mem.Allocator,
) void {
    for (trees) |*tree| {
        if (tree.coefficients) |coefficients| {
            for (coefficients) |*coefficient| coefficient.deinit(allocator);
            allocator.free(coefficients);
            tree.coefficients = null;
        }
    }
}

test "prover pcs: coefficient eval plan cache reuses duplicate point sets" {
    const allocator = std.testing.allocator;
    const points_a = try allocator.dupe(CirclePointQM31, &[_]CirclePointQM31{
        circle.SECURE_FIELD_CIRCLE_GEN.mul(17),
        circle.SECURE_FIELD_CIRCLE_GEN.mul(23),
    });
    defer allocator.free(points_a);
    const points_b = try allocator.dupe(CirclePointQM31, points_a);
    defer allocator.free(points_b);
    const points_c = try allocator.dupe(CirclePointQM31, &[_]CirclePointQM31{
        circle.SECURE_FIELD_CIRCLE_GEN.mul(29),
    });
    defer allocator.free(points_c);

    var plans = std.ArrayList(CoefficientEvalPlan).empty;
    defer deinitCoefficientEvalPlans(allocator, &plans);
    var index = std.AutoHashMap(u64, usize).init(allocator);
    defer index.deinit();

    const plan_a = try getOrCreateCoefficientEvalPlan(allocator, &index, &plans, 6, 1, points_a);
    try plan_a.column_indices.append(allocator, 0);

    _ = try getOrCreateCoefficientEvalPlan(allocator, &index, &plans, 6, 1, points_b);
    try std.testing.expectEqual(@as(usize, 1), plans.items.len);

    _ = try getOrCreateCoefficientEvalPlan(allocator, &index, &plans, 6, 1, points_c);
    try std.testing.expectEqual(@as(usize, 2), plans.items.len);
}
