//! Direct adapted-input materialization for resident Cairo witnesses.

const std = @import("std");
const arena_plan = @import("../../../../backends/metal/arena_plan.zig");
const cairo_adapter = @import("../../../../frontends/cairo/adapter/mod.zig");
const cairo_opcodes = @import("../../../../frontends/cairo/adapter/opcodes.zig");
const witness_bundle_mod = @import("../../../../frontends/cairo/witness/bundle.zig");
const schedule_bindings = @import("../../schedule_bindings.zig");
const Error = @import("../errors.zig").Error;

const collectComponent = schedule_bindings.collectComponent;

/// Materializes the direct adapted-input lanes without an intermediate packed
/// matrix. Padding repeats row zero exactly as stwo-cairo's `casm_slot_columns`.
pub fn populateCasmWitnessInputs(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    input: *const cairo_adapter.ProverInput,
) !usize {
    var populated: usize = 0;
    for (cairo_opcodes.direct_witness_lanes) |lane| {
        if (witness_bundle.find(lane.label) == null) continue;
        if (!try populateDirectWitnessInput(allocator, resident_arena, schedule, plan, witness_bundle, input, lane.label))
            return Error.MissingBinding;
        populated += 1;
    }
    return populated;
}

pub fn populateBuiltinSeedWitnessInputs(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    input: *const cairo_adapter.ProverInput,
) !usize {
    const lanes = [_][]const u8{ "bitwise_builtin", "range_check_builtin", "pedersen_builtin", "poseidon_builtin" };
    var populated: usize = 0;
    for (lanes) |lane| {
        if (witness_bundle.find(lane) == null) continue;
        if (!try populateDirectWitnessInput(allocator, resident_arena, schedule, plan, witness_bundle, input, lane))
            return Error.MissingBinding;
        populated += 1;
    }
    return populated;
}

/// Recreates one directly seeded recorded component in its aliased interaction
/// input slab. Returns false for gather/compact consumers, whose inputs must be
/// reconstructed from producer sub-words instead.
pub fn populateDirectWitnessInput(
    allocator: std.mem.Allocator,
    resident_arena: *arena_plan.ResidentArena,
    schedule: []const std.json.Value,
    plan: arena_plan.Plan,
    witness_bundle: witness_bundle_mod.Bundle,
    input: *const cairo_adapter.ProverInput,
    component: []const u8,
) !bool {
    const entry = witness_bundle.find(component) orelse return Error.MissingBinding;
    for (cairo_opcodes.direct_witness_lanes) |lane| {
        if (!std.mem.eql(u8, lane.label, component)) continue;
        const states = input.state_transitions.casm_states_by_opcode.getConst(lane.tag);
        if (states.len == 0) return Error.MissingBinding;
        const bindings = try collectComponent(allocator, schedule, plan, "WitnessInput", component);
        defer allocator.free(bindings);
        const expected_columns: usize = if (lane.includes_iota) 5 else 4;
        if (entry.program.n_inputs != expected_columns or bindings.len != expected_columns)
            return Error.InvalidCardinality;
        const row_count = bindings[0].size_bytes / 4;
        const expected_rows = @max(std.math.ceilPowerOfTwo(usize, states.len) catch return Error.InvalidBindingSize, 16);
        if (row_count != expected_rows) return Error.InvalidBindingSize;
        for (bindings, 0..) |binding, column| {
            const bytes = try resident_arena.bytes(binding);
            if (bytes.len != row_count * 4) return Error.InvalidBindingSize;
            const aligned: []align(4) u8 = @alignCast(bytes);
            const destination = std.mem.bytesAsSlice(u32, aligned);
            for (destination, 0..) |*value, row| {
                const state = states[if (row < states.len) row else 0];
                value.* = switch (column) {
                    0 => state.pc.v,
                    1 => state.ap.v,
                    2 => state.fp.v,
                    3 => @intFromBool(row < states.len),
                    4 => @intCast(row),
                    else => unreachable,
                };
            }
        }
        return true;
    }

    const segment = if (std.mem.eql(u8, component, "bitwise_builtin"))
        input.builtin_segments.bitwise_builtin
    else if (std.mem.eql(u8, component, "range_check_builtin"))
        input.builtin_segments.range_check_builtin
    else if (std.mem.eql(u8, component, "pedersen_builtin"))
        input.builtin_segments.pedersen_builtin
    else if (std.mem.eql(u8, component, "poseidon_builtin"))
        input.builtin_segments.poseidon_builtin
    else
        return false;
    const addresses = segment orelse return Error.MissingBinding;
    if (addresses.begin_addr > std.math.maxInt(u32)) return Error.InvalidCardinality;
    const bindings = try collectComponent(allocator, schedule, plan, "WitnessInput", component);
    defer allocator.free(bindings);
    if (entry.program.n_inputs != 3 or bindings.len != 3) return Error.InvalidCardinality;
    const row_count = bindings[0].size_bytes / 4;
    if (row_count < 16 or !std.math.isPowerOfTwo(row_count)) return Error.InvalidBindingSize;
    for (bindings, 0..) |binding, column| {
        const bytes = try resident_arena.bytes(binding);
        if (bytes.len != row_count * 4) return Error.InvalidBindingSize;
        const aligned: []align(4) u8 = @alignCast(bytes);
        const destination = std.mem.bytesAsSlice(u32, aligned);
        for (destination, 0..) |*value, row| value.* = switch (column) {
            0 => @intCast(addresses.begin_addr),
            1 => 1,
            2 => @intCast(row),
            else => unreachable,
        };
    }
    return true;
}
