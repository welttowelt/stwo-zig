const std = @import("std");
const prover = @import("../../frontends/cairo/prover.zig");
const semantic_pack = @import("../../frontends/cairo/witness/semantic_pack.zig");

test {
    std.testing.refAllDecls(prover);
    std.testing.refAllDecls(semantic_pack);
}
