//! Backend-neutral reference construction for Cairo lookup interaction traces.
//!
//! Relation descriptors and lookup words are borrowed from the caller. The
//! evaluator owns only O(relation columns) scratch and can therefore stream
//! rows into checkpoint digests without materializing the complete trace.

const std = @import("std");
const m31_mod = @import("../../../core/fields/m31.zig");
const M31 = m31_mod.M31;
const QM31 = @import("../../../core/fields/qm31.zig").QM31;

const descriptor_words = 16;
const use_words = 7;

pub const Error = error{
    DivisionByZero,
    InvalidDescriptor,
    InvalidRow,
    InvalidRowCount,
    InvalidSourceShape,
    InvalidTraceShape,
    NonCanonicalM31,
    OutOfMemory,
};

/// Column-major lookup words consumed by relation descriptors.
pub const LookupColumns = struct {
    words: []const u32,
    rows: usize,
    columns: usize,

    pub fn init(words: []const u32, rows: usize) Error!LookupColumns {
        if (rows == 0 or words.len % rows != 0) return Error.InvalidSourceShape;
        return .{
            .words = words,
            .rows = rows,
            .columns = words.len / rows,
        };
    }

    fn value(self: LookupColumns, column: usize, row: usize) Error!M31 {
        if (column >= self.columns or row >= self.rows) return Error.InvalidSourceShape;
        const raw = self.words[column * self.rows + row];
        if (raw >= m31_mod.Modulus) return Error.NonCanonicalM31;
        return M31.fromCanonical(raw);
    }
};

/// Streaming scalar reference for the relation fractions of one lookup trace.
///
/// `descriptors`, `source`, and `alpha_powers` remain caller-owned and must
/// outlive the evaluator. Each descriptor occupies 16 words and represents
/// either one fraction or the sum of two fractions.
pub const Reference = struct {
    allocator: std.mem.Allocator,
    descriptors: []const u32,
    source: LookupColumns,
    z: QM31,
    alpha_powers: []const QM31,
    numerators: []QM31,
    denominators: []QM31,
    denominator_prefixes: []QM31,

    pub fn init(
        allocator: std.mem.Allocator,
        descriptors: []const u32,
        source: LookupColumns,
        z: QM31,
        alpha_powers: []const QM31,
    ) Error!Reference {
        try validateDescriptors(descriptors, source.columns, alpha_powers.len);
        const columns = descriptors.len / descriptor_words;
        const numerators = try allocator.alloc(QM31, columns);
        errdefer allocator.free(numerators);
        const denominators = try allocator.alloc(QM31, columns);
        errdefer allocator.free(denominators);
        const denominator_prefixes = try allocator.alloc(QM31, columns);
        errdefer allocator.free(denominator_prefixes);
        return .{
            .allocator = allocator,
            .descriptors = descriptors,
            .source = source,
            .z = z,
            .alpha_powers = alpha_powers,
            .numerators = numerators,
            .denominators = denominators,
            .denominator_prefixes = denominator_prefixes,
        };
    }

    pub fn deinit(self: *Reference) void {
        self.allocator.free(self.numerators);
        self.allocator.free(self.denominators);
        self.allocator.free(self.denominator_prefixes);
        self.* = undefined;
    }

    pub fn columnCount(self: Reference) usize {
        return self.descriptors.len / descriptor_words;
    }

    /// Evaluates one row using one batch inversion across all relation columns.
    /// `cumulative_sums[i]` receives the sum of fractions through column `i`.
    pub fn evaluateRow(
        self: *Reference,
        row: usize,
        cumulative_sums: []QM31,
    ) Error!QM31 {
        if (row >= self.source.rows) return Error.InvalidRow;
        if (cumulative_sums.len != self.columnCount()) return Error.InvalidTraceShape;

        var denominator_product = QM31.one();
        var descriptor_index: usize = 0;
        while (descriptor_index < self.descriptors.len) : (descriptor_index += descriptor_words) {
            const descriptor = self.descriptors[descriptor_index..][0..descriptor_words];
            const column = descriptor_index / descriptor_words;
            const a = descriptor[1..][0..use_words];
            const denominator_a = try self.combine(row, a);
            const multiplicity_a = try self.multiplicity(row, a);
            if (descriptor[0] == 2) {
                const b = descriptor[8..][0..use_words];
                const denominator_b = try self.combine(row, b);
                const multiplicity_b = try self.multiplicity(row, b);
                self.numerators[column] = denominator_a.mulM31(multiplicity_b)
                    .add(denominator_b.mulM31(multiplicity_a));
                self.denominators[column] = denominator_a.mul(denominator_b);
            } else {
                self.numerators[column] = QM31.fromBase(multiplicity_a);
                self.denominators[column] = denominator_a;
            }
            self.denominator_prefixes[column] = denominator_product;
            denominator_product = denominator_product.mul(self.denominators[column]);
        }

        var running_inverse = denominator_product.inv() catch return Error.DivisionByZero;
        var column = self.columnCount();
        while (column != 0) {
            column -= 1;
            self.numerators[column] = self.numerators[column]
                .mul(running_inverse.mul(self.denominator_prefixes[column]));
            running_inverse = running_inverse.mul(self.denominators[column]);
        }

        var total = QM31.zero();
        for (self.numerators, cumulative_sums) |fraction, *sum| {
            total = total.add(fraction);
            sum.* = total;
        }
        return total;
    }

    fn combine(self: Reference, row: usize, use: []const u32) Error!QM31 {
        var denominator = self.z.neg();
        for (0..use[2]) |word| {
            const value = if (word == 0)
                M31.fromCanonical(use[3])
            else
                try self.source.value(use[1] + word, row);
            denominator = denominator.add(self.alpha_powers[word].mulM31(value));
        }
        return denominator;
    }

    fn multiplicity(self: Reference, row: usize, use: []const u32) Error!M31 {
        const value = switch (use[4]) {
            0 => M31.one(),
            2 => try self.source.value(use[5], row),
            else => unreachable,
        };
        return if (use[6] == 0) value else value.neg();
    }
};

