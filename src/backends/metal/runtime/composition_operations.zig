const std = @import("std");
const runtime = @import("../runtime.zig");
const ffi = @import("bindings.zig");
const protocol_mode = @import("protocol_mode.zig");

const MetalError = runtime.MetalError;
const Runtime = runtime.Runtime;
const CommandEpoch = runtime.CommandEpoch;
const CommandEpochStats = runtime.CommandEpochStats;
const ArenaCopyRange = runtime.ArenaCopyRange;
const DecommitFriRoundParams = runtime.DecommitFriRoundParams;
const DecommitTraceGroupParams = runtime.DecommitTraceGroupParams;
const PipelineCacheStats = runtime.PipelineCacheStats;
const PreparedStateRange = runtime.PreparedStateRange;
const QuotientCoefficientTask = runtime.QuotientCoefficientTask;
const QuotientCoefficientTerm = runtime.QuotientCoefficientTerm;
const ArenaCopyPlan = runtime.ArenaCopyPlan;
const WitnessFeedPlan = runtime.WitnessFeedPlan;
const WitnessFeedBatchPlan = runtime.WitnessFeedBatchPlan;
const CircleLdePlan = runtime.CircleLdePlan;
const CircleIfftPlan = runtime.CircleIfftPlan;
const FixedTablePlan = runtime.FixedTablePlan;
const FixedTableBatchPlan = runtime.FixedTableBatchPlan;
const MerkleParentChainPlan = runtime.MerkleParentChainPlan;
const MerkleLeafPlan = runtime.MerkleLeafPlan;
const ResidentMerklePlan = runtime.ResidentMerklePlan;
const EcOpPlan = runtime.EcOpPlan;
const CompactLayout = runtime.CompactLayout;
const CompactPlan = runtime.CompactPlan;
const EvalLayout = runtime.EvalLayout;
const WitnessLayout = runtime.WitnessLayout;
const EvalLibrary = runtime.EvalLibrary;
const EvalPlan = runtime.EvalPlan;
const WitnessPlan = runtime.WitnessPlan;
const EvalBatchPlan = runtime.EvalBatchPlan;
const CompositionFinalizePlan = runtime.CompositionFinalizePlan;
const CompositionLdeOptions = runtime.CompositionLdeOptions;
const CompositionLdePlan = runtime.CompositionLdePlan;
const CompositionExtParamDescriptor = runtime.CompositionExtParamDescriptor;
const CompositionInputPlan = runtime.CompositionInputPlan;
const CompositionFrontPlan = runtime.CompositionFrontPlan;
const RelationPlan = runtime.RelationPlan;
const FriFoldPlan = runtime.FriFoldPlan;
const QuotientCombinePlan = runtime.QuotientCombinePlan;
const FriRoundPlan = runtime.FriRoundPlan;
const FriTreePlan = runtime.FriTreePlan;
const FriFinalPlan = runtime.FriFinalPlan;
const QuotientCommitResult = runtime.QuotientCommitResult;
const FriFoldCommitResult = runtime.FriFoldCommitResult;
const ResidentBuffer = runtime.ResidentBuffer;
const Tree = runtime.Tree;
const validDomainPrefixBytes = protocol_mode.validDomainPrefixBytes;
const resource_plans = @import("resource_plans.zig").ResourcePlans(MetalError);
const evalArguments = resource_plans.evalArguments;

