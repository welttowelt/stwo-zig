//! Compiled AIR registry and deferred adapter status.

pub fn write(writer: anytype) !void {
    try writer.writeAll(
        \\{"schema_version":1,"applications":[
        \\  {"air":"wide_fibonacci","status":"release_gated","backends":["cpu","metal-hybrid"]},
        \\  {"air":"xor","status":"release_gated","backends":["cpu","metal-hybrid"]},
        \\  {"air":"plonk","status":"release_gated","backends":["cpu","metal-hybrid"]},
        \\  {"air":"state_machine","status":"release_gated","backends":["cpu","metal-hybrid"]},
        \\  {"air":"blake","status":"release_gated","backends":["cpu","metal-hybrid"]},
        \\  {"air":"poseidon","status":"release_gated","backends":["cpu","metal-hybrid"]}
        \\],"deferred_adapters":[
        \\  {"adapter":"stark-v-rv32im-elf","status":"not_release_gated","reason":"RV32IM AIR and public I/O binding are incomplete"}
        \\]}
    );
}
