const std = @import("std");
const arena = @import("backends/metal/arena_plan.zig");
const recovery = @import("backends/metal/recovery.zig");
const cairo_recovery = @import("frontends/cairo/witness/recovery.zig");
const protocol_recipes = @import("backends/metal/protocol_recipes.zig");
const witness_bundle = @import("frontends/cairo/witness/bundle.zig");
const feed_bundle = @import("frontends/cairo/witness/feed_bundle.zig");
const relation_bundle = @import("frontends/cairo/witness/relation_bundle.zig");
const fixed_table_bundle = @import("frontends/cairo/witness/fixed_table_bundle.zig");

test {
    std.testing.refAllDecls(recovery);
    std.testing.refAllDecls(cairo_recovery);
    std.testing.refAllDecls(protocol_recipes);
    std.testing.refAllDecls(witness_bundle);
    std.testing.refAllDecls(feed_bundle);
    std.testing.refAllDecls(relation_bundle);
    std.testing.refAllDecls(fixed_table_bundle);
}

test "sparse Metal plan enforces budget and aliases disjoint epochs" {
    const a = [_]arena.LiveRange{ .{ .first = 1, .last = 1 }, .{ .first = 8, .last = 8 } };
    const b = [_]arena.LiveRange{.{ .first = 4, .last = 5 }};
    const c = [_]arena.LiveRange{ .{ .first = 2, .last = 2 }, .{ .first = 7, .last = 7 } };
    const logical = [_]arena.LogicalBuffer{
        .{ .id = 1, .size_bytes = 4096, .alignment = 4096, .live_ranges = &a, .recompute_cost_ns = 10 },
        .{ .id = 2, .size_bytes = 4096, .alignment = 4096, .live_ranges = &b },
        .{ .id = 3, .size_bytes = 2048, .alignment = 4096, .live_ranges = &c, .spill_cost_ns = 20 },
    };
    var plan = try arena.build(std.testing.allocator, &logical, 16 * 1024);
    defer plan.deinit();
    try std.testing.expectEqual(@as(u64, 16 * 1024), plan.total_bytes);
    try std.testing.expectEqual(arena.Materialization.recompute, (try plan.binding(1)).materialization);
    try std.testing.expectEqual(arena.Materialization.spill, (try plan.binding(3)).materialization);
    try plan.validate(16 * 1024);
}

test "unrecoverable Metal values stay live between uses" {
    const a = [_]arena.LiveRange{ .{ .first = 1, .last = 1 }, .{ .first = 8, .last = 8 } };
    const b = [_]arena.LiveRange{.{ .first = 4, .last = 4 }};
    const logical = [_]arena.LogicalBuffer{
        .{ .id = 1, .size_bytes = 4096, .alignment = 4096, .live_ranges = &a },
        .{ .id = 2, .size_bytes = 4096, .alignment = 4096, .live_ranges = &b },
    };
    try std.testing.expectError(arena.Error.BudgetExceeded, arena.build(std.testing.allocator, &logical, 4096));
}

test "canonical SN PIE feeds bind every sparse arena column" {
    var bundle = try feed_bundle.Bundle.readFile(std.testing.allocator, "vectors/cairo/sn_pie_2_multiplicity_feeds.bin");
    defer bundle.deinit();
    const occupied = [_]u64{0} ** (arena.max_ticks / 64);
    var next_id: u32 = 1;
    var next_offset: u64 = 16 * 1024;

    for (bundle.feeds) |feed| {
        const sources = try std.testing.allocator.alloc(arena.Binding, feed.sub_words_per_row);
        defer std.testing.allocator.free(sources);
        for (sources) |*binding| {
            binding.* = .{
                .logical_id = next_id,
                .slot = next_id,
                .offset_bytes = next_offset,
                .size_bytes = @as(u64, feed.row_count) * 4,
                .materialization = .recompute,
                .occupied = occupied,
            };
            next_id += 1;
            next_offset += 16 * 1024 + binding.size_bytes;
        }

        const table_sizes = try std.testing.allocator.alloc(u32, feed.destinations.len);
        defer std.testing.allocator.free(table_sizes);
        @memset(table_sizes, 0);
        var descriptor_index: usize = 0;
        while (descriptor_index < feed.descriptors.len) : (descriptor_index += 14) {
            const e = feed.descriptors[descriptor_index .. descriptor_index + 14];
            if (table_sizes[e[10]] == 0) table_sizes[e[10]] = e[8] else try std.testing.expectEqual(table_sizes[e[10]], e[8]);
            if (e[11] == 1) {
                if (table_sizes[e[13]] == 0) table_sizes[e[13]] = e[12] else try std.testing.expectEqual(table_sizes[e[13]], e[12]);
            }
        }

        const destination_bindings = try std.testing.allocator.alloc([]arena.Binding, feed.destinations.len);
        defer {
            for (destination_bindings) |bindings| std.testing.allocator.free(bindings);
            std.testing.allocator.free(destination_bindings);
        }
        const destinations = try std.testing.allocator.alloc(protocol_recipes.DestinationColumns, feed.destinations.len);
        defer std.testing.allocator.free(destinations);
        for (feed.destinations, table_sizes, destination_bindings, destinations) |destination, table_size, *bindings, *layout| {
            try std.testing.expect(table_size > 0 and destination.words % table_size == 0);
            bindings.* = try std.testing.allocator.alloc(arena.Binding, @intCast(destination.words / table_size));
            for (bindings.*) |*binding| {
                binding.* = .{
                    .logical_id = next_id,
                    .slot = next_id,
                    .offset_bytes = next_offset,
                    .size_bytes = @as(u64, table_size) * 4,
                    .materialization = .recompute,
                    .occupied = occupied,
                };
                next_id += 1;
                next_offset += 16 * 1024 + binding.size_bytes;
            }
            layout.* = .{ .columns = bindings.* };
        }
        const lut_views = try std.testing.allocator.alloc([]const u32, feed.luts.len);
        defer std.testing.allocator.free(lut_views);
        for (feed.luts, lut_views) |lut, *view| view.* = lut;
        var bound = try protocol_recipes.BoundWitnessFeed.init(
            std.testing.allocator,
            sources,
            destinations,
            feed.descriptors,
            lut_views,
            feed.row_count,
        );
        bound.deinit();
    }
}
