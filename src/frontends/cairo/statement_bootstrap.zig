//! Canonical statement-side transcript inputs for a Cairo proof.
//!
//! This module deliberately stops before commitments, interaction claims,
//! OODS, FRI, and query data. The component-enable and flattened-log-size
//! claims may be supplied directly or derived from the complete canonical
//! composition schedule. `CairoProofPlan` alone does not yet model the complete
//! optional Cairo claim.

const std = @import("std");
const adapter = @import("adapter/mod.zig");
const claim_registry = @import("claim_registry.zig");
const memory_mod = @import("common/memory.zig");
const composition_bundle = @import("witness/composition_bundle.zig");
const M31 = @import("../../core/fields/m31.zig").M31;
const M31_MODULUS = @import("../../core/fields/m31.zig").Modulus;
const Blake2sMerkleHasher = @import("../../core/vcs_lifted/blake2_merkle.zig").Blake2sPlainMerkleHasher;

pub const ORDINALS = [_]u32{ 1, 2, 10, 11, 12, 13, 14, 15, 16 };
pub const compact_statement_magic = "STWZCS1\x00".*;
pub const compact_statement_version: u16 = 1;
pub const compact_statement_header_bytes: usize = 80;
pub const compact_statement_memory_entry_words: usize = 9;

pub const PcsConfig = struct {
    pow_bits: u32,
    log_blowup_factor: u32,
    n_queries: u32,
    log_last_layer_degree_bound: u32,
    fold_step: u32,
    lifting_log_size: ?u32 = null,
};

pub const StatementBootstrapInput = struct {
    channel_salt: u32,
    pcs: PcsConfig,
    component_enable_bits: []const bool,
    component_log_sizes: []const u32,
    prover_input: *const adapter.ProverInput,
};

pub const ScheduledStatementBootstrapInput = struct {
    channel_salt: u32,
    pcs: PcsConfig,
    composition: *const composition_bundle.Bundle,
    prover_input: *const adapter.ProverInput,
};

pub const Error = error{
    ClaimLengthOverflow,
    InvalidClaimWord,
    InvalidClaimGeometry,
    DuplicateClaimComponent,
    InvalidMemoryId,
    InvalidOutputSegment,
    InvalidProgramRange,
    InvalidPublicSegmentContext,
    InvalidSafeCall,
    MemoryAddressMissing,
    SegmentPointerOverflow,
    UnknownClaimComponent,
};

pub const OwnedFlatClaimGeometry = struct {
    allocator: std.mem.Allocator,
    component_enable_bits: []bool,
    component_log_sizes: []u32,

    pub fn deinit(self: *OwnedFlatClaimGeometry) void {
        self.allocator.free(self.component_enable_bits);
        self.allocator.free(self.component_log_sizes);
        self.* = undefined;
    }
};

/// One active field from the canonical Rust `CairoClaim`. Dynamic fields carry
/// their claim log. Fixed fields may omit it; when present it must equal the
/// version-pinned registry value. `instance` is nonzero only for the contiguous
/// `memory_id_to_big` prefix.
pub const CanonicalClaimComponent = struct {
    name: []const u8,
    instance: u32 = 0,
    log_size: ?u32 = null,
};

/// Reconstructs Rust `CairoClaim::flatten_claim` from canonical active fields.
/// This is the diagnostic import boundary for a Rust-derived claim and the
/// production boundary for the eventual Zig claim generator.
pub fn deriveFlatClaimGeometryFromCanonical(
    allocator: std.mem.Allocator,
    components: []const CanonicalClaimComponent,
) (Error || std.mem.Allocator.Error)!OwnedFlatClaimGeometry {
    const enable_bits = try allocator.alloc(bool, claim_registry.enable_slot_count);
    errdefer allocator.free(enable_bits);
    @memset(enable_bits, false);
    const log_sizes = try allocator.alloc(u32, components.len);
    errdefer allocator.free(log_sizes);
    const consumed = try allocator.alloc(bool, components.len);
    defer allocator.free(consumed);
    @memset(consumed, false);

    var log_cursor: usize = 0;
    var memory_prefix_ended = false;
    for (claim_registry.enable_slots) |slot| {
        const field = claim_registry.claim_fields[slot.claim_field_index];
        var found: ?usize = null;
        for (components, 0..) |component, component_index| {
            if (!std.mem.eql(u8, component.name, field.name) or
                component.instance != slot.field_slot_index)
                continue;
            if (found != null) return Error.DuplicateClaimComponent;
            found = component_index;
        }

        if (slot.log_size_shape == .special_dynamic_prefix) {
            if (found == null) {
                memory_prefix_ended = true;
            } else if (memory_prefix_ended) {
                return Error.InvalidClaimGeometry;
            }
        }
        const component_index = found orelse continue;
        if (consumed[component_index]) return Error.DuplicateClaimComponent;
        const component = components[component_index];
        const log_size = switch (slot.log_size_shape) {
            .dynamic, .special_dynamic_prefix => component.log_size orelse return Error.InvalidClaimGeometry,
            .fixed => fixed: {
                const expected = slot.fixed_log_size orelse
                    return Error.InvalidClaimGeometry;
                if (component.log_size) |actual| {
                    if (actual != expected) return Error.InvalidClaimGeometry;
                }
                break :fixed expected;
            },
        };
        try validateClaimWord(log_size);
        consumed[component_index] = true;
        enable_bits[slot.enable_slot] = true;
        log_sizes[log_cursor] = log_size;
        log_cursor += 1;
    }
    for (consumed) |was_consumed| if (!was_consumed) return Error.UnknownClaimComponent;
    if (log_cursor != log_sizes.len) return Error.InvalidClaimGeometry;

    return .{
        .allocator = allocator,
        .component_enable_bits = enable_bits,
        .component_log_sizes = log_sizes,
    };
}

