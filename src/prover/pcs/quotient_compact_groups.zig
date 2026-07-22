//! Register-resident reduction of compact quotient contribution groups.

const std = @import("std");
const m31 = @import("stwo_core").fields.m31;
const qm31 = @import("stwo_core").fields.qm31;
const planning = @import("quotients/planning.zig");

const M31 = m31.M31;
const QM31 = qm31.QM31;

pub const Group = planning.CompactContributionGroup;
pub const Member = planning.CompactContributionMember;

fn numerator(
    numerators: []M31,
    row_capacity: usize,
    batch_count: usize,
    batch: usize,
    coordinate: usize,
    row: usize,
) *M31 {
    std.debug.assert(batch < batch_count);
    std.debug.assert(coordinate < qm31.SECURE_EXTENSION_DEGREE);
    std.debug.assert(row < row_capacity);
    const plane = batch * qm31.SECURE_EXTENSION_DEGREE + coordinate;
    return &numerators[plane * row_capacity + row];
}

/// Reduces all members sharing one `(sample batch, source geometry)` into an
/// even/odd compact pair, then broadcasts one exact packed group value across
/// the lifted run. Multiplications remain distributed across quotient workers;
/// output additions scale with groups instead of contributions.
pub fn accumulate(
    numerators: []M31,
    row_capacity: usize,
    batch_count: usize,
    group: Group,
    start: usize,
    row_count: usize,
) void {
    std.debug.assert(group.shift_amt >= 2);
    const end = start + row_count;
    var position = start;
    while (position < end) {
        const source_block = position >> group.shift_amt;
        const block_end = @min(end, (source_block + 1) << group.shift_amt);
        const source_index = source_block << 1;

        var sums: [qm31.SECURE_EXTENSION_DEGREE][2]M31 =
            @splat(@splat(M31.zero()));
        for (group.members) |member| {
            std.debug.assert(source_index + 1 < member.values.len);
            inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
                sums[coordinate][0] = sums[coordinate][0].add(
                    member.values[source_index].mul(member.coefficients[coordinate]),
                );
                sums[coordinate][1] = sums[coordinate][1].add(
                    member.values[source_index + 1].mul(member.coefficients[coordinate]),
                );
            }
        }

        var even_first: [qm31.SECURE_EXTENSION_DEGREE]m31.PackedM31 = undefined;
        var odd_first: [qm31.SECURE_EXTENSION_DEGREE]m31.PackedM31 = undefined;
        inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
            var even_lanes: [m31.PACK_WIDTH]u32 = undefined;
            var odd_lanes: [m31.PACK_WIDTH]u32 = undefined;
            inline for (0..m31.PACK_WIDTH) |lane| {
                even_lanes[lane] = sums[coordinate][lane & 1].v;
                odd_lanes[lane] = sums[coordinate][1 - (lane & 1)].v;
            }
            even_first[coordinate] = @bitCast(even_lanes);
            odd_first[coordinate] = @bitCast(odd_lanes);
        }

        while (block_end - position >= m31.PACK_WIDTH) : (position += m31.PACK_WIDTH) {
            const local_row = position - start;
            inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
                const plane = group.batch_index * qm31.SECURE_EXTENSION_DEGREE + coordinate;
                const values = numerators.ptr + plane * row_capacity + local_row;
                const addend = if ((position & 1) == 0)
                    even_first[coordinate]
                else
                    odd_first[coordinate];
                m31.storePacked(values, m31.addPacked(m31.loadPacked(values), addend));
            }
        }
        while (position < block_end) : (position += 1) {
            const parity = position & 1;
            inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
                const value = numerator(
                    numerators,
                    row_capacity,
                    batch_count,
                    group.batch_index,
                    coordinate,
                    position - start,
                );
                value.* = value.add(sums[coordinate][parity]);
            }
        }
    }
}

pub fn scalarValueAt(group: Group, position: usize) QM31 {
    const source_index = ((position >> group.shift_amt) << 1) + (position & 1);
    var combined = QM31.zero();
    for (group.members) |member| {
        combined = combined.add(QM31.fromM31(
            member.values[source_index].mul(member.coefficients[0]),
            member.values[source_index].mul(member.coefficients[1]),
            member.values[source_index].mul(member.coefficients[2]),
            member.values[source_index].mul(member.coefficients[3]),
        ));
    }
    return combined;
}

test "compact grouped lifting matches scalar member reduction" {
    const row_capacity: usize = 37;
    var numerators = [_]M31{M31.zero()} ** (2 * qm31.SECURE_EXTENSION_DEGREE * row_capacity);
    var values_a: [64]M31 = undefined;
    var values_b: [64]M31 = undefined;
    for (&values_a, 0..) |*value, index| value.* = M31.fromCanonical(@intCast(19 + index * 97));
    for (&values_b, 0..) |*value, index| value.* = M31.fromCanonical(@intCast(23 + index * 131));
    const members = [_]Member{
        .{ .values = &values_a, .coefficients = .{
            M31.fromCanonical(3), M31.fromCanonical(5),
            M31.fromCanonical(7), M31.fromCanonical(11),
        } },
        .{ .values = &values_b, .coefficients = .{
            M31.fromCanonical(13), M31.fromCanonical(17),
            M31.fromCanonical(19), M31.fromCanonical(23),
        } },
    };
    const Case = struct { shift: u6, start: usize, len: usize };
    for ([_]Case{
        .{ .shift = 2, .start = 0, .len = 37 },
        .{ .shift = 3, .start = 3, .len = 31 },
        .{ .shift = 8, .start = 5, .len = 29 },
    }) |case| {
        @memset(&numerators, M31.zero());
        accumulate(&numerators, row_capacity, 2, .{
            .members = &members,
            .batch_index = 1,
            .shift_amt = case.shift,
        }, case.start, case.len);
        for (0..case.len) |row| {
            const position = case.start + row;
            const source_index = ((position >> case.shift) << 1) + (position & 1);
            inline for (0..qm31.SECURE_EXTENSION_DEGREE) |coordinate| {
                const expected = values_a[source_index].mul(members[0].coefficients[coordinate]).add(
                    values_b[source_index].mul(members[1].coefficients[coordinate]),
                );
                const plane = qm31.SECURE_EXTENSION_DEGREE + coordinate;
                try std.testing.expectEqual(expected.v, numerators[plane * row_capacity + row].v);
            }
        }
    }
}
