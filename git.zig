const std = @import("std");
const string = []const u8;
const top = @This();
const time = @import("time");
const extras = @import("extras");
const tracer = @import("tracer");
const nfs = @import("nfs");

// 40 is length of sha1 hash
pub const Id = *const [40]u8;

pub const TreeId = struct {
    id: Id,

    pub fn eql(self: TreeId, other: TreeId) bool {
        return std.mem.eql(u8, self.id, other.id);
    }
};

pub const CommitId = struct {
    id: Id,

    pub fn eql(self: CommitId, other: CommitId) bool {
        return std.mem.eql(u8, self.id, other.id);
    }
};

pub const BlobId = struct {
    id: Id,

    pub fn eql(self: BlobId, other: BlobId) bool {
        return std.mem.eql(u8, self.id, other.id);
    }
};

pub const TagId = struct {
    id: Id,

    pub fn eql(self: TagId, other: TagId) bool {
        return std.mem.eql(u8, self.id, other.id);
    }
};

pub fn version(alloc: std.mem.Allocator) !string {
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "git", "--version" },
        .max_output_bytes = 1024,
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    std.debug.assert(result.term == .Exited and result.term.Exited == 0);
    return try alloc.dupe(u8, extras.trimPrefixEnsure(std.mem.trimRight(u8, result.stdout, "\n"), "git version ").?);
}

/// Returns the result of running `git rev-parse HEAD`
/// dir must already be pointing at the .git folder
// TODO this doesnt handle when there are 0 commits
pub fn getHEAD(alloc: std.mem.Allocator, dir: nfs.Dir) !?CommitId {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    const h = std.mem.trimRight(u8, try dir.readFileAlloc(alloc, "HEAD", 1024), "\n");

    if (std.mem.startsWith(u8, h, "ref:")) {
        blk: {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            @memcpy((&buf).ptr, h[5..]);
            buf[h[5..].len] = 0;
            const reffile = dir.readFileAlloc(alloc, buf[0..h[5..].len :0], 1024) catch |err| switch (err) {
                error.FileNotFound => break :blk,
                else => |e| return e,
            };
            return ensureObjId(CommitId, std.mem.trimRight(u8, reffile, "\n"));
        }
        blk: {
            const pckedrfs = dir.readFileAlloc(alloc, "packed-refs", 1024 * 1024 * 1024) catch |err| switch (err) {
                error.FileNotFound => break :blk,
                else => |e| return e,
            };
            var iter = std.mem.splitScalar(u8, pckedrfs, '\n');
            while (iter.next()) |line| {
                if (std.mem.startsWith(u8, line, "#")) continue;
                if (std.mem.startsWith(u8, line, "^")) continue;
                if (line.len == 0) continue;
                var jter = std.mem.splitScalar(u8, line, ' ');
                const objid = jter.next().?;
                const ref = jter.next().?;
                std.debug.assert(jter.next() == null);
                if (std.mem.eql(u8, h[5..], ref)) return ensureObjId(CommitId, objid);
            }
        }
        return null;
    }

    return ensureObjId(CommitId, h);
}

fn ensureObjId(comptime T: type, input: string) T {
    extras.assertLog(input.len == 40, "ensureObjId: {s}", .{input});
    return .{ .id = input[0..40] };
}

// TODO make this inspect .git/objects
// TODO make this return a Reader when we implement it ourselves
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn getObject(alloc: std.mem.Allocator, dir: nfs.Dir, obj: Id) !string {
    const t = tracer.trace(@src(), " {s}", .{obj});
    defer t.end();

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "cat-file", "-p", obj },
        .max_output_bytes = 1024 * 1024 * 1024,
    });
    extras.assertLog(result.term == .Exited and result.term.Exited == 0, "{s}", .{result.stderr});
    return result.stdout;
}

// TODO make this inspect .git/objects manually
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn getObjectSize(alloc: std.mem.Allocator, dir: nfs.Dir, obj: Id) !u64 {
    const t = tracer.trace(@src(), " {s}", .{obj});
    defer t.end();

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "cat-file", "-s", obj },
    });
    extras.assertLog(result.term == .Exited and result.term.Exited == 0, "{s}", .{result.stderr});
    return try std.fmt.parseInt(u64, std.mem.trimRight(u8, result.stdout, "\n"), 10);
}