/// Owns all statement transcript inputs emitted by `init`.
pub const OwnedStatementBootstrap = struct {
    allocator: std.mem.Allocator,
    ordinal_1: []u32,
    ordinal_2: []u32,
    ordinal_10: []u32,
    ordinal_11: []u32,
    ordinal_12: []u32,
    ordinal_13: []u32,
    ordinal_14: []u32,
    ordinal_15: []u32,
    ordinal_16: []u32,

    pub fn deinit(self: *OwnedStatementBootstrap) void {
        self.allocator.free(self.ordinal_1);
        self.allocator.free(self.ordinal_2);
        self.allocator.free(self.ordinal_10);
        self.allocator.free(self.ordinal_11);
        self.allocator.free(self.ordinal_12);
        self.allocator.free(self.ordinal_13);
        self.allocator.free(self.ordinal_14);
        self.allocator.free(self.ordinal_15);
        self.allocator.free(self.ordinal_16);
        self.* = undefined;
    }

    pub fn words(self: *const OwnedStatementBootstrap, ordinal: u32) ?[]const u32 {
        return switch (ordinal) {
            1 => self.ordinal_1,
            2 => self.ordinal_2,
            10 => self.ordinal_10,
            11 => self.ordinal_11,
            12 => self.ordinal_12,
            13 => self.ordinal_13,
            14 => self.ordinal_14,
            15 => self.ordinal_15,
            16 => self.ordinal_16,
            else => null,
        };
    }

    /// Populates the statement bindings of a Metal `TranscriptRecipe`.
    /// Kept structural so this frontend module does not depend on Metal; the
    /// recipient must provide `loadInputWords(ordinal, words)`.
    pub fn populateTranscriptRecipeInputs(
        self: *const OwnedStatementBootstrap,
        recipe: anytype,
    ) !void {
        inline for (ORDINALS) |ordinal| {
            try recipe.loadInputWords(ordinal, self.words(ordinal).?);
        }
    }
};

/// Preferred constructor when the validated canonical composition schedule is
/// available. No claim words are imported from a Rust proof.
pub fn initFromCompositionSchedule(
    allocator: std.mem.Allocator,
    input: ScheduledStatementBootstrapInput,
) (Error || std.mem.Allocator.Error)!OwnedStatementBootstrap {
    var flat = try deriveFlatClaimGeometry(allocator, input.composition);
    defer flat.deinit();
    return init(allocator, .{
        .channel_salt = input.channel_salt,
        .pcs = input.pcs,
        .component_enable_bits = flat.component_enable_bits,
        .component_log_sizes = flat.component_log_sizes,
        .prover_input = input.prover_input,
    });
}

/// Serializes the independently derived Cairo public statement and flattened
/// claim geometry consumed by the pinned STWZCVE/1 Rust verifier adapter.
pub fn encodeCompactStatementV1(
    allocator: std.mem.Allocator,
    composition: *const composition_bundle.Bundle,
    prover_input: *const adapter.ProverInput,
) (Error || std.mem.Allocator.Error)![]u8 {
    var flat = try deriveFlatClaimGeometry(allocator, composition);
    defer flat.deinit();
    return encodeCompactStatementFromFlatClaimV1(allocator, .{
        .component_enable_bits = flat.component_enable_bits,
        .component_log_sizes = flat.component_log_sizes,
    }, prover_input);
}

pub const FlatClaimGeometryView = struct {
    component_enable_bits: []const bool,
    component_log_sizes: []const u32,
};

/// Serializes a runtime-generated claim without importing a composition
/// schedule or a target proof. The caller must resolve witness-fed component
/// logs before constructing this view.
pub fn encodeCompactStatementFromFlatClaimV1(
    allocator: std.mem.Allocator,
    flat: FlatClaimGeometryView,
    prover_input: *const adapter.ProverInput,
) (Error || std.mem.Allocator.Error)![]u8 {
    try validateFlatClaimGeometry(flat);
    const public = try derivePublicStatement(allocator, prover_input);
    defer allocator.free(public.public_claim);
    const segments = try extractPublicSegments(prover_input);
    const output = segments[0] orelse return Error.InvalidPublicSegmentContext;
    if (output.stop.value < output.start.value) return Error.InvalidOutputSegment;
    const output_count: usize = output.stop.value - output.start.value;
    const program_count: usize = public.program_len;

    const segment_bytes = std.math.mul(usize, adapter.N_PUBLIC_SEGMENTS, 5 * 4) catch
        return Error.ClaimLengthOverflow;
    const memory_count = std.math.add(usize, program_count, output_count) catch
        return Error.ClaimLengthOverflow;
    const memory_bytes = std.math.mul(
        usize,
        memory_count,
        compact_statement_memory_entry_words * 4,
    ) catch return Error.ClaimLengthOverflow;
    const enable_bytes = std.math.mul(usize, flat.component_enable_bits.len, 4) catch
        return Error.ClaimLengthOverflow;
    const log_bytes = std.math.mul(usize, flat.component_log_sizes.len, 4) catch
        return Error.ClaimLengthOverflow;
    var total_bytes = std.math.add(usize, compact_statement_header_bytes, segment_bytes) catch
        return Error.ClaimLengthOverflow;
    total_bytes = std.math.add(usize, total_bytes, memory_bytes) catch
        return Error.ClaimLengthOverflow;
    total_bytes = std.math.add(usize, total_bytes, enable_bytes) catch
        return Error.ClaimLengthOverflow;
    total_bytes = std.math.add(usize, total_bytes, log_bytes) catch
        return Error.ClaimLengthOverflow;

    const bytes = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..compact_statement_magic.len], &compact_statement_magic);
    std.mem.writeInt(u16, bytes[8..10], compact_statement_version, .little);
    std.mem.writeInt(u16, bytes[10..12], compact_statement_header_bytes, .little);
    const initial = prover_input.state_transitions.initial_state;
    const final = prover_input.state_transitions.final_state;
    std.mem.writeInt(u32, bytes[16..20], initial.pc.toU32(), .little);
    std.mem.writeInt(u32, bytes[20..24], initial.ap.toU32(), .little);
    std.mem.writeInt(u32, bytes[24..28], initial.fp.toU32(), .little);
    std.mem.writeInt(u32, bytes[28..32], final.pc.toU32(), .little);
    std.mem.writeInt(u32, bytes[32..36], final.ap.toU32(), .little);
    std.mem.writeInt(u32, bytes[36..40], final.fp.toU32(), .little);
    const initial_ap = initial.ap.toU32();
    if (initial_ap < 2) return Error.InvalidProgramRange;
    const safe0 = try memoryEntryAt(prover_input.memory, initial_ap - 2);
    const safe1 = try memoryEntryAt(prover_input.memory, initial_ap - 1);
    if (!memoryValueEqualsU32(safe0.value, initial_ap) or !memoryValueIsZero(safe1.value))
        return Error.InvalidSafeCall;
    std.mem.writeInt(u32, bytes[40..44], safe0.id, .little);
    std.mem.writeInt(u32, bytes[44..48], safe1.id, .little);
    std.mem.writeInt(u32, bytes[48..52], @intCast(program_count), .little);
    std.mem.writeInt(u32, bytes[52..56], @intCast(output_count), .little);
    std.mem.writeInt(u32, bytes[56..60], @intCast(flat.component_enable_bits.len), .little);
    std.mem.writeInt(u32, bytes[60..64], @intCast(flat.component_log_sizes.len), .little);
    std.mem.writeInt(u32, bytes[64..68], adapter.N_PUBLIC_SEGMENTS, .little);
    std.mem.writeInt(u32, bytes[68..72], compact_statement_memory_entry_words, .little);

    var cursor: usize = compact_statement_header_bytes;
    for (segments) |segment| {
        if (segment) |range| {
            writeCompactStatementWord(bytes, &cursor, 1);
            writeCompactStatementWord(bytes, &cursor, range.start.id);
            writeCompactStatementWord(bytes, &cursor, range.start.value);
            writeCompactStatementWord(bytes, &cursor, range.stop.id);
            writeCompactStatementWord(bytes, &cursor, range.stop.value);
        } else {
            cursor += 5 * 4;
        }
    }
    const initial_pc = initial.pc.toU32();
    for (0..program_count) |offset| {
        const address = std.math.add(u32, initial_pc, @as(u32, @intCast(offset))) catch
            return Error.SegmentPointerOverflow;
        writeCompactMemoryEntry(bytes, &cursor, try memoryEntryAt(prover_input.memory, address));
    }
    for (0..output_count) |offset| {
        const address = std.math.add(u32, output.start.value, @as(u32, @intCast(offset))) catch
            return Error.SegmentPointerOverflow;
        writeCompactMemoryEntry(bytes, &cursor, try memoryEntryAt(prover_input.memory, address));
    }
    for (flat.component_enable_bits) |enabled| {
        writeCompactStatementWord(bytes, &cursor, @intFromBool(enabled));
    }
    for (flat.component_log_sizes) |log_size| {
        writeCompactStatementWord(bytes, &cursor, log_size);
    }
    std.debug.assert(cursor == bytes.len);
    return bytes;
}