/// Converts row totals into the final logup column in place.
///
/// The scan follows Stwo's circle-domain order and removes `claimed_sum / rows`
/// at every step. The returned final prefix is zero when `claimed_sum` equals
/// the sum of the original row totals.
pub fn scanLastColumnInPlace(values: []QM31, claimed_sum: QM31) Error!QM31 {
    try validateScanRows(values.len);
    const row_count = M31.fromCanonical(@intCast(values.len));
    const row_count_inverse = row_count.inv() catch return Error.InvalidRowCount;
    const shift = claimed_sum.mulM31(row_count_inverse);
    var prefix = QM31.zero();
    for (0..values.len) |scan_index| {
        const row = circleScanRowUnchecked(values.len, scan_index);
        prefix = prefix.add(values[row]).sub(shift);
        values[row] = prefix;
    }
    return prefix;
}

/// Maps a scan ordinal to the bit-reversed circle-domain row it visits.
pub fn circleScanRow(rows: usize, scan_index: usize) Error!usize {
    try validateScanRows(rows);
    if (scan_index >= rows) return Error.InvalidRow;
    return circleScanRowUnchecked(rows, scan_index);
}

fn validateDescriptors(
    descriptors: []const u32,
    source_columns: usize,
    alpha_power_count: usize,
) Error!void {
    if (descriptors.len == 0 or descriptors.len % descriptor_words != 0)
        return Error.InvalidDescriptor;
    var descriptor_index: usize = 0;
    while (descriptor_index < descriptors.len) : (descriptor_index += descriptor_words) {
        const descriptor = descriptors[descriptor_index..][0..descriptor_words];
        if (descriptor[0] < 1 or descriptor[0] > 2) return Error.InvalidDescriptor;
        for (0..descriptor[0]) |use_index| {
            const use = descriptor[1 + use_index * use_words ..][0..use_words];
            if (use[0] != 0 or use[2] == 0 or use[2] > alpha_power_count or
                use[3] >= m31_mod.Modulus or (use[4] != 0 and use[4] != 2) or use[6] > 1)
                return Error.InvalidDescriptor;
            if (use[2] > 1) {
                const last_source = std.math.add(usize, use[1], use[2] - 1) catch
                    return Error.InvalidDescriptor;
                if (last_source >= source_columns) return Error.InvalidDescriptor;
            }
            if (use[4] == 2 and use[5] >= source_columns) return Error.InvalidDescriptor;
        }
    }
}

