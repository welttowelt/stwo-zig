//! Host tool that binds canonical product identity to a built artifact.

const std = @import("std");
const product = @import("product_identity");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const arguments = try std.process.argsAlloc(allocator);
    if (arguments.len != 4) return error.InvalidArguments;
    const executable = if (std.mem.eql(u8, arguments[2], "executable"))
        true
    else if (std.mem.eql(u8, arguments[2], "library"))
        false
    else
        return error.InvalidArtifactKind;
    const artifact_digest = try digestFile(arguments[1]);
    const artifact_hex = std.fmt.bytesToHex(artifact_digest, .lower);

    var buffer: [16 * 1024]u8 = undefined;
    var output = std.fs.File.stdout().writer(&buffer);
    try std.json.Stringify.value(.{
        .schema = "stwo-product-artifact-identity-v1",
        .product_id = product.product,
        .identity_schema_version = product.schema_version,
        .product_identity_sha256 = product.identity_sha256,
        .artifact_sha256 = &artifact_hex,
        .artifact_path = arguments[3],
        .executable_sha256 = if (executable) @as(?[]const u8, &artifact_hex) else null,
        .frontend = product.frontend,
        .backend = product.backend,
        .role = product.role,
        .protocol_manifest = product.protocol_features,
        .protocol_manifest_sha256 = product.protocol_manifest_sha256,
        .implementation_repository = product.implementation_repository,
        .implementation_commit = product.implementation_commit,
        .implementation_tree = if (product.implementation_tree_available)
            product.implementation_tree
        else
            null,
        .implementation_dirty = product.implementation_dirty,
        .dirty_content_sha256 = if (product.dirty_content_sha256_available)
            product.dirty_content_sha256
        else
            null,
        .zig_version = product.zig_version,
        .target_arch = product.target_arch,
        .target_os = product.target_os,
        .target_abi = product.target_abi,
        .cpu_model = product.cpu_model,
        .cpu_features_sha256 = product.cpu_features_sha256,
        .optimize = product.optimize,
        .runtime_manifest = product.runtime_manifest,
        .sdk_manifest = product.sdk_manifest,
        .aot_manifest = product.aot_manifest,
    }, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

fn digestFile(path: []const u8) ![32]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try file.read(&buffer);
        if (count == 0) break;
        hasher.update(buffer[0..count]);
    }
    return hasher.finalResult();
}
