const std = @import("std");
const string = []const u8;
const top = @This();
const time = @import("time");
const extras = @import("extras");
const tracer = @import("tracer");
const nfs = @import("nfs");
const nio = @import("nio");

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

pub const RefType = enum {
    blob,
    tree,
    commit,
    tag,
};

pub const AnyId = union(RefType) {
    blob: BlobId,
    tree: TreeId,
    commit: CommitId,
    tag: TagId,

    pub fn erase(self: AnyId) Id {
        return switch (self) {
            inline else => |v| v.id,
        };
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
                error.ENOENT => break :blk,
                else => |e| return e,
            };
            return ensureObjId(CommitId, std.mem.trimRight(u8, reffile, "\n"));
        }
        blk: {
            const pckedrfs = dir.readFileAlloc(alloc, "packed-refs", 1024 * 1024 * 1024) catch |err| switch (err) {
                error.ENOENT => break :blk,
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

// 40 is length of sha1 hash
pub fn ensureObjId(comptime T: type, input: string) T {
    extras.assertLog(input.len == 40, "ensureObjId: {s}", .{input});
    return .{ .id = input[0..40] };
}

// TODO make this inspect .git/objects
// TODO make this return a Reader when we implement it ourselves
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn getObjectContent(alloc: std.mem.Allocator, dir: nfs.Dir, obj: Id) !string {
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
    return try extras.parseDigits(u64, std.mem.trimRight(u8, result.stdout, "\n"), 10);
}

// TODO make this inspect .git manually
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn isType(alloc: std.mem.Allocator, dir: nfs.Dir, maybeobj: Id, typ: RefType) !bool {
    const t = tracer.trace(@src(), " {s} = {s} ?", .{ maybeobj, @tagName(typ) });
    defer t.end();

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "cat-file", "-t", maybeobj },
    });
    std.debug.assert(result.term == .Exited and result.term.Exited == 0);
    const output = std.mem.trimRight(u8, result.stdout, "\n");
    return std.meta.stringToEnum(RefType, output).? == typ;
}

// TODO make this inspect .git manually
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn getType(alloc: std.mem.Allocator, dir: nfs.Dir, obj: Id) !RefType {
    const t = tracer.trace(@src(), " {s}", .{obj});
    defer t.end();

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "cat-file", "-t", obj },
    });
    std.debug.assert(result.term == .Exited and result.term.Exited == 0);
    const output = std.mem.trimRight(u8, result.stdout, "\n");
    return std.meta.stringToEnum(RefType, output) orelse @panic(output);
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

