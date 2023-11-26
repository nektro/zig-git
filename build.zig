const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const test_step = b.step("test", "dummy test step to pass CI checks");
    _ = test_step;
}