// TODO make this inspect .git manually
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn isType(alloc: std.mem.Allocator, dir: nfs.Dir, maybeobj: Id, typ: Tree.Object.Id.Tag) !bool {
    const t = tracer.trace(@src(), " {s} = {s} ?", .{ maybeobj, @tagName(typ) });
    defer t.end();

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "cat-file", "-t", maybeobj },
    });
    std.debug.assert(result.term == .Exited and result.term.Exited == 0);
    const output = std.mem.trimRight(u8, result.stdout, "\n");
    return std.meta.stringToEnum(Tree.Object.Id.Tag, output).? == typ;
}

// TODO make this inspect .git manually
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn getType(alloc: std.mem.Allocator, dir: nfs.Dir, obj: Id) !Tree.Object.Id.Tag {
    const t = tracer.trace(@src(), " {s}", .{obj});
    defer t.end();

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "cat-file", "-t", obj },
    });
    std.debug.assert(result.term == .Exited and result.term.Exited == 0);
    const output = std.mem.trimRight(u8, result.stdout, "\n");
    return std.meta.stringToEnum(Tree.Object.Id.Tag, output) orelse @panic(output);
}

// TODO make this inspect .git/objects manually
// TODO make a version of this that accepts an array of sub_paths and searches all of them at once, so as to not lose spot in history when searching for many old paths
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn revList(alloc: std.mem.Allocator, dir: nfs.Dir, comptime count: u31, from: CommitId, sub_path: string) !string {
    const t = tracer.trace(@src(), "({d}) {s} -- {s}", .{ count, from.id, sub_path });
    defer t.end();

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{
            "git",
            "rev-list",
            "-" ++ std.fmt.comptimePrint("{d}", .{count}),
            from.id,
            "--",
            sub_path,
        },
    });
    std.debug.assert(result.term == .Exited and result.term.Exited == 0);
    return std.mem.trimRight(u8, result.stdout, "\n");
}

pub fn parseCommit(alloc: std.mem.Allocator, commitfile: string) !Commit {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var iter = std.mem.splitScalar(u8, commitfile, '\n');
    var result: Commit = undefined;
    var parents = std.ArrayList(CommitId).init(alloc);
    errdefer parents.deinit();
    while (true) {
        const line = iter.next() orelse break;
        if (line.len == 0) break;
        const space = std.mem.indexOfScalar(u8, line, ' ').?;
        const k = line[0..space];

        if (std.mem.eql(u8, k, "tree")) result.tree = .{ .id = line[space + 1 ..][0..40] };
        if (std.mem.eql(u8, k, "author")) result.author = try parseCommitUserAndAt(line[space + 1 ..]);
        if (std.mem.eql(u8, k, "committer")) result.committer = try parseCommitUserAndAt(line[space + 1 ..]);
        if (std.mem.eql(u8, k, "parent")) try parents.append(.{ .id = line[space + 1 ..][0..40] });
    }
    result.parents = try parents.toOwnedSlice();
    result.message = iter.rest();
    return result;
}

fn parseCommitUserAndAt(input: string) !UserAndAt {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    // Mitchell Hashimoto <mitchell.hashimoto@gmail.com> 1680797363 -0700
    // first and second part is https://datatracker.ietf.org/doc/html/rfc5322#section-3.4
    // third part is unix epoch timestamp
    // fourth part is TZ
    var maybe_bad_parser = std.mem.splitBackwardsScalar(u8, input, ' ');
    const tz_part = maybe_bad_parser.next() orelse return error.BadCommitTz;
    const time_part = maybe_bad_parser.next() orelse return error.BadCommitTime;
    const email_part = maybe_bad_parser.next() orelse return error.BadCommitEmail;
    const name_part = maybe_bad_parser.rest();
    std.debug.assert(email_part[0] == '<');
    std.debug.assert(email_part[email_part.len - 1] == '>');
    const name = name_part;
    const email = std.mem.trim(u8, email_part, "<>");
    const at = parseAt(time_part, tz_part);

    return .{
        .name = name,
        .email = email,
        .at = at,
    };
}