// TODO make this inspect .git/objects manually
// TODO make a version of this that accepts an array of sub_paths and searches all of them at once, so as to not lose spot in history when searching for many old paths
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn revListAll(alloc: std.mem.Allocator, dir: nfs.Dir, from: CommitId, sub_path: string) !string {
    const t = tracer.trace(@src(), " {s} -- {s}", .{ from.id, sub_path });
    defer t.end();

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "rev-list", from.id, "--", sub_path },
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
    var email_part = maybe_bad_parser.next() orelse return error.BadCommitEmail;
    while (email_part[0] != '<') {
        const next_len = maybe_bad_parser.next().?.len;
        email_part.ptr -= next_len + 1;
        email_part.len += next_len + 1;
    }
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
    const at = time.DateTime.initUnix(extras.parseDigits(u64, time_part, 10) catch unreachable);
    std.debug.assert(tz_part.len == 5);
    std.debug.assert(tz_part[0] == '-' or tz_part[0] == '+');
    // const sign: i8 = if (tz_part[0] == '+') 1 else -1;
    // const hrs = extras.parseDigits(u8, tz_part[1..][0..2], 10) catch unreachable;
    // const mins = extras.parseDigits(u8, tz_part[3..][0..2], 10) catch unreachable;
    // if (sign > 0) at = at.addHours(hrs);
    // if (sign > 0) at = at.addMins(mins);
    // at.offset += (hrs * 60) + mins;
    // if (sign < 0) at = at.subHours(hrs); // TODO:
    // if (sign < 0) at = at.subMins(mins); // TODO:
    // at.offset -= (hrs * 60) + mins;
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
        const otype = std.meta.stringToEnum(RefType, jter.next().?).?;
        const id_and_name = jter.rest();
        const tab_pos = std.mem.indexOfScalar(u8, id_and_name, '\t').?; // why git. why.
        std.debug.assert(tab_pos == 40);
        const id = id_and_name[0..tab_pos][0..40];
        const name = id_and_name[tab_pos + 1 ..];

        inline for (std.meta.fields(AnyId)) |item| {
            if (std.mem.eql(u8, item.name, @tagName(otype))) {
                try children.append(.{
                    .mode = try parseTreeMode(mode),
                    .id = @unionInit(AnyId, item.name, item.type{ .id = id }),
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
        .type = @enumFromInt(try extras.parseDigits(u16, input[0..3], 10)),
        .perm_user = @bitCast(try extras.parseDigits(u3, input[3..][0..1], 8)),
        .perm_group = @bitCast(try extras.parseDigits(u3, input[4..][0..1], 8)),
        .perm_other = @bitCast(try extras.parseDigits(u3, input[5..][0..1], 8)),
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

    pub fn find(self: Tree, name: string) ?Object {
        for (self.children) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) {
                return item;
            }
        }
        return null;
    }

    pub fn findBlob(self: Tree, name: string) ?Object {
        const o = self.find(name) orelse return null;
        if (o.id != .blob) return null;
        return o;
    }

    pub const Object = struct {
        mode: Mode,
        id: AnyId,
        name: string,

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

            pub fn nprint(self: Mode, writer: anytype) !void {
                try self.type.nprint(writer);
                try self.perm_user.nprint(writer);
                try self.perm_group.nprint(writer);
                try self.perm_other.nprint(writer);
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

            pub fn nprint(self: Type, writer: anytype) !void {
                try writer.writeAll(&.{switch (self) {
                    .file => '-',
                    .directory => 'd',
                    .submodule => 'm',
                    .symlink => '-',
                    .none => '-',
                }});
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

            pub fn nprint(self: Perm, writer: anytype) !void {
                try writer.writeAll(&.{
                    if (self.read) 'r' else '-',
                    if (self.write) 'w' else '-',
                    if (self.execute) 'x' else '-',
                });
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
            .argv = &.{ "git", "diff-tree", "-p", "--raw", "--full-index", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", commitid.id },
            .max_output_bytes = 1024 * 1024 * 1024,
        });
        std.debug.assert(result.term == .Exited and result.term.Exited == 0);
        return std.mem.trim(u8, result.stdout, "\n");
    }
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "diff-tree", "-p", "--raw", "--full-index", parentid.?.id, commitid.id },
        .max_output_bytes = 1024 * 1024 * 1024,
    });
    std.debug.assert(result.term == .Exited and result.term.Exited == 0);
    return std.mem.trim(u8, result.stdout, "\n");
}

// TODO make this inspect .git manually
// TODO make this return a Reader when we implement it ourselves
pub fn getTreeDiffPath(alloc: std.mem.Allocator, dir: nfs.Dir, commitid: CommitId, parentid: ?CommitId, path: []const u8) !string {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    if (parentid == null) {
        const result = try std.process.Child.run(.{
            .allocator = alloc,
            .cwd_dir = dir.to_std(),
            // 4b825dc642cb6eb9a060e54bf8d69288fbee4904 is a hardcode for the empty tree in git sha1
            // result of `printf | git hash-object -t tree --stdin`
            .argv = &.{ "git", "diff-tree", "-p", "--raw", "--full-index", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", commitid.id, "--", path },
            .max_output_bytes = 1024 * 1024 * 1024,
        });
        std.debug.assert(result.term == .Exited and result.term.Exited == 0);
        return std.mem.trim(u8, result.stdout, "\n");
    }
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "diff-tree", "-p", "--raw", "--full-index", parentid.?.id, commitid.id, "--", path },
        .max_output_bytes = 1024 * 1024 * 1024,
    });
    std.debug.assert(result.term == .Exited and result.term.Exited == 0);
    return std.mem.trim(u8, result.stdout, "\n");
}