fn writeCompactMemoryEntry(bytes: []u8, cursor: *usize, entry: MemoryEntry) void {
    writeCompactStatementWord(bytes, cursor, entry.id);
    for (memoryValueWords(entry.value)) |word| writeCompactStatementWord(bytes, cursor, word);
}

fn writeCompactStatementWord(bytes: []u8, cursor: *usize, word: u32) void {
    std.mem.writeInt(u32, bytes[cursor.*..][0..4], word, .little);
    cursor.* += 4;
}

/// Reconstructs Rust `CairoClaim::flatten_claim` order from the canonical
/// composition components. Every component contributes one flattened log;
/// `memory_id_to_big` is the only field with multiple claim instances.
pub fn deriveFlatClaimGeometry(
    allocator: std.mem.Allocator,
    bundle: *const composition_bundle.Bundle,
) (Error || std.mem.Allocator.Error)!OwnedFlatClaimGeometry {
    const components = try allocator.alloc(CanonicalClaimComponent, bundle.components.len);
    defer allocator.free(components);
    for (bundle.components, components) |component, *canonical| {
        canonical.* = .{
            .name = component.label,
            .instance = component.instance,
            .log_size = component.trace_log_size,
        };
    }
    return deriveFlatClaimGeometryFromCanonical(allocator, components);
}

const PublicStatement = struct {
    program_len: u32,
    public_claim: []u32,
    output_root: [8]u32,
    program_root: [8]u32,
};

const MemoryEntry = struct {
    id: u32,
    value: memory_mod.MemoryValue,
};

const SmallPointer = struct {
    id: u32,
    value: u32,
};

const SegmentRange = struct {
    start: SmallPointer,
    stop: SmallPointer,
};

/// Derives ordinals 1, 2, and 10 through 16 in Rust verifier order.
pub fn init(
    allocator: std.mem.Allocator,
    input: StatementBootstrapInput,
) (Error || std.mem.Allocator.Error)!OwnedStatementBootstrap {
    try validateConfig(input.pcs);
    if (input.component_enable_bits.len > std.math.maxInt(u32)) return Error.ClaimLengthOverflow;
    for (input.component_log_sizes) |word| try validateClaimWord(word);

    const public = try derivePublicStatement(allocator, input.prover_input);
    defer allocator.free(public.public_claim);

    const ordinal_1 = try allocator.dupe(u32, &[_]u32{ input.channel_salt, 0, 0, 0 });
    errdefer allocator.free(ordinal_1);
    const ordinal_2 = try allocator.dupe(u32, &[_]u32{
        input.pcs.pow_bits,
        input.pcs.log_blowup_factor,
        input.pcs.n_queries,
        input.pcs.log_last_layer_degree_bound,
        input.pcs.fold_step,
        input.pcs.lifting_log_size orelse 0,
        0,
        0,
    });
    errdefer allocator.free(ordinal_2);
    const ordinal_10 = try allocator.dupe(u32, &[_]u32{
        @intCast(input.component_enable_bits.len), 0, 0, 0,
    });
    errdefer allocator.free(ordinal_10);
    const ordinal_11 = try allocPadded(allocator, input.component_enable_bits.len);
    errdefer allocator.free(ordinal_11);
    for (input.component_enable_bits, 0..) |enabled, index| ordinal_11[index] = @intFromBool(enabled);

    const ordinal_12 = try allocPadded(allocator, input.component_log_sizes.len);
    errdefer allocator.free(ordinal_12);
    @memcpy(ordinal_12[0..input.component_log_sizes.len], input.component_log_sizes);

    const ordinal_13 = try allocator.dupe(u32, &[_]u32{ public.program_len, 0, 0, 0 });
    errdefer allocator.free(ordinal_13);
    const ordinal_14 = try allocator.dupe(u32, public.public_claim);
    errdefer allocator.free(ordinal_14);
    const ordinal_15 = try allocator.dupe(u32, &public.output_root);
    errdefer allocator.free(ordinal_15);
    const ordinal_16 = try allocator.dupe(u32, &public.program_root);
    errdefer allocator.free(ordinal_16);

    return .{
        .allocator = allocator,
        .ordinal_1 = ordinal_1,
        .ordinal_2 = ordinal_2,
        .ordinal_10 = ordinal_10,
        .ordinal_11 = ordinal_11,
        .ordinal_12 = ordinal_12,
        .ordinal_13 = ordinal_13,
        .ordinal_14 = ordinal_14,
        .ordinal_15 = ordinal_15,
        .ordinal_16 = ordinal_16,
    };
}

fn validateConfig(config: PcsConfig) Error!void {
    inline for (.{
        config.pow_bits,
        config.log_blowup_factor,
        config.n_queries,
        config.log_last_layer_degree_bound,
        config.fold_step,
        config.lifting_log_size orelse 0,
    }) |word| try validateClaimWord(word);
}