fn parseAt(time_part: string, tz_part: string) time.DateTime {
    var at = time.DateTime.initUnix(std.fmt.parseInt(u64, time_part, 10) catch unreachable);
    std.debug.assert(tz_part.len == 5);
    std.debug.assert(tz_part[0] == '-' or tz_part[0] == '+');
    const sign: i8 = if (tz_part[0] == '+') 1 else -1;
    const hrs = std.fmt.parseInt(u8, tz_part[1..][0..2], 10) catch unreachable;
    const mins = std.fmt.parseInt(u8, tz_part[3..][0..2], 10) catch unreachable;
    if (sign > 0) at = at.addHours(hrs);
    if (sign > 0) at = at.addMins(mins);
    // if (sign < 0) at = at.subHours(hrs); // TODO:
    // if (sign < 0) at = at.subMins(mins); // TODO:
    return at;
}

pub const Commit = struct {
    tree: TreeId,
    parents: []const CommitId,
    author: UserAndAt,
    committer: UserAndAt,
    message: string,
};

pub const UserAndAt = struct {
    name: string,
    email: string,
    at: time.DateTime,
};

pub fn parseTree(alloc: std.mem.Allocator, treefile: string) !Tree {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var iter = std.mem.splitScalar(u8, treefile, '\n');
    var children = std.ArrayList(Tree.Object).init(alloc);
    errdefer children.deinit();

    while (iter.next()) |line| {
        if (line.len == 0) {
            std.debug.assert(iter.peek() == null);
            break;
        }
        var jter = std.mem.splitScalar(u8, line, ' ');
        const mode = jter.next().?;
        const otype = std.meta.stringToEnum(Tree.Object.Id.Tag, jter.next().?).?;
        const id_and_name = jter.rest();
        const tab_pos = std.mem.indexOfScalar(u8, id_and_name, '\t').?; // why git. why.
        std.debug.assert(tab_pos == 40);
        const id = id_and_name[0..tab_pos][0..40];
        const name = id_and_name[tab_pos + 1 ..];

        inline for (std.meta.fields(Tree.Object.Id)) |item| {
            if (std.mem.eql(u8, item.name, @tagName(otype))) {
                try children.append(.{
                    .mode = try parseTreeMode(mode),
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

fn parseTreeMode(input: string) !Tree.Object.Mode {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    std.debug.assert(input.len == 6);
    return .{
        .type = @enumFromInt(try std.fmt.parseInt(u16, input[0..3], 10)),
        .perm_user = @bitCast(try std.fmt.parseInt(u3, input[3..][0..1], 8)),
        .perm_group = @bitCast(try std.fmt.parseInt(u3, input[4..][0..1], 8)),
        .perm_other = @bitCast(try std.fmt.parseInt(u3, input[5..][0..1], 8)),
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
        mode: Mode,
        id: @This().Id,
        name: string,

        pub const Id = union(enum) {
            blob: BlobId,
            tree: TreeId,
            commit: CommitId,
            tag: TagId,

            pub const Tag = std.meta.Tag(@This());

            pub fn erase(self: @This()) top.Id {
                return switch (self) {
                    inline else => |v| v.id,
                };
            }
        };

        pub const Mode = struct {
            type: Type,
            perm_user: Perm,
            perm_group: Perm,
            perm_other: Perm,

            pub fn format(self: Mode, comptime fmt: string, options: std.fmt.FormatOptions, writer: anytype) !void {
                _ = fmt;
                _ = options;

                try writer.print("{}", .{self.type});
                try writer.print("{}", .{self.perm_user});
                try writer.print("{}", .{self.perm_group});
                try writer.print("{}", .{self.perm_other});
            }
        };

        pub const Type = enum(u16) {
            file = 100,
            directory = 40,
            submodule = 160,
            symlink = 120,
            none = 0,

            pub fn format(self: Type, comptime fmt: string, options: std.fmt.FormatOptions, writer: anytype) !void {
                _ = fmt;
                _ = options;

                try writer.writeByte(switch (self) {
                    .file => '-',
                    .directory => 'd',
                    .submodule => 'm',
                    .symlink => '-',
                    .none => '-',
                });
            }
        };

        pub const Perm = packed struct(u3) {
            execute: bool,
            write: bool,
            read: bool,

            pub fn format(self: Perm, comptime fmt: string, options: std.fmt.FormatOptions, writer: anytype) !void {
                _ = fmt;
                _ = options;

                try writer.writeByte(if (self.read) 'r' else '-');
                try writer.writeByte(if (self.write) 'w' else '-');
                try writer.writeByte(if (self.execute) 'x' else '-');
            }
        };
    };
};

// TODO make this inspect .git manually
// TODO make this return a Reader when we implement it ourselves
pub fn getTreeDiff(alloc: std.mem.Allocator, dir: nfs.Dir, commitid: CommitId, parentid: ?CommitId) !string {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    if (parentid == null) {
        const result = try std.process.Child.run(.{
            .allocator = alloc,
            .cwd_dir = dir.to_std(),
            // 4b825dc642cb6eb9a060e54bf8d69288fbee4904 is a hardcode for the empty tree in git sha1
            // result of `printf | git hash-object -t tree --stdin`
            .argv = &.{ "git", "diff-tree", "-p", "--raw", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", commitid.id },
            .max_output_bytes = 1024 * 1024 * 1024,
        });
        std.debug.assert(result.term == .Exited and result.term.Exited == 0);
        return std.mem.trim(u8, result.stdout, "\n");
    }
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "diff-tree", "-p", "--raw", parentid.?.id, commitid.id },
        .max_output_bytes = 1024 * 1024 * 1024,
    });
    std.debug.assert(result.term == .Exited and result.term.Exited == 0);
    return std.mem.trim(u8, result.stdout, "\n");
}

pub fn parseTreeDiffMeta(input: string) !TreeDiffMeta {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var result = std.mem.zeroes(TreeDiffMeta);
    var lineiter = std.mem.splitScalar(u8, input, '\n');

    while (lineiter.next()) |lin| {
        if (lin.len == 0) break;
        std.debug.assert(lin[0] == ':');
        result.files_changed += 1;
    }

    std.debug.assert(std.mem.startsWith(u8, lineiter.next() orelse return result, "diff --git"));
    blk: while (true) {
        while (lineiter.next()) |lin| {
            if (std.mem.startsWith(u8, lin, "index")) break;
            if (std.mem.startsWith(u8, lin, "new file mode")) continue;
            if (std.mem.startsWith(u8, lin, "deleted file mode")) continue;
            if (std.mem.startsWith(u8, lin, "old mode")) continue;
            if (std.mem.startsWith(u8, lin, "new mode")) continue;
            if (std.mem.startsWith(u8, lin, "diff --git")) continue :blk;

            std.log.err("{s}", .{lin});
            unreachable;
        }
        if (lineiter.peek() == null) break; // handle empty file being last or being at the end

        if (std.mem.startsWith(u8, lineiter.peek().?, "Binary files")) {
            _ = lineiter.next().?;
            result.lines_added += 1;
            result.lines_removed += 1;
            if (lineiter.peek() == null) break; // handle binary file being last
            std.debug.assert(std.mem.startsWith(u8, lineiter.next().?, "diff --git"));
            continue;
        }

        if (std.mem.startsWith(u8, lineiter.peek().?, "diff --git")) { // handle empty file being in the middle
            std.debug.assert(std.mem.startsWith(u8, lineiter.next().?, "diff --git"));
            continue;
        }

        // Every affected text file in the diff has a preamble like below
        //
        // diff --git a/notes/all_packages.txt b/notes/all_packages.txt
        // index c06b41d..e8f91cf 100644
        // --- a/notes/all_packages.txt
        // +++ b/notes/all_packages.txt
        std.debug.assert(std.mem.startsWith(u8, lineiter.next().?, "---"));
        std.debug.assert(std.mem.startsWith(u8, lineiter.next().?, "+++"));

        while (lineiter.next()) |lin| {
            if (std.mem.startsWith(u8, lin, "diff --git")) break;
            switch (lin[0]) {
                '@' => continue, // @@ -89,3 +89,4 @@ freedesktop/xorg/libsm
                ' ' => continue,
                '+' => result.lines_added += 1,
                '-' => result.lines_removed += 1,
                '\\' => continue, // \ No newline at end of file
                else => @panic(lin),
            }
        }
        if (lineiter.peek() == null) break; // handle being at the end
    }

    return result;
}

pub const TreeDiffMeta = struct {
    files_changed: u16,
    lines_added: u32,
    lines_removed: u32,
};

pub fn parseTreeDiff(alloc: std.mem.Allocator, input: string) !TreeDiff {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var lineiter = std.mem.splitScalar(u8, input, '\n');
    var overview = std.ArrayList(TreeDiff.StateLine).init(alloc);
    var diffs = std.ArrayList(TreeDiff.Diff).init(alloc);

    while (lineiter.next()) |lin| {
        if (lin.len == 0) break;
        std.debug.assert(lin[0] == ':');

        // :100644 100644 c06b41d04c381f1841d445c0072219d9a7f57e17 e8f91cf7dd413ac65a362b0a170951033dba4762 M     notes/all_packages.txt
        var jter = std.mem.tokenizeScalar(u8, lin[1..], ' ');
        const before_mode = try parseTreeMode(jter.next().?);
        const after_mode = try parseTreeMode(jter.next().?);

        const before_tree = ensureObjId(BlobId, jter.next().?);
        const after_tree = ensureObjId(BlobId, jter.next().?);

        var kter = std.mem.splitScalar(u8, jter.next().?, '\t'); // why is there a tab here git. why?
        const action_s = kter.next().?;

        try overview.append(.{
            .before = .{
                .mode = before_mode,
                .blob = before_tree,
            },
            .after = .{
                .mode = after_mode,
                .blob = after_tree,
            },
            .action = std.meta.stringToEnum(TreeDiff.Action, action_s).?,
            .sub_path = kter.rest(),
            .adds = 0,
            .subs = 0,
        });
    }

    // diff --git a/notes/all_packages.txt b/notes/all_packages.txt
    // index c06b41d..e8f91cf 100644
    // --- a/notes/all_packages.txt
    // +++ b/notes/all_packages.txt
    // @@ -89,3 +89,4 @@ freedesktop/xorg/libsm
    //  freedesktop/xorg/libxt
    //  freedesktop/xorg/libxmu
    //  ncompress
    // +freedesktop/xorg/libxpm
    std.debug.assert(std.mem.startsWith(u8, lineiter.next() orelse return std.mem.zeroes(TreeDiff), "diff --git"));
    blk: while (true) {
        while (lineiter.next()) |lin| {
            if (std.mem.startsWith(u8, lin, "index")) break;
            if (std.mem.startsWith(u8, lin, "new file mode")) continue;
            if (std.mem.startsWith(u8, lin, "deleted file mode")) continue;
            if (std.mem.startsWith(u8, lin, "old mode")) continue;
            if (std.mem.startsWith(u8, lin, "new mode")) continue;

            std.log.err("{s}", .{lin});
            unreachable;
        }

        const before_path_raw = lineiter.next() orelse {
            // empty file diff has nothing after 'index' line and this branch handles when its the last item
            try diffs.append(.{
                .before_path = overview.items[diffs.items.len].sub_path,
                .after_path = overview.items[diffs.items.len].sub_path,
                .content = "",
            });
            break;
        };
        if (std.mem.startsWith(u8, before_path_raw, "Binary files")) {
            try diffs.append(.{
                .before_path = overview.items[diffs.items.len].sub_path,
                .after_path = overview.items[diffs.items.len].sub_path,
                .content = before_path_raw,
            });
            _ = lineiter.index orelse break :blk;
            std.debug.assert(std.mem.startsWith(u8, lineiter.next().?, "diff --git"));
            continue :blk;
        }
        if (std.mem.startsWith(u8, before_path_raw, "diff --git")) {
            // empty file in the middle, no diff
            try diffs.append(.{
                .before_path = overview.items[diffs.items.len].sub_path,
                .after_path = overview.items[diffs.items.len].sub_path,
                .content = "",
            });
            continue :blk;
        }
        const before_path = extras.trimPrefixEnsure(before_path_raw, "--- a/") orelse extras.trimPrefixEnsure(before_path_raw, "--- ") orelse @panic(before_path_raw);

        const after_path_raw = lineiter.next().?;
        const after_path = extras.trimPrefixEnsure(after_path_raw, "+++ b/") orelse extras.trimPrefixEnsure(after_path_raw, "+++ ") orelse @panic(after_path_raw);

        const start_index = lineiter.index.?;

        while (lineiter.next()) |lin| {
            if (std.mem.startsWith(u8, lin, "diff --git")) {
                const end_index = lineiter.index.? - lin.len - 2;
                const content = input[start_index..end_index];
                overview.items[diffs.items.len].adds = @intCast(std.mem.count(u8, content, "\n+"));
                overview.items[diffs.items.len].subs = @intCast(std.mem.count(u8, content, "\n-"));
                try diffs.append(.{
                    .before_path = before_path,
                    .after_path = after_path,
                    .content = content,
                });
                continue :blk;
            }
        }
        const content = input[start_index..];
        overview.items[diffs.items.len].adds = @intCast(std.mem.count(u8, content, "\n+"));
        overview.items[diffs.items.len].subs = @intCast(std.mem.count(u8, content, "\n-"));
        try diffs.append(.{
            .before_path = before_path,
            .after_path = after_path,
            .content = content,
        });
        break :blk;
    }

    return TreeDiff{
        .overview = overview.items,
        .diffs = diffs.items,
    };
}

pub const TreeDiff = struct {
    overview: []const StateLine,
    diffs: []const Diff,

    pub const StateLine = struct {
        before: State,
        after: State,
        action: Action,
        sub_path: string,
        adds: u32,
        subs: u32,
    };

    pub const State = struct {
        mode: Tree.Object.Mode,
        blob: BlobId,
    };

    pub const Action = enum {
        A, // Added
        C, // Copied
        D, // Deleted
        M, // Modified
        R, // Renamed
        T, // type changed
        U, // Unmerged
        X, // Unknown
        B, // Broken

        pub fn toString(self: Action, alloc: std.mem.Allocator) !string {
            _ = alloc;
            return @tagName(self);
        }
    };

    pub const Diff = struct {
        before_path: string,
        after_path: string,
        content: string,
    };
};

pub fn getBranches(alloc: std.mem.Allocator, dir: nfs.Dir) ![]const Ref {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "show-ref", "--heads" },
        .max_output_bytes = 1024 * 1024 * 1024,
    });
    std.debug.assert(result.term == .Exited and result.term.Exited == 0);
    const output = std.mem.trimRight(u8, result.stdout, "\n");
    var iter = std.mem.splitScalar(u8, output, '\n');
    var list = std.ArrayList(Ref).init(alloc);
    errdefer list.deinit();
    while (iter.next()) |line| {
        var jter = std.mem.splitScalar(u8, line, ' ');
        try list.append(Ref{
            .commit = ensureObjId(CommitId, jter.next().?),
            .label = extras.trimPrefixEnsure(jter.rest(), "refs/heads/").?,
            .tag = null,
        });
    }
    return list.toOwnedSlice();
}

pub fn getTags(alloc: std.mem.Allocator, dir: nfs.Dir) ![]const Ref {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    // 97bc4b5f87656a34139e1a8122866c8c5b432598 refs/tags/1.2.5
    // a450a23e318c5a8fcba5a52c8fdc2e23584650b3 refs/tags/1.2.5^{}
    // 71264720050572b7bad24532ff39951f47d9296a refs/tags/15.3.1
    // 7dfd3948a9095f0253bfba60fed52895ffbf84bb refs/tags/15.3.2
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "show-ref", "--tags", "--dereference" },
        .max_output_bytes = 1024 * 1024 * 1024,
    });
    if (result.term == .Exited and result.term.Exited == 1) return &.{}; // show-ref exits 1 when there are no tags
    std.debug.assert(result.term == .Exited and result.term.Exited == 0);
    const output = std.mem.trimRight(u8, result.stdout, "\n");
    var iter = std.mem.splitScalar(u8, output, '\n');
    var list = std.ArrayList(Ref).init(alloc);
    errdefer list.deinit();
    while (iter.next()) |line| {
        var jter = std.mem.splitScalar(u8, line, ' ');
        const id = ensureObjId(CommitId, jter.next().?).id;
        const label = extras.trimPrefixEnsure(jter.rest(), "refs/tags/").?;
        extras.assertLog(!std.mem.endsWith(u8, label, "^{}"), "{s}", .{label});

        switch (try getType(alloc, dir, id)) {
            .tree => continue,
            .blob => unreachable,
            .commit => {
                try list.append(Ref{
                    .label = label,
                    .commit = ensureObjId(CommitId, id),
                    .tag = null,
                });
            },
            .tag => {
                const derefline = iter.next().?;
                var kter = std.mem.splitScalar(u8, derefline, ' ');
                const id2 = ensureObjId(CommitId, kter.next().?).id;
                const label2 = extras.trimPrefixEnsure(kter.rest(), "refs/tags/").?;
                extras.assertLog(std.mem.endsWith(u8, label2, "^{}"), "{s}", .{label2});
                std.debug.assert(std.mem.eql(u8, label, extras.trimSuffixEnsure(label2, "^{}").?));
                // extras.assertLog(try isType(alloc, dir, id2, .commit), id2); // linux kernel has a single tag that points at a tree
                if (!try isType(alloc, dir, id2, .commit)) continue;

                try list.append(Ref{
                    .label = label,
                    .commit = ensureObjId(CommitId, id2),
                    .tag = ensureObjId(TagId, id),
                });
            },
        }
    }
    return list.toOwnedSlice();
}

