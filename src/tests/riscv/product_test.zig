//! Focused RISC-V product checks kept inside the normal package touchpoint.

test {
    _ = @import("unit_test.zig");
    _ = @import("proof_admission_test.zig");
    _ = @import("public_relation_binding_test.zig");
}
