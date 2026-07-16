const std = @import("std");
const statement_bootstrap = @import("frontends/cairo/statement_bootstrap.zig");

test {
    std.testing.refAllDecls(statement_bootstrap);
}