fn validateClaimWord(word: u32) Error!void {
    if (word >= M31_MODULUS) return Error.InvalidClaimWord;
}

fn validateFlatClaimGeometry(flat: FlatClaimGeometryView) Error!void {
    if (flat.component_enable_bits.len != claim_registry.enable_slot_count)
        return Error.InvalidClaimGeometry;
    var log_cursor: usize = 0;
    var memory_prefix_ended = false;
    for (claim_registry.enable_slots) |slot| {
        const enabled = flat.component_enable_bits[slot.enable_slot];
        if (slot.log_size_shape == .special_dynamic_prefix) {
            if (enabled and memory_prefix_ended) return Error.InvalidClaimGeometry;
            if (!enabled) memory_prefix_ended = true;
        }
        if (!enabled) continue;
        if (log_cursor >= flat.component_log_sizes.len) return Error.InvalidClaimGeometry;
        const log_size = flat.component_log_sizes[log_cursor];
        try validateClaimWord(log_size);
        if (slot.fixed_log_size) |fixed| {
            if (log_size != fixed) return Error.InvalidClaimGeometry;
        }
        log_cursor += 1;
    }
    if (log_cursor != flat.component_log_sizes.len) return Error.InvalidClaimGeometry;
}

fn paddedLength(len: usize) Error!usize {
    const with_padding = std.math.add(usize, len, 3) catch return Error.ClaimLengthOverflow;
    return with_padding & ~@as(usize, 3);
}

fn allocPadded(allocator: std.mem.Allocator, len: usize) (Error || std.mem.Allocator.Error)![]u32 {
    const words = try allocator.alloc(u32, try paddedLength(len));
    @memset(words, 0);
    return words;
}

fn derivePublicStatement(
    allocator: std.mem.Allocator,
    input: *const adapter.ProverInput,
) (Error || std.mem.Allocator.Error)!PublicStatement {
    const initial = input.state_transitions.initial_state;
    const final = input.state_transitions.final_state;
    const initial_pc = initial.pc.toU32();
    const initial_ap = initial.ap.toU32();
    if (initial_ap < 2) return Error.InvalidProgramRange;
    const program_stop = initial_ap - 2;
    if (program_stop < initial_pc) return Error.InvalidProgramRange;
    const program_len_u32 = program_stop - initial_pc;
    const program_len: usize = program_len_u32;

    const segments = try extractPublicSegments(input);
    const output = segments[0] orelse return Error.InvalidPublicSegmentContext;
    if (output.stop.value < output.start.value) return Error.InvalidOutputSegment;
    const output_len_u32 = output.stop.value - output.start.value;
    const output_len: usize = output_len_u32;

    const fixed_len: usize = 6 + adapter.N_PUBLIC_SEGMENTS * 4 + 2;
    const with_program = std.math.add(usize, fixed_len, program_len) catch return Error.ClaimLengthOverflow;
    const unpadded_len = std.math.add(usize, with_program, output_len) catch return Error.ClaimLengthOverflow;
    var public_claim = try allocPadded(allocator, unpadded_len);
    errdefer allocator.free(public_claim);

    var cursor: usize = 0;
    for ([_]u32{
        initial.pc.toU32(), initial.ap.toU32(), initial.fp.toU32(),
        final.pc.toU32(),   final.ap.toU32(),   final.fp.toU32(),
    }) |word| {
        public_claim[cursor] = word;
        cursor += 1;
    }
    for (segments) |segment| {
        if (segment) |range| {
            for ([_]u32{ range.start.id, range.start.value, range.stop.id, range.stop.value }) |word| {
                public_claim[cursor] = word;
                cursor += 1;
            }
        } else {
            cursor += 4;
        }
    }

    const safe0 = try memoryEntryAt(input.memory, initial_ap - 2);
    const safe1 = try memoryEntryAt(input.memory, initial_ap - 1);
    if (!memoryValueEqualsU32(safe0.value, initial_ap) or !memoryValueIsZero(safe1.value))
        return Error.InvalidSafeCall;
    public_claim[cursor] = safe0.id;
    public_claim[cursor + 1] = safe1.id;
    cursor += 2;

    var output_hasher = Blake2sMerkleHasher.defaultWithInitialState();
    for (0..output_len) |offset| {
        const address = std.math.add(u32, output.start.value, @as(u32, @intCast(offset))) catch
            return Error.SegmentPointerOverflow;
        const entry = try memoryEntryAt(input.memory, address);
        public_claim[cursor] = entry.id;
        cursor += 1;
        hashMemoryValue(&output_hasher, entry.value);
    }

    var program_hasher = Blake2sMerkleHasher.defaultWithInitialState();
    for (0..program_len) |offset| {
        const address = std.math.add(u32, initial_pc, @as(u32, @intCast(offset))) catch
            return Error.SegmentPointerOverflow;
        const entry = try memoryEntryAt(input.memory, address);
        public_claim[cursor] = entry.id;
        cursor += 1;
        hashMemoryValue(&program_hasher, entry.value);
    }
    std.debug.assert(cursor == unpadded_len);

    return .{
        .program_len = program_len_u32,
        .public_claim = public_claim,
        .output_root = hashWords(output_hasher.finalize()),
        .program_root = hashWords(program_hasher.finalize()),
    };
}

fn extractPublicSegments(input: *const adapter.ProverInput) Error![adapter.N_PUBLIC_SEGMENTS]?SegmentRange {
    var present_count: u32 = 0;
    for (input.public_segment_context) |present| present_count += @intFromBool(present);
    if (present_count == 0 or !input.public_segment_context[0])
        return Error.InvalidPublicSegmentContext;

    const initial_ap = input.state_transitions.initial_state.ap.toU32();
    const final_ap = input.state_transitions.final_state.ap.toU32();
    _ = std.math.add(u32, initial_ap, present_count) catch return Error.SegmentPointerOverflow;
    if (final_ap < present_count) return Error.SegmentPointerOverflow;
    const stop_base = final_ap - present_count;

    var result: [adapter.N_PUBLIC_SEGMENTS]?SegmentRange = .{null} ** adapter.N_PUBLIC_SEGMENTS;
    var packed_index: u32 = 0;
    for (input.public_segment_context, 0..) |present, segment_index| {
        if (!present) continue;
        const start_address = std.math.add(u32, initial_ap, packed_index) catch
            return Error.SegmentPointerOverflow;
        const stop_address = std.math.add(u32, stop_base, packed_index) catch
            return Error.SegmentPointerOverflow;
        result[segment_index] = .{
            .start = try memorySmallPointerAt(input.memory, start_address),
            .stop = try memorySmallPointerAt(input.memory, stop_address),
        };
        packed_index += 1;
    }
    return result;
}

