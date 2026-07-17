const std = @import("std");
const recipe_requirements = @import("../../integrations/cairo_metal/recipe_requirements.zig");

test {
    std.testing.refAllDecls(recipe_requirements);
}
