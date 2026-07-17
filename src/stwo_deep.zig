const std = @import("std");
const stwo = @import("stwo.zig");

test {
    _ = @import("core/fri/tests.zig");
    _ = @import("core/fields/tests/m31.zig");
    _ = @import("core/pcs/quotients/tests.zig");
    _ = @import("integrations/cairo_metal/oods.zig");
    _ = @import("integrations/cairo_metal/schedule_bindings.zig");
    _ = @import("prover/tests/mod.zig");
    _ = @import("interop/parity/mod.zig");
    std.testing.refAllDecls(stwo);
    std.testing.refAllDeclsRecursive(stwo.core);
    std.testing.refAllDeclsRecursive(stwo.prover);
    std.testing.refAllDeclsRecursive(stwo.examples);
    std.testing.refAllDeclsRecursive(stwo.interop);
    std.testing.refAllDeclsRecursive(stwo.tracing);
}
