//! Backend-neutral Cairo quotient mask and sample-point geometry.

const std = @import("std");
const composition_bundle = @import("composition_bundle.zig");
const circle = @import("../../../core/circle.zig");
const canonic = @import("../../../core/poly/circle/canonic.zig");
const QM31 = @import("../../../core/fields/qm31.zig").QM31;

pub const m31_prime: u32 = 0x7fff_ffff;

const Span = struct { start: usize, end: usize };

pub const Masks = struct {
    allocator: std.mem.Allocator,
    preprocessed_used: []bool,
    base_offsets: []std.ArrayList(i32),
    interaction_offsets: []std.ArrayList(i32),

    pub fn deinit(self: *Masks) void {
        self.allocator.free(self.preprocessed_used);
        freeOffsetLists(self.allocator, self.base_offsets);
        freeOffsetLists(self.allocator, self.interaction_offsets);
        self.* = undefined;
    }
};

pub fn canonicalWords(words: []const u32) !void {
    for (words) |word| if (word >= m31_prime) return error.NonCanonicalQuotientReference;
}

pub fn deriveMasks(
    allocator: std.mem.Allocator,
    bundle: composition_bundle.Bundle,
    preprocessed_count: usize,
    base_count: usize,
    interaction_count: usize,
) !Masks {
    const preprocessed_used = try allocator.alloc(bool, preprocessed_count);
    errdefer allocator.free(preprocessed_used);
    @memset(preprocessed_used, false);
    const base_offsets = try allocateOffsetLists(allocator, base_count);
    errdefer freeOffsetLists(allocator, base_offsets);
    const interaction_offsets = try allocateOffsetLists(allocator, interaction_count);
    errdefer freeOffsetLists(allocator, interaction_offsets);

    for (bundle.components) |component| {
        const base_span = try componentSpan(component, 1, base_count);
        const interaction_span = try componentSpan(component, 2, interaction_count);
        for (component.parts) |part| for (part.program.base_insts) |instruction| switch (instruction.op) {
            .preprocessed_col => {
                if (instruction.a >= component.preprocessed_indices.len) return error.InvalidQuotientMask;
                const column = component.preprocessed_indices[instruction.a];
                if (column >= preprocessed_used.len) return error.InvalidQuotientMask;
                preprocessed_used[column] = true;
            },
            .trace_col => switch (instruction.interaction) {
                0 => {
                    if (instruction.a >= component.preprocessed_indices.len) return error.InvalidQuotientMask;
                    const column = component.preprocessed_indices[instruction.a];
                    if (column >= preprocessed_used.len) return error.InvalidQuotientMask;
                    preprocessed_used[column] = true;
                },
                1 => try appendUnique(
                    allocator,
                    &base_offsets[base_span.start + instruction.a],
                    instruction.imm,
                    base_span,
                    instruction.a,
                ),
                2 => try appendUnique(
                    allocator,
                    &interaction_offsets[interaction_span.start + instruction.a],
                    instruction.imm,
                    interaction_span,
                    instruction.a,
                ),
                else => return error.InvalidQuotientMask,
            },
            else => {},
        };
    }
    return .{
        .allocator = allocator,
        .preprocessed_used = preprocessed_used,
        .base_offsets = base_offsets,
        .interaction_offsets = interaction_offsets,
    };
}

pub fn validatedLiftingLogSize(lifting_log_size: u32) !u32 {
    if (lifting_log_size <= 3 or lifting_log_size > circle.M31_CIRCLE_LOG_ORDER)
        return error.InvalidQuotientInputShape;
    return lifting_log_size;
}

fn componentSpan(component: composition_bundle.Component, tree: u32, tree_len: usize) !Span {
    var found: ?Span = null;
    for (component.trace_spans) |span| {
        if (span.tree != tree) continue;
        if (found != null or span.start > span.end or span.end > tree_len) return error.InvalidQuotientMask;
        found = .{ .start = span.start, .end = span.end };
    }
    return found orelse error.InvalidQuotientMask;
}

fn allocateOffsetLists(allocator: std.mem.Allocator, count: usize) ![]std.ArrayList(i32) {
    const lists = try allocator.alloc(std.ArrayList(i32), count);
    for (lists) |*list| list.* = .empty;
    return lists;
}

fn freeOffsetLists(allocator: std.mem.Allocator, lists: []std.ArrayList(i32)) void {
    for (lists) |*list| list.deinit(allocator);
    allocator.free(lists);
}