pub const Ref = struct {
    label: string,
    commit: CommitId,
    tag: ?TagId,
};

// TODO make this inspect .git/objects
pub fn getBlame(alloc: std.mem.Allocator, dir: std.fs.Dir, at: CommitId, sub_path: string) !string {
    const t = tracer.trace(@src(), " {s} -- {s}", .{ at.id, sub_path });
    defer t.end();

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir,
        .argv = &.{ "git", "blame", "-p", at.id, "--", sub_path },
        .max_output_bytes = 1024 * 1024 * 1024,
    });
    extras.assertLog(result.term == .Exited and result.term.Exited == 0, "{s}", .{result.stderr});
    return result.stdout;
}

pub const BlameIterator = struct {
    inner: std.mem.SplitIterator(u8, .scalar),

    pub fn init(blamefile: []const u8) BlameIterator {
        return .{
            .inner = std.mem.splitScalar(u8, blamefile, '\n'),
        };
    }

    /// when line.continuity is >0 then .commit will be the same for the next continuity-1 iterations
    pub fn next(self: *BlameIterator) ?Line {
        var result: Line = .{
            .commit = undefined,
            .prev_line = 0,
            .curr_line = 0,
            .continuity = 0,
            .author = .{ .name = "", .email = "", .at = .initUnix(0) },
            .committer = .{ .name = "", .email = "", .at = .initUnix(0) },
            .summary = "",
            .previous = null,
            .filename = "",
            .line = "",
        };
        blk: {
            var it = std.mem.splitScalar(u8, self.inner.next() orelse return null, ' ');
            result.commit = ensureObjId(CommitId, extras.nullifyS(it.next().?) orelse return null);
            result.prev_line = std.fmt.parseInt(u32, it.next().?, 10) catch unreachable;
            result.curr_line = std.fmt.parseInt(u32, it.next().?, 10) catch unreachable;
            result.continuity = std.fmt.parseInt(u32, it.next() orelse break :blk, 10) catch unreachable;
        }
        while (self.inner.next()) |line| {
            if (line[0] == '\t') {
                result.line = line[1..];
                break;
            }
            if (extras.trimPrefixEnsure(line, "author ")) |trimmed| {
                result.author = .{
                    .name = trimmed,
                    .email = extras.trimPrefixEnsure(self.inner.next().?, "author-mail ").?,
                    .at = parseAt(
                        extras.trimPrefixEnsure(self.inner.next().?, "author-time ").?,
                        extras.trimPrefixEnsure(self.inner.next().?, "author-tz ").?,
                    ),
                };
                continue;
            }
            if (extras.trimPrefixEnsure(line, "committer ")) |trimmed| {
                result.committer = .{
                    .name = trimmed,
                    .email = extras.trimPrefixEnsure(self.inner.next().?, "committer-mail ").?,
                    .at = parseAt(
                        extras.trimPrefixEnsure(self.inner.next().?, "committer-time ").?,
                        extras.trimPrefixEnsure(self.inner.next().?, "committer-tz ").?,
                    ),
                };
                continue;
            }
            if (extras.trimPrefixEnsure(line, "summary ")) |trimmed| {
                result.summary = trimmed;
                continue;
            }
            if (extras.trimPrefixEnsure(line, "previous ")) |trimmed| {
                var it = std.mem.splitScalar(u8, trimmed, ' ');
                result.previous = .{
                    ensureObjId(CommitId, it.next().?),
                    it.next().?,
                };
                continue;
            }
            if (extras.trimPrefixEnsure(line, "filename ")) |trimmed| {
                result.filename = trimmed;
                continue;
            }
        }
        return result;
    }

    pub const Line = struct {
        commit: CommitId,
        prev_line: u32,
        curr_line: u32,
        continuity: u32,
        author: UserAndAt,
        committer: UserAndAt,
        summary: string,
        previous: ?struct { CommitId, string },
        filename: string,
        line: string,
    };
};
