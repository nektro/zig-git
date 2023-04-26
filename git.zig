const std = @import("std");
const string = []const u8;

// 40 is length of sha1 hash
pub const Id = *const [40]u8;

/// Returns the result of running `git rev-parse HEAD`
/// dir must already be pointing at the .git folder
pub fn getHEAD(alloc: std.mem.Allocator, dir: std.fs.Dir) !Id {
    const h = std.mem.trimRight(u8, try dir.readFileAlloc(alloc, "HEAD", 1024), "\n");

    if (std.mem.startsWith(u8, h, "ref:")) {
        const r = std.mem.trimRight(u8, try dir.readFileAlloc(alloc, h[5..], 1024), "\n");
        std.debug.assert(r.len == 40);
        return r[0..40];
    }

    // content should be 40-char sha1 hash
    std.debug.assert(h.len == 40);
    return h[0..40];
}

// TODO make this inspect .git/objects
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn getObject(alloc: std.mem.Allocator, dir: std.fs.Dir, obj: Id) !string {
    const result = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .cwd_dir = dir,
        .argv = &.{ "git", "cat-file", "-p", obj },
    });
    return result.stdout;
}

pub fn parseCommit(alloc: std.mem.Allocator, commitfile: string) !Commit {
    var iter = std.mem.split(u8, commitfile, "\n");
    var result: Commit = undefined;
    var parents = std.ArrayList(Id).init(alloc);
    errdefer parents.deinit();
    while (true) {
        const line = iter.next().?;
        if (line.len == 0) break;
        const space = std.mem.indexOfScalar(u8, line, ' ').?;
        const k = line[0..space];

        if (std.mem.eql(u8, k, "tree")) result.tree = line[space + 1 ..][0..40];
        if (std.mem.eql(u8, k, "author")) result.author = line[space + 1 ..];
        if (std.mem.eql(u8, k, "committer")) result.committer = line[space + 1 ..];
        if (std.mem.eql(u8, k, "parent")) try parents.append(line[space + 1 ..][0..40]);
    }
    result.parents = try parents.toOwnedSlice();
    result.message = iter.rest();
    return result;
}

pub const Commit = struct {
    tree: Id,
    parents: []const Id,
    author: string,
    committer: string,
    gpgsig: string,
    message: string,
};
