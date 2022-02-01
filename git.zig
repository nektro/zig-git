const std = @import("std");
const string = []const u8;

/// Returns the result of running `git rev-parse HEAD`
pub fn getHEAD(alloc: std.mem.Allocator, dir: std.fs.Dir) !string {
    var dirg = try dir.openDir(".git", .{});
    defer dirg.close();
    const h = std.mem.trimRight(u8, try dirg.readFileAlloc(alloc, "HEAD", 1024), "\n");
    const r = std.mem.trimRight(u8, try dirg.readFileAlloc(alloc, h[5..], 1024), "\n");
    return r;
}
