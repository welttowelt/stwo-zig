const eval_program = @import("../../frontends/cairo/witness/eval_program.zig");
const eval_codegen = @import("../../integrations/cairo_metal/eval_codegen.zig");
const composition_bundle = @import("../../frontends/cairo/witness/composition_bundle.zig");

test {
    _ = eval_program;
    _ = eval_codegen;
    _ = composition_bundle;
}