fn memoryEntryAt(memory: memory_mod.Memory, address: u32) Error!MemoryEntry {
    if (address >= memory.address_to_id.len) return Error.MemoryAddressMissing;
    const encoded = memory.address_to_id[address];
    if (encoded.isEmpty()) return Error.MemoryAddressMissing;
    if (encoded.isSmall()) {
        if (encoded.index() >= memory.small_values.len) return Error.InvalidMemoryId;
        return .{ .id = encoded.raw, .value = .{ .small = memory.small_values[encoded.index()] } };
    }
    if (encoded.index() >= memory.f252_values.len) return Error.InvalidMemoryId;
    return .{ .id = encoded.raw, .value = .{ .f252 = memory.f252_values[encoded.index()] } };
}

fn memorySmallPointerAt(memory: memory_mod.Memory, address: u32) Error!SmallPointer {
    const entry = try memoryEntryAt(memory, address);
    const value = switch (entry.value) {
        .small => |small| std.math.cast(u32, small) orelse return Error.SegmentPointerOverflow,
        .f252 => |words| blk: {
            if (words[1] != 0 or words[2] != 0 or words[3] != 0 or
                words[4] != 0 or words[5] != 0 or words[6] != 0 or words[7] != 0)
                return Error.SegmentPointerOverflow;
            break :blk words[0];
        },
    };
    try validateClaimWord(value);
    return .{ .id = entry.id, .value = value };
}

fn memoryValueWords(value: memory_mod.MemoryValue) [8]u32 {
    return switch (value) {
        .small => |small| .{
            @truncate(small),
            @truncate(small >> 32),
            @truncate(small >> 64),
            @truncate(small >> 96),
            0,
            0,
            0,
            0,
        },
        .f252 => |words| words,
    };
}

fn memoryValueEqualsU32(value: memory_mod.MemoryValue, expected: u32) bool {
    const words = memoryValueWords(value);
    return words[0] == expected and memoryValueTailIsZero(words);
}

fn memoryValueIsZero(value: memory_mod.MemoryValue) bool {
    const words = memoryValueWords(value);
    for (words) |word| if (word != 0) return false;
    return true;
}

fn memoryValueTailIsZero(words: [8]u32) bool {
    for (words[1..]) |word| if (word != 0) return false;
    return true;
}

fn hashMemoryValue(hasher: *Blake2sMerkleHasher, value: memory_mod.MemoryValue) void {
    const dense = memoryValueWords(value);
    var split: [28]M31 = undefined;
    for (&split, 0..) |*word, index| {
        const bit_offset = index * 9;
        const limb = bit_offset / 32;
        const shift: u5 = @intCast(bit_offset % 32);
        var raw = dense[limb] >> shift;
        if (shift > 23 and limb + 1 < dense.len) {
            raw |= dense[limb + 1] << @intCast(32 - @as(u6, shift));
        }
        word.* = M31.fromCanonical(raw & 0x1ff);
    }
    hasher.updateLeaf(&split);
}

fn hashWords(hash: [32]u8) [8]u32 {
    var result: [8]u32 = undefined;
    for (&result, 0..) |*word, index| {
        const start = index * 4;
        word.* = std.mem.readInt(u32, hash[start..][0..4], .little);
    }
    return result;
}

fn syntheticInput(allocator: std.mem.Allocator) !adapter.ProverInput {
    const address_count = 23;
    const address_to_id = try allocator.alloc(memory_mod.EncodedMemoryValueId, address_count);
    errdefer allocator.free(address_to_id);
    const small_values = try allocator.alloc(u128, address_count);
    errdefer allocator.free(small_values);
    const f252_values = try allocator.alloc(memory_mod.F252, 0);
    errdefer allocator.free(f252_values);
    for (address_to_id, 0..) |*encoded, index| encoded.* = .small(@intCast(index));
    @memset(small_values, 0);
    small_values[1] = 11;
    small_values[2] = 12;
    small_values[3] = 5;
    small_values[5] = 20;
    small_values[7] = 22;
    small_values[20] = 123;
    small_values[21] = 456;

    return .{
        .state_transitions = .{
            .initial_state = .{
                .pc = M31.fromCanonical(1),
                .ap = M31.fromCanonical(5),
                .fp = M31.fromCanonical(5),
            },
            .final_state = .{
                .pc = M31.fromCanonical(9),
                .ap = M31.fromCanonical(8),
                .fp = M31.fromCanonical(5),
            },
            .casm_states_by_opcode = adapter.opcodes.CasmStatesByOpcode.init(allocator),
        },
        .memory = .{
            .config = .{},
            .address_to_id = address_to_id,
            .f252_values = f252_values,
            .small_values = small_values,
        },
        .pc_count = 0,
        .public_memory_addresses = try allocator.alloc(u32, 0),
        .builtin_segments = .{},
        .public_segment_context = .{
            true,  false, false, false, false, false,
            false, false, false, false, false,
        },
    };
}

fn claimComponent(label: []const u8, instance: u32, trace_log_size: u32) composition_bundle.Component {
    return .{
        .label = @constCast(label),
        .instance = instance,
        .trace_log_size = trace_log_size,
        .evaluation_log_size = trace_log_size,
        .n_constraints = 1,
        .random_coefficient_offset = 0,
        .trace_spans = undefined,
        .preprocessed_indices = undefined,
        .denominator_inverses = undefined,
        .ext_sources = undefined,
        .parts = undefined,
    };
}

fn claimBundle(components: []composition_bundle.Component) composition_bundle.Bundle {
    return .{
        .allocator = undefined,
        .max_kernel_instructions = 1,
        .total_constraints = 1,
        .max_evaluation_log_size = 31,
        .plan_hash = 1,
        .components = components,
    };
}

test "statement bootstrap derives flat claim order from shuffled schedule" {
    var components = [_]composition_bundle.Component{
        claimComponent("memory_id_to_small", 0, 20),
        claimComponent("memory_id_to_big", 1, 19),
        claimComponent("range_check_8", 0, 8),
        claimComponent("add_opcode", 0, 7),
        claimComponent("memory_id_to_big", 0, 18),
    };
    var bundle = claimBundle(&components);
    var flat = try deriveFlatClaimGeometry(std.testing.allocator, &bundle);
    defer flat.deinit();

    try std.testing.expectEqual(@as(usize, 83), flat.component_enable_bits.len);
    try std.testing.expect(flat.component_enable_bits[0]);
    try std.testing.expect(flat.component_enable_bits[49]);
    try std.testing.expect(flat.component_enable_bits[50]);
    try std.testing.expect(flat.component_enable_bits[65]);
    try std.testing.expect(flat.component_enable_bits[67]);
    try std.testing.expectEqualSlices(u32, &.{ 7, 18, 19, 20, 8 }, flat.component_log_sizes);
}

