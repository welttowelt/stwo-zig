pub const ResidentStorage = struct {
    handle: *anyopaque,
    destroyFn: *const fn (*anyopaque) void,

    pub fn deinit(self: ResidentStorage) void {
        self.destroyFn(self.handle);
    }
};