fn appendUnique(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(i32),
    offset: i32,
    span: Span,
    local_column: u32,
) !void {
    if (local_column >= span.end - span.start) return error.InvalidQuotientMask;
    for (list.items) |existing| if (existing == offset) return;
    try list.append(allocator, offset);
}
pub fn secureFromWords(words: []const u32) QM31 {
    std.debug.assert(words.len == 4);
    return QM31.fromU32Unchecked(words[0], words[1], words[2], words[3]);
}

pub fn pointFromParameter(parameter: QM31) !circle.CirclePointQM31 {
    const square = parameter.square();
    const inverse = square.add(QM31.one()).inv() catch return error.InvalidOodsPoint;
    return .{
        .x = QM31.one().sub(square).mul(inverse),
        .y = parameter.add(parameter).mul(inverse),
    };
}

pub fn pointM31IntoQM31(point: circle.CirclePointM31) circle.CirclePointQM31 {
    return .{ .x = QM31.fromBase(point.x), .y = QM31.fromBase(point.y) };
}

pub fn pointLessThan(lhs: circle.CirclePointQM31, rhs: circle.CirclePointQM31) bool {
    const lhs_words = lhs.x.toM31Array() ++ lhs.y.toM31Array();
    const rhs_words = rhs.x.toM31Array() ++ rhs.y.toM31Array();
    for (lhs_words, rhs_words) |lhs_word, rhs_word| {
        if (lhs_word.v != rhs_word.v) return lhs_word.v < rhs_word.v;
    }
    return false;
}
test "Cairo quotient geometry: SN2 mask has 19 sample batches with the reference partial logs" {
    @setEvalBranchQuota(10_000);
    var bundle = try composition_bundle.Bundle.readFile(
        std.testing.allocator,
        "vectors/cairo/sn_pie_2_composition.bin",
    );
    defer bundle.deinit();
    const lifting_log_size = try validatedLiftingLogSize(bundle.max_evaluation_log_size);
    const max_trace_log_size = lifting_log_size - 1;
    var masks = try deriveMasks(std.testing.allocator, bundle, 161, 3449, 2268);
    defer masks.deinit();

    var oods_count: usize = 8;
    for (masks.preprocessed_used) |used| oods_count += @intFromBool(used);
    for (masks.base_offsets) |offsets| oods_count += offsets.items.len;
    for (masks.interaction_offsets) |offsets| oods_count += offsets.items.len;
    try std.testing.expectEqual(@as(usize, 6110), oods_count);

    const base_logs = try traceLogs(std.testing.allocator, bundle, 1, masks.base_offsets.len);
    defer std.testing.allocator.free(base_logs);
    const interaction_logs = try traceLogs(std.testing.allocator, bundle, 2, masks.interaction_offsets.len);
    defer std.testing.allocator.free(interaction_logs);
    const parameter = QM31.fromU32Unchecked(846579577, 1914966500, 886709583, 1440664798);
    const oods_point = try pointFromParameter(parameter);
    const trace_step = pointM31IntoQM31(canonic.CanonicCoset.new(max_trace_log_size).step());
    const lifting_generator = canonic.CanonicCoset.new(lifting_log_size).step();
    var logs_by_point = std.AutoHashMap(circle.CirclePointQM31, u32).init(std.testing.allocator);
    defer logs_by_point.deinit();
    try updatePointLog(&logs_by_point, oods_point, max_trace_log_size);
    for (masks.base_offsets, base_logs) |offsets, log_size| {
        for (offsets.items) |offset| try updatePointLog(
            &logs_by_point,
            oods_point.add(trace_step.mulSigned(offset)),
            log_size,
        );
        if (offsets.items.len == 2) try updatePointLog(
            &logs_by_point,
            oods_point.add(trace_step.mulSigned(offsets.items[1])).add(
                pointM31IntoQM31(lifting_generator.repeatedDouble(log_size + 1)),
            ),
            log_size,
        );
    }
    for (masks.interaction_offsets, interaction_logs) |offsets, log_size| {
        for (offsets.items) |offset| try updatePointLog(
            &logs_by_point,
            oods_point.add(trace_step.mulSigned(offset)),
            log_size,
        );
        if (offsets.items.len == 2) try updatePointLog(
            &logs_by_point,
            oods_point.add(trace_step.mulSigned(offsets.items[1])).add(
                pointM31IntoQM31(lifting_generator.repeatedDouble(log_size + 1)),
            ),
            log_size,
        );
    }
    var found_logs = try std.testing.allocator.alloc(u32, logs_by_point.count());
    defer std.testing.allocator.free(found_logs);
    var iterator = logs_by_point.valueIterator();
    var index: usize = 0;
    while (iterator.next()) |log_size| : (index += 1) found_logs[index] = log_size.*;
    std.mem.sort(u32, found_logs, {}, std.sort.asc(u32));
    const expected = [_]u32{ 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 23, 23 };
    try std.testing.expectEqualSlices(u32, &expected, found_logs);

    const reference_points = [_][9]u32{
        .{ 14, 445372541, 1092951465, 1937492379, 1741050069, 121692003, 1608055819, 1454547682, 1593254727 },
        .{ 4, 484424958, 59829562, 256131572, 1338900763, 900826934, 1604527622, 108623509, 526566284 },
        .{ 21, 525035803, 1088825149, 323592314, 192277391, 1058980337, 1019540402, 1169599338, 638809582 },
        .{ 6, 767508393, 2115198925, 1843087753, 2025960515, 751518033, 1141333622, 1947451246, 421367053 },
        .{ 15, 779763653, 1636038482, 192064866, 527045910, 196438127, 1298266339, 1660792984, 1380706413 },
        .{ 13, 974335912, 1795692920, 1772739649, 565152841, 1859874711, 577277296, 2096796993, 1804450951 },
        .{ 12, 1062229442, 1534487438, 417657836, 1813561061, 914272876, 1566962871, 1617148800, 503065456 },
        .{ 23, 1088503310, 1127943245, 977884309, 1508674065, 525035803, 1088825149, 323592314, 192277391 },
        .{ 8, 1147498412, 1682502947, 604657200, 1934484738, 748490768, 683428971, 1237496906, 501711744 },
        .{ 10, 1186089343, 1858683932, 1377241751, 450379047, 569783259, 43759836, 1092348743, 124278569 },
        .{ 16, 1257102701, 1252171081, 1925056363, 1723107290, 2046002179, 784376680, 826551315, 280272916 },
        .{ 20, 1402265644, 432374817, 2055720338, 986735970, 361127530, 225967531, 636639488, 817803657 },
        .{ 18, 1492953197, 1087151664, 1115585517, 1137606051, 555855364, 1753831263, 763591256, 1744387696 },
        .{ 11, 1549526234, 1184890108, 1723548676, 144693332, 2130289263, 331389383, 400976595, 445526442 },
        .{ 19, 1615873698, 2128601643, 415723873, 1776882859, 1609276372, 643677304, 2070842543, 438095759 },
        .{ 17, 1863123986, 1607251448, 1434703069, 1731883500, 970243058, 1030755838, 253489516, 645254088 },
        .{ 9, 1977806255, 2147059310, 1300592184, 1048430120, 1746574005, 1138685808, 171335228, 437360123 },
        .{ 7, 2045635317, 1095316091, 1249771119, 677632478, 1784052439, 1242092662, 1337741234, 1650121225 },
        .{ 23, 2100911427, 2110974293, 1566596213, 79180041, 592238137, 1137599031, 141723729, 555328319 },
    };
    for (reference_points) |entry| {
        const point = circle.CirclePointQM31{
            .x = secureFromWords(entry[1..5]),
            .y = secureFromWords(entry[5..9]),
        };
        try std.testing.expectEqual(entry[0], logs_by_point.get(point) orelse return error.MissingReferencePoint);
    }
}

fn traceLogs(
    allocator: std.mem.Allocator,
    bundle: composition_bundle.Bundle,
    tree: u32,
    count: usize,
) ![]u32 {
    const logs = try allocator.alloc(u32, count);
    errdefer allocator.free(logs);
    @memset(logs, 0);
    for (bundle.components) |component| {
        const span = try componentSpan(component, tree, count);
        for (logs[span.start..span.end]) |*log_size| {
            if (log_size.* != 0) return error.InvalidQuotientMask;
            log_size.* = component.trace_log_size;
        }
    }
    for (logs) |log_size| if (log_size == 0) return error.InvalidQuotientMask;
    return logs;
}

fn updatePointLog(
    logs: *std.AutoHashMap(circle.CirclePointQM31, u32),
    point: circle.CirclePointQM31,
    log_size: u32,
) !void {
    const entry = try logs.getOrPut(point);
    if (!entry.found_existing) entry.value_ptr.* = log_size else entry.value_ptr.* = @max(entry.value_ptr.*, log_size);
}