fn validateScanRows(rows: usize) Error!void {
    if (rows == 0 or !std.math.isPowerOfTwo(rows) or rows >= m31_mod.Modulus or
        rows > std.math.maxInt(u32))
        return Error.InvalidRowCount;
}

fn circleScanRowUnchecked(rows: usize, scan_index: usize) usize {
    const circle_index = if ((scan_index & 1) == 0)
        scan_index / 2
    else
        rows - 1 - scan_index / 2;
    const log_rows = std.math.log2_int(u32, @intCast(rows));
    return @bitReverse(@as(u32, @intCast(circle_index))) >>
        @intCast(@as(u32, 32) - @as(u32, log_rows));
}

fn base(value: u32) QM31 {
    return QM31.fromBase(M31.fromCanonical(value));
}

fn singleDescriptor(
    relation_id: u32,
    source_start: u32,
    relation_words: u32,
    multiplicity_column: ?u32,
    negate: bool,
) [descriptor_words]u32 {
    var descriptor = [_]u32{0} ** descriptor_words;
    descriptor[0] = 1;
    descriptor[1] = 0;
    descriptor[2] = source_start;
    descriptor[3] = relation_words;
    descriptor[4] = relation_id;
    descriptor[5] = if (multiplicity_column == null) 0 else 2;
    descriptor[6] = multiplicity_column orelse 0;
    descriptor[7] = @intFromBool(negate);
    return descriptor;
}

test "Cairo interaction reference evaluates a dynamic single relation" {
    const source_words = [_]u32{ 99, 98, 2, 3 };
    const source = try LookupColumns.init(&source_words, 2);
    const alpha_powers = [_]QM31{
        QM31.fromU32Unchecked(2, 3, 5, 7),
        QM31.fromU32Unchecked(11, 13, 17, 19),
    };
    const z = QM31.fromU32Unchecked(23, 29, 31, 37);
    const descriptor = singleDescriptor(9, 0, 2, 1, false);
    var reference = try Reference.init(std.testing.allocator, &descriptor, source, z, &alpha_powers);
    defer reference.deinit();

    var cumulative: [1]QM31 = undefined;
    const actual = try reference.evaluateRow(0, &cumulative);
    const denominator = z.neg()
        .add(alpha_powers[0].mulM31(M31.fromCanonical(9)))
        .add(alpha_powers[1].mulM31(M31.fromCanonical(2)));
    const expected = try base(2).div(denominator);
    try std.testing.expect(QM31.eql(expected, actual));
    try std.testing.expect(QM31.eql(expected, cumulative[0]));
}

