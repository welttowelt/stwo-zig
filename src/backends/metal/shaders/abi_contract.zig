//! Native Metal kernel ABI authority derived from the shader declarations.

const std = @import("std");
const manifest = @import("manifest.zig");

pub const FunctionConstant = struct {
    index: u16,
    name: []const u8,
    msl_type: []const u8,
    specialization_value: []const u8,
};

pub const KernelAbi = struct {
    name: []const u8,
    owner: manifest.Unit,
    minimum_core_shader_abi: u32,
    declaration_sha256: []const u8,
    function_constants: []const FunctionConstant,
};

const empty_function_constants = [_]FunctionConstant{};

const declaration_digests: [manifest.native_exports.len][64]u8 = build: {
    @setEvalBranchQuota(10_000_000);
    var result: [manifest.native_exports.len][64]u8 = undefined;
    for (manifest.native_exports, 0..) |entry, index| {
        const declaration = kernelDeclaration(manifest.native_amalgamated_source, entry.name) catch
            @compileError("Native Metal export has no kernel declaration");
        result[index] = std.fmt.bytesToHex(canonicalDeclarationDigest(declaration), .lower);
    }
    break :build result;
};

/// Ordered ABI table serialized into the authenticated core-library manifest.
/// There are currently no Native function constants; each empty inventory is
/// intentional and makes adding a specialization an explicit ABI change.
pub const native_kernel_abi: [manifest.native_exports.len]KernelAbi = build: {
    var result: [manifest.native_exports.len]KernelAbi = undefined;
    for (manifest.native_exports, 0..) |entry, index| {
        result[index] = .{
            .name = entry.name,
            .owner = entry.owner,
            .minimum_core_shader_abi = manifest.core_shader_abi,
            .declaration_sha256 = declaration_digests[index][0..],
            .function_constants = empty_function_constants[0..],
        };
    }
    break :build result;
};

fn kernelDeclaration(source: []const u8, name: []const u8) ![]const u8 {
    var prefix_buffer: [192]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buffer, "kernel void {s}(", .{name});
    const start = std.mem.indexOf(u8, source, prefix) orelse return error.MissingKernelDeclaration;
    const end = std.mem.indexOfPos(u8, source, start + prefix.len, ") {") orelse
        return error.MalformedKernelDeclaration;
    return source[start .. end + 1];
}

fn canonicalDeclarationDigest(declaration: []const u8) [32]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var pending_space = false;
    var previous: ?u8 = null;
    for (declaration) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = true;
            continue;
        }
        if (pending_space and previous != null and tokenByte(previous.?) and tokenByte(byte))
            digest.update(" ");
        digest.update(&.{byte});
        pending_space = false;
        previous = byte;
    }
    return digest.finalResult();
}

fn tokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "every Native export has exactly one ordered ABI entry" {
    try std.testing.expectEqual(manifest.native_exports.len, native_kernel_abi.len);
    for (manifest.native_exports, native_kernel_abi, 0..) |entry, abi, index| {
        try std.testing.expectEqualStrings(entry.name, abi.name);
        try std.testing.expectEqual(entry.owner, abi.owner);
        try std.testing.expectEqual(manifest.core_shader_abi, abi.minimum_core_shader_abi);
        try std.testing.expectEqual(@as(usize, 64), abi.declaration_sha256.len);
        try std.testing.expectEqual(@as(usize, 0), abi.function_constants.len);
        for (native_kernel_abi[index + 1 ..]) |other|
            try std.testing.expect(!std.mem.eql(u8, abi.name, other.name));
    }
}

test "function-constant authority is explicitly empty" {
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, manifest.native_amalgamated_source, "function_constant"),
    );
    for (native_kernel_abi) |abi|
        try std.testing.expectEqual(@as(usize, 0), abi.function_constants.len);
}

test "canonical declaration digests ignore formatting but bind ABI tokens" {
    const compact = "kernel void example(device uint*value[[buffer(0)]],uint i[[thread_position_in_grid]])";
    const formatted =
        \\kernel void example(
        \\    device uint *value [[buffer(0)]],
        \\    uint i [[thread_position_in_grid]]
        \\)
    ;
    try std.testing.expectEqualSlices(
        u8,
        &canonicalDeclarationDigest(compact),
        &canonicalDeclarationDigest(formatted),
    );

    const changed = "kernel void example(device uint*value[[buffer(1)]],uint i[[thread_position_in_grid]])";
    try std.testing.expect(!std.mem.eql(
        u8,
        &canonicalDeclarationDigest(compact),
        &canonicalDeclarationDigest(changed),
    ));
}
