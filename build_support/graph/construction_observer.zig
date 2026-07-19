//! Derives the configured build closure from Zig's constructed step graph.

const std = @import("std");

pub const Snapshot = struct {
    module_roots: []const []const u8,
    external_tools: []const []const u8,
    runtime_probes: []const []const u8,
};

pub fn observe(b: *std.Build) Snapshot {
    var observer = Observer.init(b);
    var top_levels = b.top_level_steps.iterator();
    while (top_levels.next()) |entry| observer.visitStep(&entry.value_ptr.*.step);
    return .{
        .module_roots = observer.sortedKeys(&observer.module_roots),
        .external_tools = observer.sortedKeys(&observer.external_tools),
        .runtime_probes = observer.sortedKeys(&observer.runtime_probes),
    };
}

const Observer = struct {
    b: *std.Build,
    visited_steps: std.AutoHashMap(*std.Build.Step, void),
    visited_modules: std.AutoHashMap(*std.Build.Module, void),
    module_roots: std.StringHashMap(void),
    external_tools: std.StringHashMap(void),
    runtime_probes: std.StringHashMap(void),

    fn init(b: *std.Build) Observer {
        return .{
            .b = b,
            .visited_steps = std.AutoHashMap(*std.Build.Step, void).init(b.allocator),
            .visited_modules = std.AutoHashMap(*std.Build.Module, void).init(b.allocator),
            .module_roots = std.StringHashMap(void).init(b.allocator),
            .external_tools = std.StringHashMap(void).init(b.allocator),
            .runtime_probes = std.StringHashMap(void).init(b.allocator),
        };
    }

    fn visitStep(self: *Observer, step: *std.Build.Step) void {
        const entry = self.visited_steps.getOrPut(step) catch @panic("out of memory");
        if (entry.found_existing) return;
        switch (step.id) {
            .compile => {
                const compile: *std.Build.Step.Compile = @fieldParentPtr("step", step);
                self.visitModule(compile.root_module);
            },
            .run => {
                const run: *std.Build.Step.Run = @fieldParentPtr("step", step);
                if (run.producer == null and run.argv.items.len != 0) switch (run.argv.items[0]) {
                    .bytes => |command| self.put(&self.external_tools, std.fs.path.basename(command)),
                    else => {},
                };
            },
            else => {},
        }
        for (step.dependencies.items) |dependency| self.visitStep(dependency);
    }

    fn visitModule(self: *Observer, module: *std.Build.Module) void {
        const entry = self.visited_modules.getOrPut(module) catch @panic("out of memory");
        if (entry.found_existing) return;
        if (module.root_source_file) |root| self.putPath(&self.module_roots, root);
        var frameworks = module.frameworks.iterator();
        while (frameworks.next()) |framework| self.put(
            &self.runtime_probes,
            self.b.fmt("{s}.framework", .{framework.key_ptr.*}),
        );
        for (module.link_objects.items) |link| switch (link) {
            .system_lib => |library| self.put(
                &self.runtime_probes,
                if (std.mem.eql(u8, library.name, "objc")) "libobjc" else library.name,
            ),
            .c_source_file => |source| self.putPath(&self.module_roots, source.file),
            .c_source_files => |sources| for (sources.files) |path| self.put(
                &self.module_roots,
                self.b.pathJoin(&.{ sources.root.getDisplayName(), path }),
            ),
            else => {},
        };
        var imports = module.import_table.iterator();
        while (imports.next()) |item| self.visitModule(item.value_ptr.*);
    }

    fn put(_: *Observer, map: *std.StringHashMap(void), value: []const u8) void {
        map.put(value, {}) catch @panic("out of memory");
    }

    fn putPath(self: *Observer, map: *std.StringHashMap(void), path: std.Build.LazyPath) void {
        switch (path) {
            .src_path => |source| self.put(map, source.sub_path),
            .cwd_relative => |source| self.put(map, source),
            .generated, .dependency => {},
        }
    }

    fn sortedKeys(self: *Observer, map: *std.StringHashMap(void)) []const []const u8 {
        const result = self.b.allocator.alloc([]const u8, map.count()) catch @panic("out of memory");
        var iterator = map.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |key| : (index += 1) result[index] = key.*;
        std.mem.sort([]const u8, result, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.lessThan);
        return result;
    }
};