test "Cairo interaction reference batches paired fractions and cumulative columns" {
    const source_words = [_]u32{ 90, 91, 4, 5, 6, 7 };
    const source = try LookupColumns.init(&source_words, 2);
    const alpha_powers = [_]QM31{ base(3), base(11) };
    const z = base(101);
    const first = singleDescriptor(13, 0, 1, null, false);
    var second = [_]u32{0} ** descriptor_words;
    second[0] = 2;
    second[1..8].* = .{ 0, 0, 2, 17, 2, 1, 0 };
    second[8..15].* = .{ 0, 1, 2, 19, 2, 2, 1 };
    var descriptors: [descriptor_words * 2]u32 = undefined;
    descriptors[0..descriptor_words].* = first;
    descriptors[descriptor_words..].* = second;
    var reference = try Reference.init(std.testing.allocator, &descriptors, source, z, &alpha_powers);
    defer reference.deinit();

    var cumulative: [2]QM31 = undefined;
    const actual = try reference.evaluateRow(0, &cumulative);
    const d0 = z.neg().add(alpha_powers[0].mulM31(M31.fromCanonical(13)));
    const d1 = z.neg().add(alpha_powers[0].mulM31(M31.fromCanonical(17)))
        .add(alpha_powers[1].mulM31(M31.fromCanonical(4)));
    const d2 = z.neg().add(alpha_powers[0].mulM31(M31.fromCanonical(19)))
        .add(alpha_powers[1].mulM31(M31.fromCanonical(6)));
    const fraction0 = try base(1).div(d0);
    const fraction1 = (try base(4).div(d1)).add(try base(6).neg().div(d2));
    try std.testing.expect(QM31.eql(fraction0, cumulative[0]));
    try std.testing.expect(QM31.eql(fraction0.add(fraction1), cumulative[1]));
    try std.testing.expect(QM31.eql(cumulative[1], actual));
}

test "Cairo interaction reference scans the final column in circle order" {
    const expected_rows = [_]usize{ 0, 7, 4, 3, 2, 5, 6, 1 };
    for (expected_rows, 0..) |expected, scan_index|
        try std.testing.expectEqual(expected, try circleScanRow(8, scan_index));

    var values = [_]QM31{ base(1), base(2), base(3), base(4), base(5), base(6), base(7), base(12) };
    const final_prefix = try scanLastColumnInPlace(&values, base(40));
    try std.testing.expect(QM31.eql(QM31.zero(), final_prefix));
    const expected = [_]u32{ m31_mod.Modulus - 4, 0, 0, 2, 3, 1, 3, 3 };
    for (values, expected) |actual, value|
        try std.testing.expect(QM31.eql(base(value), actual));
}

test "Cairo interaction reference rejects malformed geometry and words" {
    const source_words = [_]u32{1};
    const source = try LookupColumns.init(&source_words, 1);
    const alpha_powers = [_]QM31{base(2)};
    var descriptor = singleDescriptor(3, 0, 1, null, false);
    descriptor[1] = 1;
    try std.testing.expectError(
        Error.InvalidDescriptor,
        Reference.init(std.testing.allocator, &descriptor, source, base(5), &alpha_powers),
    );
    try std.testing.expectError(Error.InvalidRowCount, circleScanRow(3, 0));

    descriptor = singleDescriptor(3, 0, 1, 0, false);
    const bad_source_words = [_]u32{m31_mod.Modulus};
    const bad_source = try LookupColumns.init(&bad_source_words, 1);
    var reference = try Reference.init(std.testing.allocator, &descriptor, bad_source, base(5), &alpha_powers);
    defer reference.deinit();
    var cumulative: [1]QM31 = undefined;
    try std.testing.expectError(Error.NonCanonicalM31, reference.evaluateRow(0, &cumulative));
}

test "Cairo interaction reference accepts every generated lookup template" {
    const relation_bundle = @import("relation_bundle.zig");
    var bundle = try relation_bundle.Bundle.readFile(
        std.testing.allocator,
        "vectors/cairo/cairo_relation_templates.bin",
    );
    defer bundle.deinit();
    const alpha_powers = [_]QM31{base(1)} ** 128;
    var lookup_trace_count: usize = 0;
    for (bundle.components) |component| {
        for (component.traces) |trace| {
            if (trace.layout != .lookup_words) continue;
            const source_column_count = component.lookup_words orelse return error.MissingLookupGeometry;
            const source_words = try std.testing.allocator.alloc(u32, source_column_count);
            defer std.testing.allocator.free(source_words);
            @memset(source_words, 0);
            const source = try LookupColumns.init(source_words, 1);
            var reference = try Reference.init(
                std.testing.allocator,
                trace.descriptors,
                source,
                base(2),
                &alpha_powers,
            );
            reference.deinit();
            lookup_trace_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 64), lookup_trace_count);
}