test "statement bootstrap imports canonical Fib25k claim geometry" {
    const components = [_]CanonicalClaimComponent{
        .{ .name = "memory_id_to_small", .log_size = 16 },
        .{ .name = "range_check_9_9" },
        .{ .name = "add_opcode", .log_size = 15 },
        .{ .name = "verify_bitwise_xor_9" },
        .{ .name = "add_opcode_small", .log_size = 16 },
        .{ .name = "add_ap_opcode", .log_size = 4 },
        .{ .name = "assert_eq_opcode", .log_size = 15 },
        .{ .name = "assert_eq_opcode_imm", .log_size = 4 },
        .{ .name = "call_opcode_rel_imm", .log_size = 15 },
        .{ .name = "jnz_opcode_non_taken", .log_size = 4 },
        .{ .name = "jnz_opcode_taken", .log_size = 15 },
        .{ .name = "ret_opcode", .log_size = 15 },
        .{ .name = "verify_instruction", .log_size = 5 },
        .{ .name = "memory_address_to_id", .log_size = 14 },
        .{ .name = "memory_id_to_big", .log_size = 15 },
        .{ .name = "range_check_6" },
        .{ .name = "range_check_8" },
        .{ .name = "range_check_11" },
        .{ .name = "range_check_12" },
        .{ .name = "range_check_18" },
        .{ .name = "range_check_20" },
        .{ .name = "range_check_4_3" },
        .{ .name = "range_check_4_4" },
        .{ .name = "range_check_7_2_5" },
        .{ .name = "range_check_3_6_6_3" },
        .{ .name = "range_check_4_4_4_4" },
        .{ .name = "range_check_3_3_3_3_3" },
        .{ .name = "verify_bitwise_xor_4" },
        .{ .name = "verify_bitwise_xor_7" },
        .{ .name = "verify_bitwise_xor_8" },
    };
    var flat = try deriveFlatClaimGeometryFromCanonical(std.testing.allocator, &components);
    defer flat.deinit();

    try std.testing.expectEqual(@as(usize, 83), flat.component_enable_bits.len);
    try std.testing.expectEqual(@as(usize, 30), std.mem.count(
        bool,
        flat.component_enable_bits,
        &.{true},
    ));
    try std.testing.expect(!flat.component_enable_bits[7]);
    try std.testing.expect(flat.component_enable_bits[8]);
    try std.testing.expect(flat.component_enable_bits[49]);
    try std.testing.expect(!flat.component_enable_bits[50]);
    try std.testing.expectEqualSlices(u32, &.{
        15, 16, 4,  15, 4,  15, 4,  15, 15, 5,
        14, 15, 16, 6,  8,  11, 12, 18, 20, 7,
        8,  18, 14, 18, 16, 15, 8,  14, 16, 18,
    }, flat.component_log_sizes);
}

test "statement bootstrap rejects noncanonical imported claim geometry" {
    const missing_dynamic_log = [_]CanonicalClaimComponent{.{ .name = "add_opcode" }};
    try std.testing.expectError(
        Error.InvalidClaimGeometry,
        deriveFlatClaimGeometryFromCanonical(std.testing.allocator, &missing_dynamic_log),
    );

    const wrong_fixed_log = [_]CanonicalClaimComponent{
        .{ .name = "range_check_8", .log_size = 7 },
    };
    try std.testing.expectError(
        Error.InvalidClaimGeometry,
        deriveFlatClaimGeometryFromCanonical(std.testing.allocator, &wrong_fixed_log),
    );

    const memory_gap = [_]CanonicalClaimComponent{
        .{ .name = "memory_id_to_big", .instance = 1, .log_size = 15 },
    };
    try std.testing.expectError(
        Error.InvalidClaimGeometry,
        deriveFlatClaimGeometryFromCanonical(std.testing.allocator, &memory_gap),
    );
}

test "statement bootstrap rejects ambiguous claim schedules" {
    var duplicate_components = [_]composition_bundle.Component{
        claimComponent("add_opcode", 0, 7),
        claimComponent("add_opcode", 0, 7),
    };
    var duplicate_bundle = claimBundle(&duplicate_components);
    try std.testing.expectError(
        Error.DuplicateClaimComponent,
        deriveFlatClaimGeometry(std.testing.allocator, &duplicate_bundle),
    );

    var gap_components = [_]composition_bundle.Component{
        claimComponent("memory_id_to_big", 1, 19),
    };
    var gap_bundle = claimBundle(&gap_components);
    try std.testing.expectError(
        Error.InvalidClaimGeometry,
        deriveFlatClaimGeometry(std.testing.allocator, &gap_bundle),
    );

    var unknown_components = [_]composition_bundle.Component{
        claimComponent("not_a_cairo_claim", 0, 7),
    };
    var unknown_bundle = claimBundle(&unknown_components);
    try std.testing.expectError(
        Error.UnknownClaimComponent,
        deriveFlatClaimGeometry(std.testing.allocator, &unknown_bundle),
    );
}