pub fn parseTreeDiff(alloc: std.mem.Allocator, input: string) !TreeDiff {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var lineiter = std.mem.splitScalar(u8, input, '\n');
    var overview = std.ArrayList(TreeDiff.StateLine).init(alloc);
    var diffs = std.ArrayList(TreeDiff.Diff).init(alloc);
    var meta = std.mem.zeroes(TreeDiff.Meta);

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
        });
        meta.files_changed += 1;
    }
    if (lineiter.peek() == null) {
        return TreeDiff{
            .overview = overview.items,
            .diffs = diffs.items,
            .meta = meta,
        };
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
    blk: while (true) {
        const first_line = lineiter.next().?;
        std.debug.assert(std.mem.startsWith(u8, first_line, "diff --git"));
        var i = diffs.items.len;
        var n: usize = 0;
        while (n < i) : (n += 1) i -= @intFromBool(overview.items[n].action == .T);
        try diffs.append(.{
            .index = @splat(.{ .id = undefined }),
            .before_path = overview.items[i].sub_path,
            .after_path = overview.items[i].sub_path,
            .subs = 0,
            .adds = 0,
            .content = "",
        });
        const diff = &diffs.items[diffs.items.len - 1];

        while (true) {
            if (lineiter.index.? >= input.len) {
                break :blk;
            }
            if (lineiter.peek()) |lin| {
                if (std.mem.startsWith(u8, lin, "index")) {
                    const index = lin[6..];
                    var iiter = std.mem.splitSequence(u8, index, "..");
                    var xx: [2][]const u8 = .{ iiter.next().?, iiter.next().? };
                    std.debug.assert(iiter.next() == null);
                    if (std.mem.indexOfScalar(u8, xx[1], ' ')) |j| xx[1] = xx[1][0..j];
                    diff.index[0] = ensureObjId(CommitId, xx[0]);
                    diff.index[1] = ensureObjId(CommitId, xx[1]);

                    lineiter.index.? += lin.len + 1;
                    break;
                }
                if (std.mem.startsWith(u8, lin, "new file mode")) {
                    lineiter.index.? += lin.len + 1;
                    continue;
                }
                if (std.mem.startsWith(u8, lin, "deleted file mode")) {
                    lineiter.index.? += lin.len + 1;
                    continue;
                }
                if (std.mem.startsWith(u8, lin, "old mode")) {
                    lineiter.index.? += lin.len + 1;
                    continue;
                }
                if (std.mem.startsWith(u8, lin, "new mode")) {
                    lineiter.index.? += lin.len + 1;
                    continue;
                }
                if (std.mem.startsWith(u8, lin, "diff --git")) {
                    continue :blk;
                }
                std.log.err("{s}", .{lin});
                unreachable;
            }
        }

        var content_start: usize = 0;

        while (true) {
            if (lineiter.index.? >= input.len) {
                break :blk;
            }
            if (lineiter.peek()) |lin| {
                if (std.mem.startsWith(u8, lin, "--- ")) {
                    diff.before_path = extras.trimPrefix(lin[4..], "a/");
                    lineiter.index.? += lin.len + 1;
                    continue;
                }
                if (std.mem.startsWith(u8, lin, "+++ ")) {
                    diff.after_path = extras.trimPrefix(lin[4..], "b/");
                    lineiter.index.? += lin.len + 1;
                    continue;
                }
                if (std.mem.startsWith(u8, lin, "@@ ")) {
                    content_start = lineiter.index.?;
                    lineiter.index.? += lin.len + 1;
                    break;
                }
                if (std.mem.startsWith(u8, lin, "Binary files ")) {
                    content_start = lineiter.index.?;
                    lineiter.index.? += lin.len + 1;
                    break;
                }
                if (std.mem.startsWith(u8, lin, "diff --git")) {
                    continue :blk;
                }
                std.log.err("{s}", .{lin});
                unreachable;
            }
        }
        if (lineiter.index.? >= input.len) {
            diff.content = input[content_start..];
            break :blk;
        }

        while (true) {
            if (lineiter.peek()) |lin| {
                if (std.mem.startsWith(u8, lin, "diff --git")) {
                    const content_end = lineiter.index.? - 1;
                    diff.content = input[content_start..content_end];
                    continue :blk;
                }
                if (lin[0] == '-') {
                    diff.subs += 1;
                    meta.lines_removed += 1;
                }
                if (lin[0] == '+') {
                    diff.adds += 1;
                    meta.lines_added += 1;
                }
                lineiter.index.? += lin.len + 1;

                if (lineiter.index.? >= input.len) {
                    diff.content = input[content_start..];
                    break :blk;
                }
            }
        }
    }

    return TreeDiff{
        .overview = overview.items,
        .diffs = diffs.items,
        .meta = meta,
    };
}