pub fn prepareCompositionFinalize(
    self: *Runtime,
    accumulator_offsets: []const u32,
    accumulator_logs: []const u32,
    inverse_twiddle_offset_words: u32,
    output_offsets: [8]u32,
    scale_factor: u32,
) MetalError!CompositionFinalizePlan {
    if (accumulator_offsets.len == 0 or accumulator_offsets.len != accumulator_logs.len or scale_factor == 0)
        return MetalError.PolynomialEvaluationFailed;
    for (accumulator_logs, 0..) |log_size, index| {
        if (log_size < 3 or log_size >= 31 or (index != 0 and log_size <= accumulator_logs[index - 1]))
            return MetalError.PolynomialEvaluationFailed;
    }
    var message: [1024]u8 = [_]u8{0} ** 1024;
    const handle = ffi.stwo_zig_metal_composition_finalize_prepare(
        self.handle,
        accumulator_offsets.ptr,
        accumulator_logs.ptr,
        @intCast(accumulator_logs.len),
        inverse_twiddle_offset_words,
        &output_offsets,
        scale_factor,
        &message,
        message.len,
    ) orelse {
        std.log.err("Metal composition-finalize preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
        return MetalError.PolynomialEvaluationFailed;
    };
    return .{ .handle = handle };
}

pub fn prepareCompositionLde(
    self: *Runtime,
    source_offsets: []const u64,
    source_logs: []const u32,
    destination_offsets: []const u32,
    extended_log: u32,
    twiddle_offset_words: u32,
) MetalError!CompositionLdePlan {
    return prepareCompositionLdeConfigured(
        self,
        source_offsets,
        source_logs,
        destination_offsets,
        extended_log,
        twiddle_offset_words,
        try runtime.compositionLdeOptionsFromEnvironment(),
    );
}

pub fn prepareCompositionLdeConfigured(
    self: *Runtime,
    source_offsets: []const u64,
    source_logs: []const u32,
    destination_offsets: []const u32,
    extended_log: u32,
    twiddle_offset_words: u32,
    options: CompositionLdeOptions,
) MetalError!CompositionLdePlan {
    if (source_offsets.len == 0 or source_offsets.len != source_logs.len or source_offsets.len != destination_offsets.len or
        extended_log < 3 or extended_log >= 31)
        return MetalError.PolynomialEvaluationFailed;
    for (source_logs) |log_size| if (log_size < 3 or log_size > extended_log) return MetalError.PolynomialEvaluationFailed;
    var message: [1024]u8 = [_]u8{0} ** 1024;
    const handle = ffi.stwo_zig_metal_composition_lde_prepare(
        self.handle,
        source_offsets.ptr,
        source_logs.ptr,
        destination_offsets.ptr,
        @intCast(source_offsets.len),
        extended_log,
        twiddle_offset_words,
        options.radix4,
        &message,
        message.len,
    ) orelse {
        std.log.err("Metal composition LDE preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
        return MetalError.PolynomialEvaluationFailed;
    };
    return .{ .handle = handle };
}

pub fn compositionLdePrepared(self: *Runtime, arena: ResidentBuffer, plan: CompositionLdePlan) MetalError!f64 {
    var gpu_ms: f64 = 0;
    var message: [1024]u8 = [_]u8{0} ** 1024;
    if (!ffi.stwo_zig_metal_composition_lde_prepared(self.handle, arena.handle, plan.handle, &gpu_ms, &message, message.len)) {
        std.log.err("Metal composition LDE execution failed: {s}", .{std.mem.sliceTo(&message, 0)});
        return MetalError.PolynomialEvaluationFailed;
    }
    return gpu_ms;
}

pub fn prepareCompositionFront(
    self: *Runtime,
    inputs: CompositionInputPlan,
    lde_plans: []const CompositionLdePlan,
    eval_batches: []const EvalBatchPlan,
    accumulator_offset: u32,
    accumulator_words: u32,
) MetalError!CompositionFrontPlan {
    _ = self;
    if (lde_plans.len == 0 or lde_plans.len != eval_batches.len or accumulator_words == 0)
        return MetalError.PolynomialEvaluationFailed;
    const lde_handles: []const *anyopaque = @ptrCast(lde_plans);
    const eval_handles: []const *anyopaque = @ptrCast(eval_batches);
    var message: [1024]u8 = [_]u8{0} ** 1024;
    const handle = ffi.stwo_zig_metal_composition_front_prepare(
        inputs.handle,
        lde_handles.ptr,
        eval_handles.ptr,
        @intCast(lde_plans.len),
        accumulator_offset,
        accumulator_words,
        &message,
        message.len,
    ) orelse {
        std.log.err("Metal composition-front preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
        return MetalError.PolynomialEvaluationFailed;
    };
    return .{ .handle = handle };
}

pub fn prepareCompositionInputs(
    self: *Runtime,
    descriptors: []const CompositionExtParamDescriptor,
    random_offset: u32,
    powers_offset: u32,
    power_count: u32,
) MetalError!CompositionInputPlan {
    if (power_count == 0) return MetalError.PolynomialEvaluationFailed;
    var message: [1024]u8 = [_]u8{0} ** 1024;
    const words: ?[*]const u32 = if (descriptors.len == 0) null else @ptrCast(descriptors.ptr);
    const handle = ffi.stwo_zig_metal_composition_inputs_prepare(
        self.handle,
        words,
        @intCast(descriptors.len),
        random_offset,
        powers_offset,
        power_count,
        &message,
        message.len,
    ) orelse {
        std.log.err("Metal composition input preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
        return MetalError.PolynomialEvaluationFailed;
    };
    return .{ .handle = handle };
}

pub fn compositionFrontPrepared(self: *Runtime, arena: ResidentBuffer, plan: CompositionFrontPlan) MetalError!f64 {
    var gpu_ms: f64 = 0;
    var message: [1024]u8 = [_]u8{0} ** 1024;
    if (!ffi.stwo_zig_metal_composition_front_prepared(self.handle, arena.handle, plan.handle, &gpu_ms, &message, message.len)) {
        std.log.err("Metal composition-front execution failed: {s}", .{std.mem.sliceTo(&message, 0)});
        return MetalError.PolynomialEvaluationFailed;
    }
    return gpu_ms;
}

pub fn compositionFinalizePrepared(self: *Runtime, arena: ResidentBuffer, plan: CompositionFinalizePlan) MetalError!f64 {
    var gpu_ms: f64 = 0;
    var message: [1024]u8 = [_]u8{0} ** 1024;
    if (!ffi.stwo_zig_metal_composition_finalize_prepared(self.handle, arena.handle, plan.handle, &gpu_ms, &message, message.len)) {
        std.log.err("Metal composition-finalize execution failed: {s}", .{std.mem.sliceTo(&message, 0)});
        return MetalError.PolynomialEvaluationFailed;
    }
    return gpu_ms;
}

/// Executes the complete device-resident composition graph in one command
/// buffer. Diagnostic modes retain their explicit host-readback boundaries.
pub fn compositionPrepared(
    self: *Runtime,
    arena: ResidentBuffer,
    front: CompositionFrontPlan,
    finalize: CompositionFinalizePlan,
) MetalError!f64 {
    var gpu_ms: f64 = 0;
    var message: [1024]u8 = [_]u8{0} ** 1024;
    if (!ffi.stwo_zig_metal_composition_prepared(
        self.handle,
        arena.handle,
        front.handle,
        finalize.handle,
        &gpu_ms,
        &message,
        message.len,
    )) {
        std.log.err("Metal composition graph execution failed: {s}", .{std.mem.sliceTo(&message, 0)});
        return MetalError.PolynomialEvaluationFailed;
    }
    return gpu_ms;
}

pub fn prepareRelation(
    self: *Runtime,
    geometry: []const u32,
    source_offsets: []const u32,
    descriptors: []const u32,
    output_offsets: []const u32,
    total_blocks: u32,
    alpha_offset_words: u32,
    z_offset_words: u32,
    scratch_offset_words: u32,
) MetalError!RelationPlan {
    if (geometry.len == 0 or geometry.len % 10 != 0 or source_offsets.len == 0 or
        descriptors.len == 0 or descriptors.len % 16 != 0 or output_offsets.len == 0 or total_blocks == 0)
        return MetalError.PolynomialEvaluationFailed;
    var message: [1024]u8 = [_]u8{0} ** 1024;
    const handle = ffi.stwo_zig_metal_relation_prepare(
        self.handle,
        geometry.ptr,
        @intCast(geometry.len / 10),
        source_offsets.ptr,
        @intCast(source_offsets.len),
        descriptors.ptr,
        @intCast(descriptors.len),
        output_offsets.ptr,
        @intCast(output_offsets.len),
        total_blocks,
        alpha_offset_words,
        z_offset_words,
        scratch_offset_words,
        &message,
        message.len,
    ) orelse {
        std.log.err("Metal relation preparation failed: {s}", .{std.mem.sliceTo(&message, 0)});
        return MetalError.PolynomialEvaluationFailed;
    };
    return .{ .handle = handle };
}

pub fn relationPrepared(self: *Runtime, arena: ResidentBuffer, plan: RelationPlan) MetalError!f64 {
    var gpu_ms: f64 = 0;
    var message: [1024]u8 = [_]u8{0} ** 1024;
    if (!ffi.stwo_zig_metal_relation_prepared(
        self.handle,
        arena.handle,
        plan.handle,
        &gpu_ms,
        &message,
        message.len,
    )) {
        std.log.err("Metal relation execution failed: {s}", .{std.mem.sliceTo(&message, 0)});
        return MetalError.PolynomialEvaluationFailed;
    }
    return gpu_ms;
}