test "self-derived statement populates transcript recipe inputs without fixtures" {
    const RecordingRecipe = struct {
        const max_words = 128;

        expected_lengths: [ORDINALS.len]usize,
        lengths: [ORDINALS.len]usize = .{0} ** ORDINALS.len,
        storage: [ORDINALS.len][max_words]u32 = .{.{0} ** max_words} ** ORDINALS.len,

        fn loadInputWords(self: *@This(), ordinal: u32, input_words: []const u32) !void {
            const index = for (ORDINALS, 0..) |candidate, candidate_index| {
                if (candidate == ordinal) break candidate_index;
            } else return error.MissingRecipe;
            if (input_words.len != self.expected_lengths[index] or input_words.len > max_words)
                return error.BindingSizeMismatch;
            @memcpy(self.storage[index][0..input_words.len], input_words);
            self.lengths[index] = input_words.len;
        }

        fn words(self: *const @This(), ordinal: u32) ?[]const u32 {
            for (ORDINALS, 0..) |candidate, index| {
                if (candidate == ordinal) return self.storage[index][0..self.lengths[index]];
            }
            return null;
        }
    };

    const allocator = std.testing.allocator;
    var prover_input = try syntheticInput(allocator);
    defer prover_input.deinit(allocator);
    var components = [_]composition_bundle.Component{
        claimComponent("memory_id_to_small", 0, 20),
        claimComponent("add_opcode", 0, 7),
        claimComponent("memory_id_to_big", 0, 18),
    };
    var composition = claimBundle(&components);
    var bootstrap = try initFromCompositionSchedule(allocator, .{
        .channel_salt = 7,
        .pcs = .{
            .pow_bits = 26,
            .log_blowup_factor = 1,
            .n_queries = 70,
            .log_last_layer_degree_bound = 0,
            .fold_step = 3,
        },
        .composition = &composition,
        .prover_input = &prover_input,
    });
    defer bootstrap.deinit();

    var lengths: [ORDINALS.len]usize = undefined;
    for (ORDINALS, &lengths) |ordinal, *length| length.* = bootstrap.words(ordinal).?.len;
    var recipe = RecordingRecipe{ .expected_lengths = lengths };
    try bootstrap.populateTranscriptRecipeInputs(&recipe);
    for (ORDINALS) |ordinal| {
        try std.testing.expectEqualSlices(u32, bootstrap.words(ordinal).?, recipe.words(ordinal).?);
    }
}

test "compact statement v1 serializes the transcript's authoritative public data" {
    const allocator = std.testing.allocator;
    var prover_input = try syntheticInput(allocator);
    defer prover_input.deinit(allocator);
    var components = [_]composition_bundle.Component{
        claimComponent("memory_id_to_small", 0, 20),
        claimComponent("add_opcode", 0, 7),
        claimComponent("memory_id_to_big", 0, 18),
    };
    var composition = claimBundle(&components);
    const encoded = try encodeCompactStatementV1(allocator, &composition, &prover_input);
    defer allocator.free(encoded);
    var flat = try deriveFlatClaimGeometry(allocator, &composition);
    defer flat.deinit();
    const runtime_encoded = try encodeCompactStatementFromFlatClaimV1(allocator, .{
        .component_enable_bits = flat.component_enable_bits,
        .component_log_sizes = flat.component_log_sizes,
    }, &prover_input);
    defer allocator.free(runtime_encoded);
    try std.testing.expectEqualSlices(u8, encoded, runtime_encoded);

    try std.testing.expectEqualSlices(u8, &compact_statement_magic, encoded[0..8]);
    try std.testing.expectEqual(compact_statement_version, std.mem.readInt(u16, encoded[8..10], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, encoded[16..20], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, encoded[48..52], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, encoded[52..56], .little));
    try std.testing.expectEqual(@as(u32, 83), std.mem.readInt(u32, encoded[56..60], .little));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, encoded[60..64], .little));
    try std.testing.expectEqual(@as(usize, 788), encoded.len);

    const first_segment = compact_statement_header_bytes;
    for ([_]u32{ 1, 5, 20, 7, 22 }, 0..) |expected, index| {
        const offset = first_segment + index * 4;
        try std.testing.expectEqual(expected, std.mem.readInt(u32, encoded[offset..][0..4], .little));
    }
    const first_program = compact_statement_header_bytes + adapter.N_PUBLIC_SEGMENTS * 5 * 4;
    for ([_]u32{ 1, 11, 0, 0, 0, 0, 0, 0, 0 }, 0..) |expected, index| {
        const offset = first_program + index * 4;
        try std.testing.expectEqual(expected, std.mem.readInt(u32, encoded[offset..][0..4], .little));
    }
}

test "compact statement v1 rejects noncanonical runtime flat geometry" {
    const allocator = std.testing.allocator;
    var prover_input = try syntheticInput(allocator);
    defer prover_input.deinit(allocator);
    var enable_bits = [_]bool{false} ** claim_registry.enable_slot_count;
    enable_bits[67] = true;
    const wrong_fixed_log = [_]u32{7};
    try std.testing.expectError(
        Error.InvalidClaimGeometry,
        encodeCompactStatementFromFlatClaimV1(allocator, .{
            .component_enable_bits = &enable_bits,
            .component_log_sizes = &wrong_fixed_log,
        }, &prover_input),
    );

    var memory_gap = [_]bool{false} ** claim_registry.enable_slot_count;
    memory_gap[50] = true;
    const memory_log = [_]u32{15};
    try std.testing.expectError(
        Error.InvalidClaimGeometry,
        encodeCompactStatementFromFlatClaimV1(allocator, .{
            .component_enable_bits = &memory_gap,
            .component_log_sizes = &memory_log,
        }, &prover_input),
    );
}

test "compact statement v1 matches an independently encoded SN2 statement" {
    const allocator = std.testing.allocator;
    const expected_path = std.process.getEnvVarOwned(
        allocator,
        "STWO_ZIG_TEST_SN2_COMPACT_STATEMENT",
    ) catch return error.SkipZigTest;
    defer allocator.free(expected_path);
    const expected = try std.fs.cwd().readFileAlloc(allocator, expected_path, 16 * 1024 * 1024);
    defer allocator.free(expected);
    var prover_input = try adapter.adapted_input.readFile(
        allocator,
        "/private/tmp/SN_PIE_2.generic.stwzcpi",
    );
    defer prover_input.deinit(allocator);
    var composition = try composition_bundle.Bundle.readFile(
        allocator,
        "vectors/cairo/sn_pie_2_composition.bin",
    );
    defer composition.deinit();
    const actual = try encodeCompactStatementV1(allocator, &composition, &prover_input);
    defer allocator.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "statement bootstrap derives canonical shapes and roots" {
    const allocator = std.testing.allocator;
    var prover_input = try syntheticInput(allocator);
    defer prover_input.deinit(allocator);
    const enable = [_]bool{ true, false, true };
    const logs = [_]u32{ 4, 5 };
    var bootstrap = try init(allocator, .{
        .channel_salt = 7,
        .pcs = .{
            .pow_bits = 26,
            .log_blowup_factor = 1,
            .n_queries = 70,
            .log_last_layer_degree_bound = 0,
            .fold_step = 3,
        },
        .component_enable_bits = &enable,
        .component_log_sizes = &logs,
        .prover_input = &prover_input,
    });
    defer bootstrap.deinit();

    try std.testing.expectEqualSlices(u32, &.{ 7, 0, 0, 0 }, bootstrap.ordinal_1);
    try std.testing.expectEqualSlices(u32, &.{ 3, 0, 0, 0 }, bootstrap.ordinal_10);
    try std.testing.expectEqualSlices(u32, &.{ 1, 0, 1, 0 }, bootstrap.ordinal_11);
    try std.testing.expectEqualSlices(u32, &.{ 4, 5, 0, 0 }, bootstrap.ordinal_12);
    try std.testing.expectEqualSlices(u32, &.{ 2, 0, 0, 0 }, bootstrap.ordinal_13);
    try std.testing.expectEqual(@as(usize, 56), bootstrap.ordinal_14.len);
    try std.testing.expectEqualSlices(u32, &.{ 1, 5, 5, 9, 8, 5 }, bootstrap.ordinal_14[0..6]);
    try std.testing.expectEqualSlices(u32, &.{ 5, 20, 7, 22 }, bootstrap.ordinal_14[6..10]);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 20, 21, 1, 2 }, bootstrap.ordinal_14[50..56]);
    try std.testing.expectEqual(@as(usize, 8), bootstrap.ordinal_15.len);
    try std.testing.expectEqual(@as(usize, 8), bootstrap.ordinal_16.len);
    try std.testing.expect(bootstrap.words(3) == null);
}