pub const TreeDiff = struct {
    overview: []const StateLine,
    diffs: []const Diff,
    meta: Meta,

    pub const StateLine = struct {
        before: State,
        after: State,
        action: Action,
        sub_path: string,
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
        index: [2]CommitId,
        before_path: string,
        after_path: string,
        adds: u32,
        subs: u32,
        content: string,
    };

    pub const Meta = struct {
        files_changed: u32,
        lines_added: u64,
        lines_removed: u64,
    };
};

pub fn getBranches(alloc: std.mem.Allocator, dir: nfs.Dir) ![]Ref {
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
            .oid = ensureObjId(CommitId, jter.next().?).id,
            .label = extras.trimPrefixEnsure(jter.rest(), "refs/heads/").?,
        });
    }
    return list.toOwnedSlice();
}

pub fn getTags(alloc: std.mem.Allocator, dir: nfs.Dir) ![]Ref {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    // 97bc4b5f87656a34139e1a8122866c8c5b432598 refs/tags/1.2.5
    // a450a23e318c5a8fcba5a52c8fdc2e23584650b3 refs/tags/1.2.5^{}
    // 71264720050572b7bad24532ff39951f47d9296a refs/tags/15.3.1
    // 7dfd3948a9095f0253bfba60fed52895ffbf84bb refs/tags/15.3.2
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
        .argv = &.{ "git", "show-ref", "--tags" },
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

        try list.append(Ref{
            .oid = id,
            .label = label,
        });
    }
    return list.toOwnedSlice();
}

pub const Ref = struct {
    oid: Id,
    label: string,
};

pub fn parseTag(tagfile: string) !Tag {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var iter = std.mem.splitScalar(u8, tagfile, '\n');
    var result: Tag = undefined;
    result.tagger = null;
    const object = extras.trimPrefixEnsure(iter.next().?, "object ").?;
    std.debug.assert(object.len == 40);
    result.object = object[0..40];
    const ty = extras.trimPrefixEnsure(iter.next().?, "type ").?;
    result.type = std.meta.stringToEnum(RefType, ty).?;
    const tag = extras.trimPrefixEnsure(iter.next().?, "tag ").?;
    _ = tag;

    while (true) {
        const line = iter.next() orelse break;
        if (line.len == 0) break;
        const space = std.mem.indexOfScalar(u8, line, ' ').?;
        const k = line[0..space];
        if (std.mem.eql(u8, k, "tagger")) result.tagger = try parseCommitUserAndAt(line[space + 1 ..]);
    }
    result.message = iter.rest();
    return result;
}

