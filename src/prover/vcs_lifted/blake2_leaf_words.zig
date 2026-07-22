//! Direct four-lane Blake2s leaf hashing from canonical M31 words.

const std = @import("std");
const stwo_core = @import("stwo_core");

const blake2_backend = stwo_core.crypto.blake2s_backend;
const blake2_merkle = stwo_core.vcs_lifted.blake2_merkle;

/// The direct seeded path is valid only for the production domain-prefixed,
/// non-M31-output hasher. Other protocols retain their generic packed path.
pub fn supports(comptime H: type) bool {
    return H == blake2_merkle.Blake2sMerkleHasher;
}

pub fn hashLeafWordsWithSeed4(
    comptime H: type,
    seed: H.NodeSeed,
    word_count: usize,
    reader: anytype,
) [4]H.Hash {
    if (comptime !supports(H)) @compileError("unsupported direct leaf hasher");
    return blake2_backend.Blake2sHasher.hashEqualWordsFromSeed4WithMode(
        blake2_backend.getDefaultBackendMode(),
        seed,
        word_count,
        reader,
    );
}

pub fn hashColumnMajorLeavesWithSeed4(
    comptime H: type,
    seed: H.NodeSeed,
    columns: anytype,
    max_log_size: u32,
    position: usize,
) [4]H.Hash {
    if (comptime !supports(H)) @compileError("unsupported direct leaf hasher");
    const Reader = struct {
        columns: @TypeOf(columns),
        max_log_size: u32,
        position: usize,
        direct_equal_size: bool,

        pub inline fn readWord4(reader: @This(), word_index: usize) [4]u32 {
            const column = reader.columns[word_index];
            if (reader.direct_equal_size) {
                return .{
                    column.values[reader.position + 0].v,
                    column.values[reader.position + 1].v,
                    column.values[reader.position + 2].v,
                    column.values[reader.position + 3].v,
                };
            }
            const shift_amt: std.math.Log2Int(usize) =
                @intCast(reader.max_log_size - column.log_size + 1);
            var words: [4]u32 = undefined;
            inline for (0..4) |lane| {
                const leaf_position = reader.position + lane;
                const source_index = ((leaf_position >> shift_amt) << 1) +
                    (leaf_position & 1);
                words[lane] = column.values[source_index].v;
            }
            return words;
        }
    };

    var direct_equal_size = columns.len > 0;
    for (columns) |column| {
        direct_equal_size = direct_equal_size and column.log_size == max_log_size;
    }

    return hashLeafWordsWithSeed4(
        H,
        seed,
        columns.len,
        Reader{
            .columns = columns,
            .max_log_size = max_log_size,
            .position = position,
            .direct_equal_size = direct_equal_size,
        },
    );
}
