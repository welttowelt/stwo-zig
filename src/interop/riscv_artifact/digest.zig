//! Canonical statement digest for external expected-statement binding.

const std = @import("std");
const schema = @import("schema.zig");

const DOMAIN = "stwo-zig/riscv/expected-statement/v3\x00";

/// Hashes every statement field in declaration order using fixed-width little
/// endian words. Sequence lengths and optional-value presence are explicit.
pub fn statement(source: schema.SourceWire, wire_statement: schema.StatementWire) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(DOMAIN);

    bytes(&hasher, source.elf_sha256);
    bytes(&hasher, source.input_sha256);
    word(&hasher, wire_statement.segment_ordinal);
    word(&hasher, wire_statement.segment_count);
    word(&hasher, wire_statement.initial_pc);
    word(&hasher, wire_statement.final_pc);
    word(&hasher, wire_statement.total_steps);
    length(&hasher, wire_statement.components.len);
    for (wire_statement.components) |component| {
        word(&hasher, component.index);
        word(&hasher, component.family);
        word(&hasher, component.family_shard_index);
        word(&hasher, component.family_shard_count);
        word(&hasher, component.row_offset);
        word(&hasher, component.log_size);
        word(&hasher, component.n_rows);
        word(&hasher, component.n_columns);
        word(&hasher, component.interaction_batch_count);
    }
    length(&hasher, wire_statement.infrastructure.len);
    for (wire_statement.infrastructure) |component| {
        word(&hasher, component.index);
        word(&hasher, component.kind);
        word(&hasher, component.log_size);
        word(&hasher, component.n_rows);
        word(&hasher, component.n_columns);
        word(&hasher, component.claim_count);
    }

    const public = wire_statement.public_data;
    word(&hasher, public.initial_pc);
    word(&hasher, public.final_pc);
    word(&hasher, public.clock);
    for (public.initial_regs) |value| word(&hasher, value);
    for (public.final_regs) |value| word(&hasher, value);
    for (public.reg_last_clock) |value| word(&hasher, value);
    optional(&hasher, public.program_root);
    optional(&hasher, public.initial_rw_root);
    optional(&hasher, public.final_rw_root);
    word(&hasher, public.input_start);
    word(&hasher, public.input_len);
    length(&hasher, public.input_words.len);
    for (public.input_words) |value| word(&hasher, value);
    word(&hasher, public.output_len);
    word(&hasher, public.output_len_addr);
    word(&hasher, public.output_data_addr);
    length(&hasher, public.output_words.len);
    for (public.output_words) |value| {
        word(&hasher, value.addr);
        word(&hasher, value.value);
        word(&hasher, value.clock);
    }
    return hasher.finalResult();
}

fn word(hasher: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, @intCast(value), .little);
    hasher.update(&encoded);
}

fn length(hasher: *std.crypto.hash.sha2.Sha256, value: usize) void {
    word(hasher, std.math.cast(u32, value) orelse unreachable);
}

fn bytes(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    length(hasher, value.len);
    hasher.update(value);
}

fn optional(hasher: *std.crypto.hash.sha2.Sha256, value: ?u32) void {
    word(hasher, @intFromBool(value != null));
    word(hasher, value orelse 0);
}