pub const Tag = struct {
    object: Id,
    type: RefType,
    tagger: ?UserAndAt,
    message: string,
};

// TODO make this inspect .git/objects
pub fn getBlame(alloc: std.mem.Allocator, dir: nfs.Dir, at: CommitId, sub_path: string) !string {
    const t = tracer.trace(@src(), " {s} -- {s}", .{ at.id, sub_path });
    defer t.end();

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .cwd_dir = dir.to_std(),
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
            result.prev_line = extras.parseDigits(u32, it.next().?, 10) catch unreachable;
            result.curr_line = extras.parseDigits(u32, it.next().?, 10) catch unreachable;
            result.continuity = extras.parseDigits(u32, it.next() orelse break :blk, 10) catch unreachable;
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

pub const Repository = struct {
    gitdir: nfs.Dir,
    gpa: std.mem.Allocator,
    raw_object_contents: std.StringArrayHashMapUnmanaged([]const u8),
    idx_content: std.StringArrayHashMapUnmanaged([]const u8),
    pack_content: std.StringArrayHashMapUnmanaged([]const u8),
    commits: std.StringArrayHashMapUnmanaged(Commit),
    trees: std.StringArrayHashMapUnmanaged(Tree),

    pub fn init(gitdir: nfs.Dir, gpa: std.mem.Allocator) Repository {
        return .{
            .gitdir = gitdir,
            .gpa = gpa,
            .raw_object_contents = .empty,
            .idx_content = .empty,
            .pack_content = .empty,
            .commits = .empty,
            .trees = .empty,
        };
    }

    pub fn deinit(r: *Repository) void {
        for (r.raw_object_contents.values()) |v| r.gpa.free(v);
        r.raw_object_contents.deinit(r.gpa);
        for (r.idx_content.values()) |v| nfs.munmap(v);
        r.idx_content.deinit(r.gpa);
        for (r.pack_content.values()) |v| nfs.munmap(v);
        r.pack_content.deinit(r.gpa);
        r.commits.deinit(r.gpa);
        for (r.trees.values()) |v| r.gpa.free(v.children);
        r.trees.deinit(r.gpa);
    }

    fn getObject(r: *Repository, obj: Id, arena: std.mem.Allocator) !?[]const u8 {
        if (r.raw_object_contents.get(obj)) |content| {
            return content;
        }
        if (obj.len == 40) blk: { //sha1 object
            var sub_path: [49:0]u8 = "objects/00/00000000000000000000000000000000000000".*;
            @memcpy(sub_path[8..][0..2], obj[0..2]);
            @memcpy(sub_path[11..], obj[2..]);
            const objfile = r.gitdir.openFile(&sub_path, .{}) catch |err| switch (err) {
                error.ENOENT => break :blk,
                else => |e| return e,
            };
            defer objfile.close();
            var bufr = nio.BufferedReader(4096, nfs.File).init(objfile);
            var list: std.ArrayList(u8) = .init(r.gpa);
            errdefer list.deinit();
            try list.ensureUnusedCapacity(512);
            try std.compress.flate.inflate.decompress(.zlib, bufr.anyReadable(), list.writer());
            const content = try list.toOwnedSlice();
            try r.raw_object_contents.put(r.gpa, obj, content);
            return content;
        }

        // read .idx
        if (r.idx_content.count() == 0) {
            const packdir = try r.gitdir.openDir("objects/pack", .{});
            defer packdir.close();
            var iter = packdir.iterate();
            while (try iter.next()) |entry| {
                if (entry.type != .REG) continue;
                if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
                std.log.debug("packdir iterate: {s}", .{entry.name});

                const idx_file = try packdir.openFile(entry.name, .{});
                defer idx_file.close();
                const idx_content = try idx_file.mmap();
                errdefer nfs.munmap(idx_content);
                try r.idx_content.put(
                    r.gpa,
                    try arena.dupe(u8, entry.name),
                    idx_content,
                );
            }
        }
        const pack_index, const pack_offset = blk: for (r.idx_content.keys(), r.idx_content.values()) |idx_path, idx_content| {
            if (std.mem.startsWith(u8, idx_content, "\xfftOc")) {
                std.debug.assert(std.mem.readInt(u32, idx_content[4..][0..4], .big) == 2);
                const flfo_table_bytes = idx_content[8..][0 .. 256 * 4];
                const object_count = std.mem.readInt(u32, flfo_table_bytes[255 * 4 ..][0..4], .big);
                const name_bytes = idx_content[8..][1024..][0 .. object_count * 20];
                const crc32_bytes = idx_content[8..][1024..][name_bytes.len..][0 .. object_count * 4];
                const offset_bytes = idx_content[8..][1024..][name_bytes.len..][crc32_bytes.len..][0 .. object_count * 4];
                for (0..object_count) |i| {
                    const object_id = &extras.to_hex(name_bytes[i * 20 ..][0..20].*);
                    const pack_offset = std.mem.readInt(u32, offset_bytes[i * 4 ..][0..4], .big);
                    if (std.mem.eql(u8, object_id, obj)) {
                        std.log.debug("found {s} in {s} at offset {d}", .{ obj, idx_path, pack_offset });
                        const pack_index = r.pack_content.getIndex(idx_path) orelse clk: {
                            var pack_path: [128]u8 = @splat(0);
                            @memcpy(pack_path[0..13], "objects/pack/");
                            @memcpy(pack_path[13..][0..idx_path.len], idx_path);
                            @memcpy(pack_path[13..][idx_path.len - 4 ..][0..5], ".pack");
                            const pack_name_nidx = std.mem.indexOfScalar(u8, &pack_path, 0).?;
                            const pack_file = try r.gitdir.openFile(pack_path[0..pack_name_nidx :0], .{});
                            defer pack_file.close();
                            const pack_content = try pack_file.mmap();
                            errdefer nfs.munmap(pack_content);
                            try r.pack_content.put(r.gpa, idx_path, pack_content);
                            break :clk r.pack_content.count() - 1;
                        };
                        break :blk .{ pack_index, pack_offset };
                    }
                }
            } else {
                return error.Version1Idx;
            }
        } else return null;

        // parse .pack
        std.log.warn("pack_index={d} pack_offset={d}", .{ pack_index, pack_offset });

        const pack_content = r.pack_content.values()[pack_index];
        if (!std.mem.eql(u8, pack_content[0..4], "PACK")) return error.InvalidGitPack;
        const pack_version = std.mem.readInt(u32, pack_content[4..][0..4], .big);
        switch (pack_version) {
            2 => {
                const packedobj_content = pack_content[pack_offset..];
                // var packedobj_fbs = std.ArrayListUnmanaged(u8).initBuffer(packedobj_content);
                var packedobj_fbs = nio.FixedBufferStream([]const u8).init(packedobj_content);

                const PackedObjType = enum(u3) { none, commit, tree, blob, tag, reserved, ofs_delta, ref_delta };

                var c: usize = packedobj_fbs.takeByte();
                const ty: PackedObjType = @enumFromInt((c >> 4) & 7);
                var size: usize = c & 15;
                var shift: u6 = 4;
                while (c & 0x80 > 0) {
                    c = packedobj_fbs.takeByte();
                    size += (c & 0x7f) << shift;
                    shift += 7;
                }
                std.log.warn("type={s} size={d}", .{ @tagName(ty), size });

                switch (ty) {
                    .none, .reserved => {
                        return null;
                    },
                    .commit, .tree, .blob, .tag => {
                        const compressed_content = packedobj_fbs.rest()[0..size];
                        var bufr = nio.FixedBufferStream([]const u8).init(compressed_content);
                        var list: std.ArrayList(u8) = .init(r.gpa);
                        errdefer list.deinit();
                        try list.ensureUnusedCapacity(512);
                        try list.appendSlice(@tagName(ty));
                        try list.writer().print(" {d}\x00", .{size});
                        try std.compress.flate.inflate.decompress(.zlib, bufr.anyReadable(), list.writer());
                        const content = try list.toOwnedSlice();
                        try r.raw_object_contents.put(r.gpa, obj, content);
                        return content;
                    },
                    .ofs_delta => {
                        return null;
                    },
                    .ref_delta => {
                        return null;
                    },
                }
                comptime unreachable;
            },
            3 => {
                return error.ReservedPackVersion;
            },
            else => return error.InvalidGitPack,
        }
        return null;
    }

    fn getGitObject(r: *Repository, obj: Id, arena: std.mem.Allocator) !?GitObject {
        if (try r.getObject(obj, arena)) |data| {
            const header = data[0..std.mem.indexOfScalar(u8, data, 0).?];
            const _type = header[0..std.mem.indexOfScalar(u8, header, ' ').?];
            const content_len = try extras.parseDigits(u64, header[_type.len + 1 ..], 10);
            std.debug.assert(data[header.len + 1 ..].len == content_len);
            return .{
                .type = std.meta.stringToEnum(RefType, _type).?,
                .content = try arena.dupe(u8, data[header.len + 1 ..]),
            };
        }
        return null;
    }

    const GitObject = struct {
        type: RefType,
        content: []const u8,
    };

    pub fn getCommit(r: *Repository, arena: std.mem.Allocator, id: CommitId) !?struct { CommitId, Commit } {
        if (r.commits.getPtr(id.id)) |val| {
            return .{ id, val.* };
        }
        if (try r.getGitObject(id.id, arena)) |obj| {
            if (obj.type == .commit) {
                const commit = try parseCommit(arena, obj.content);
                try r.commits.put(r.gpa, id.id, commit);
                return .{ id, commit };
            }
        }
        return null;
    }

    pub fn getTree(r: *Repository, arena: std.mem.Allocator, id: TreeId) !?struct { TreeId, Tree } {
        if (r.trees.getPtr(id.id)) |val| {
            return .{ id, val.* };
        }
        if (try r.getGitObject(id.id, arena)) |obj| {
            if (obj.type == .tree) {
                var children = std.ArrayList(Tree.Object).init(r.gpa);
                errdefer children.deinit();
                var i: usize = 0;
                while (i < obj.content.len) {
                    const mode_end = std.mem.indexOfScalar(u8, obj.content[i..], ' ').?;
                    const mode = obj.content[i..][0..mode_end];
                    i += mode_end + 1;

                    const name_end = std.mem.indexOfScalar(u8, obj.content[i..], 0).?;
                    const name = obj.content[i..][0..name_end :0];
                    i += name_end + 1;

                    const oid_raw = obj.content[i..][0..20].*;
                    const oid_hex = (try arena.alloc(u8, 40))[0..40];
                    oid_hex.* = extras.to_hex(oid_raw);
                    i += 20;

                    var mode_buf: [6]u8 = @splat('0');
                    @memcpy(mode_buf[6 - mode.len ..], mode);
                    const mode_real = try parseTreeMode(&mode_buf);

                    try children.append(.{
                        .mode = mode_real,
                        .name = name,
                        .id = switch (mode_real.type) {
                            .file => .{ .blob = .{ .id = oid_hex } },
                            .directory => .{ .tree = .{ .id = oid_hex } },
                            .submodule => .{ .commit = .{ .id = oid_hex } },
                            .symlink => .{ .blob = .{ .id = oid_hex } },
                            .none => unreachable,
                        },
                    });
                }
                const tree: Tree = .{ .children = try children.toOwnedSlice() };
                try r.trees.put(r.gpa, id.id, tree);
                return .{ id, tree };
            }
        }
        return null;
    }
};
