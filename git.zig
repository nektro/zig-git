const std = @import("std");
const string = []const u8;

// 40 is length of sha1 hash
pub const Id = *const [40]u8;
pub const TreeId = struct { id: Id };
pub const CommitId = struct { id: Id };
pub const BlobId = struct { id: Id };

/// Returns the result of running `git rev-parse HEAD`
/// dir must already be pointing at the .git folder
pub fn getHEAD(alloc: std.mem.Allocator, dir: std.fs.Dir) !Id {
    const h = std.mem.trimRight(u8, try dir.readFileAlloc(alloc, "HEAD", 1024), "\n");

    if (std.mem.startsWith(u8, h, "ref:")) {
        const r = blk: {
            const pckedrfs = dir.readFileAlloc(alloc, "packed-refs", 1024 * 1024) catch |err| switch (err) {
                error.FileNotFound => try std.fs.cwd().readFileAlloc(alloc, "/dev/null", 1024),
                else => |e| return e,
            };
            var iter = std.mem.split(u8, pckedrfs, "\n");
            while (iter.next()) |line| {
                if (std.mem.startsWith(u8, line, "#")) continue;
                if (std.mem.startsWith(u8, line, "^")) continue;
                if (line.len == 0) continue;
                var jter = std.mem.split(u8, line, " ");
                const objid = jter.next().?;
                const ref = jter.next().?;
                std.debug.assert(jter.next() == null);
                if (std.mem.eql(u8, h[5..], ref)) break :blk objid;
            }
            break :blk std.mem.trimRight(u8, try dir.readFileAlloc(alloc, h[5..], 1024), "\n");
        };
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
    return std.mem.trimRight(u8, result.stdout, "\n");
}

pub fn parseCommit(alloc: std.mem.Allocator, commitfile: string) !Commit {
    var iter = std.mem.split(u8, commitfile, "\n");
    var result: Commit = undefined;
    var parents = std.ArrayList(CommitId).init(alloc);
    errdefer parents.deinit();
    while (true) {
        const line = iter.next().?;
        if (line.len == 0) break;
        const space = std.mem.indexOfScalar(u8, line, ' ').?;
        const k = line[0..space];

        if (std.mem.eql(u8, k, "tree")) result.tree = .{ .id = line[space + 1 ..][0..40] };
        if (std.mem.eql(u8, k, "author")) result.author = line[space + 1 ..];
        if (std.mem.eql(u8, k, "committer")) result.committer = line[space + 1 ..];
        if (std.mem.eql(u8, k, "parent")) try parents.append(.{ .id = line[space + 1 ..][0..40] });
    }
    result.parents = try parents.toOwnedSlice();
    result.message = iter.rest();
    return result;
}

pub const Commit = struct {
    tree: TreeId,
    parents: []const CommitId,
    author: string,
    committer: string,
    gpgsig: string,
    message: string,
};

pub fn parseTree(alloc: std.mem.Allocator, treefile: string) !Tree {
    var iter = std.mem.split(u8, treefile, "\n");
    var children = std.ArrayList(Tree.Object).init(alloc);
    errdefer children.deinit();

    while (iter.next()) |line| {
        var jter = std.mem.split(u8, line, " ");
        const mode = try std.fmt.parseInt(u32, jter.next().?, 10);
        const otype = std.meta.stringToEnum(Tree.Object.Id.Tag, jter.next().?).?;
        const id_and_name = jter.next().?;
        std.debug.assert(jter.next() == null);
        const tab_pos = std.mem.indexOfScalar(u8, id_and_name, '\t').?; // why git. why.
        std.debug.assert(tab_pos == 40);
        const id = id_and_name[0..tab_pos][0..40];
        const name = id_and_name[tab_pos + 1 ..];

        inline for (std.meta.fields(Tree.Object.Id)) |item| {
            if (std.mem.eql(u8, item.name, @tagName(otype))) {
                try children.append(.{
                    .mode = mode,
                    .id = @unionInit(Tree.Object.Id, item.name, item.type{ .id = id }),
                    .name = name,
                });
            }
        }
    }
    return Tree{
        .children = try children.toOwnedSlice(),
    };
}

pub const Tree = struct {
    children: []const Object,

    pub fn get(self: Tree, name: string) ?Object {
        for (self.children) |item| {
            if (std.mem.eql(u8, item.name, name)) {
                return item;
            }
        }
        return null;
    }

    pub fn getBlob(self: Tree, name: string) ?Object {
        const o = self.get(name) orelse return null;
        if (o.id != .blob) return null;
        return o;
    }

    pub const Object = struct {
        mode: u32, // git allegedly only uses a specific set of these. should it be an enum?
        id: @This().Id,
        name: string,

        pub const Id = union(enum) {
            blob: BlobId,
            tree: TreeId,

            pub const Tag = std.meta.Tag(@This());
        };
    };
};