test "statement bootstrap roots and public IDs respond to memory mutation" {
    const allocator = std.testing.allocator;
    var prover_input = try syntheticInput(allocator);
    defer prover_input.deinit(allocator);
    const enable = [_]bool{true};
    const logs = [_]u32{4};
    const statement = StatementBootstrapInput{
        .channel_salt = 0,
        .pcs = .{
            .pow_bits = 26,
            .log_blowup_factor = 1,
            .n_queries = 70,
            .log_last_layer_degree_bound = 0,
            .fold_step = 3,
        },
        .component_enable_bits = &enable,
        .component_log_sizes = &logs,
        .prover_input = &prover_input,
    };
    var before = try init(allocator, statement);
    defer before.deinit();

    prover_input.memory.small_values[20] += 1;
    var output_mutated = try init(allocator, statement);
    defer output_mutated.deinit();
    try std.testing.expect(!std.mem.eql(u32, before.ordinal_15, output_mutated.ordinal_15));
    try std.testing.expectEqualSlices(u32, before.ordinal_16, output_mutated.ordinal_16);

    prover_input.memory.address_to_id[20] = .small(22);
    var id_mutated = try init(allocator, statement);
    defer id_mutated.deinit();
    try std.testing.expect(!std.mem.eql(u32, output_mutated.ordinal_14, id_mutated.ordinal_14));
}

test "statement bootstrap rejects malformed public memory shape" {
    const allocator = std.testing.allocator;
    var prover_input = try syntheticInput(allocator);
    defer prover_input.deinit(allocator);
    const enable = [_]bool{true};
    const logs = [_]u32{4};
    const statement = StatementBootstrapInput{
        .channel_salt = 0,
        .pcs = .{
            .pow_bits = 26,
            .log_blowup_factor = 1,
            .n_queries = 70,
            .log_last_layer_degree_bound = 0,
            .fold_step = 3,
        },
        .component_enable_bits = &enable,
        .component_log_sizes = &logs,
        .prover_input = &prover_input,
    };

    prover_input.public_segment_context[0] = false;
    try std.testing.expectError(Error.InvalidPublicSegmentContext, init(allocator, statement));
    prover_input.public_segment_context[0] = true;
    prover_input.memory.small_values[3] = 6;
    try std.testing.expectError(Error.InvalidSafeCall, init(allocator, statement));
}

fn jsonWords(allocator: std.mem.Allocator, inputs: std.json.ObjectMap, ordinal: u32) ![]u32 {
    var key_buffer: [8]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buffer, "{}", .{ordinal});
    const value = inputs.get(key) orelse return error.MissingOrdinal;
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidOrdinalWords,
    };
    const result = try allocator.alloc(u32, array.items.len);
    errdefer allocator.free(result);
    for (array.items, result) |item, *word| {
        const integer = switch (item) {
            .integer => |number| number,
            else => return error.InvalidOrdinalWords,
        };
        word.* = std.math.cast(u32, integer) orelse return error.InvalidOrdinalWords;
    }
    return result;
}

test "statement bootstrap matches actual SN PIE 1 through 4 fixtures" {
    const allocator = std.testing.allocator;
    const enabled = std.process.getEnvVarOwned(allocator, "STWO_ZIG_TEST_SN_PIE_STATEMENT_FIXTURES") catch
        return error.SkipZigTest;
    defer allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;

    for (1..5) |pie_number| {
        var fixture_path_buffer: [128]u8 = undefined;
        const fixture_path = try std.fmt.bufPrint(
            &fixture_path_buffer,
            "/private/tmp/SN_PIE_{}.fold3.reference.transcript-inputs.json",
            .{pie_number},
        );
        const encoded = try std.fs.cwd().readFileAlloc(allocator, fixture_path, 16 * 1024 * 1024);
        defer allocator.free(encoded);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
        defer parsed.deinit();
        const inputs_value = parsed.value.object.get("inputs") orelse return error.MissingInputs;
        const inputs = switch (inputs_value) {
            .object => |object| object,
            else => return error.InvalidInputs,
        };

        var adapted_path_buffer: [96]u8 = undefined;
        const adapted_path = try std.fmt.bufPrint(
            &adapted_path_buffer,
            "/private/tmp/SN_PIE_{}.generic.stwzcpi",
            .{pie_number},
        );
        var prover_input = try adapter.adapted_input.readFile(allocator, adapted_path);
        defer prover_input.deinit(allocator);

        var composition_path_buffer: [96]u8 = undefined;
        const composition_path = if (pie_number == 2)
            "vectors/cairo/sn_pie_2_composition.bin"
        else
            try std.fmt.bufPrint(
                &composition_path_buffer,
                "/private/tmp/SN_PIE_{}.composition.bin",
                .{pie_number},
            );
        var composition = try composition_bundle.Bundle.readFile(allocator, composition_path);
        defer composition.deinit();

        var bootstrap = try initFromCompositionSchedule(allocator, .{
            .channel_salt = 0,
            .pcs = .{
                .pow_bits = 26,
                .log_blowup_factor = 1,
                .n_queries = 70,
                .log_last_layer_degree_bound = 0,
                .fold_step = 3,
            },
            .composition = &composition,
            .prover_input = &prover_input,
        });
        defer bootstrap.deinit();

        for (ORDINALS) |ordinal| {
            const expected = try jsonWords(allocator, inputs, ordinal);
            defer allocator.free(expected);
            try std.testing.expectEqualSlices(u32, expected, bootstrap.words(ordinal).?);
        }
    }
}
