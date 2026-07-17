const authority = @import("shaders/manifest.zig");

pub const core_shader_abi = authority.core_shader_abi;
pub const CompileProfile = authority.CompileProfile;
pub const compile_profile = authority.compile_profile;
pub const Unit = authority.Unit;
pub const Export = authority.Export;
pub const exports = authority.exports;
pub const amalgamated_source = authority.amalgamated_source;
pub const amalgamated_source_sha256 = authority.amalgamated_source_sha256;

test {
    _ = authority;
}
