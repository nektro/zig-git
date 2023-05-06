const std = @import("std");
const string = []const u8;
const top = @This();
const time = @import("time");
const extras = @import("extras");

// 40 is length of sha1 hash
pub const Id = *const [40]u8;
pub const TreeId = struct { id: Id };
pub const CommitId = struct { id: Id };
pub const BlobId = struct { id: Id };

/// Returns the result of running `git rev-parse HEAD`
/// dir must already be pointing at the .git folder
// TODO this doesnt handle when there are 0 commits
pub fn getHEAD(alloc: std.mem.Allocator, dir: std.fs.Dir) !CommitId {
    const h = std.mem.trimRight(u8, try dir.readFileAlloc(alloc, "HEAD", 1024), "\n");

    if (std.mem.startsWith(u8, h, "ref:")) {
        const r = blk: {
            const pckedrfs = dir.readFileAlloc(alloc, "packed-refs", 1024 * 1024 * 1024) catch |err| switch (err) {
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
        return ensureObjId(CommitId, r);
    }

    return ensureObjId(CommitId, h);
}

fn ensureObjId(comptime T: type, input: string) T {
    std.debug.assert(input.len == 40);
    return .{ .id = input[0..40] };
}

// TODO make this inspect .git/objects
// TODO make this return a Reader when we implement it ourselves
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn getObject(alloc: std.mem.Allocator, dir: std.fs.Dir, obj: Id) !string {
    const result = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .cwd_dir = dir,
        .argv = &.{ "git", "cat-file", "-p", obj },
        .max_output_bytes = 1024 * 1024 * 1024,
    });
    return std.mem.trimRight(u8, result.stdout, "\n");
}

// TODO make this inspect .git/objects manually
// TODO make this return a Reader when we implement it ourselves
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn getObjectSize(alloc: std.mem.Allocator, dir: std.fs.Dir, obj: Id) !u64 {
    const result = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .cwd_dir = dir,
        .argv = &.{ "git", "cat-file", "-s", obj },
    });
    return try std.fmt.parseInt(u64, std.mem.trimRight(u8, result.stdout, "\n"), 10);
}

// TODO make this inspect .git manually
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn isType(alloc: std.mem.Allocator, dir: std.fs.Dir, maybeobj: Id, typ: Tree.Object.Id.Tag) !?bool {
    const result = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .cwd_dir = dir,
        .argv = &.{ "git", "cat-file", "-t", maybeobj },
    });
    if (result.term != .Exited or result.term.Exited != 0) return null;
    const output = std.mem.trimRight(u8, result.stdout, "\n");
    return std.meta.stringToEnum(Tree.Object.Id.Tag, output).? == typ;
}

// TODO make this inspect .git/objects manually
// TODO make this return a Reader when we implement it ourselves
// TODO make a version of this that accepts an array of sub_paths and searches all of them at once, so as to not lose spot in history when searching for many old paths
// https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
// https://git-scm.com/book/en/v2/Git-Internals-Packfiles
pub fn revList(alloc: std.mem.Allocator, dir: std.fs.Dir, comptime count: u31, from: CommitId, sub_path: string) !string {
    const result = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .cwd_dir = dir,
        .argv = &.{
            "git",
            "rev-list",
            "-" ++ std.fmt.comptimePrint("{d}", .{count}),
            from.id,
            "--",
            sub_path,
        },
    });
    return std.mem.trimRight(u8, result.stdout, "\n");
}

pub fn parseCommit(alloc: std.mem.Allocator, commitfile: string) !Commit {
    var iter = std.mem.split(u8, commitfile, "\n");
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

fn parseCommitUserAndAt(input: string) !Commit.UserAndAt {
    // Mitchell Hashimoto <mitchell.hashimoto@gmail.com> 1680797363 -0700
    // first and second part is https://datatracker.ietf.org/doc/html/rfc5322#section-3.4
    // third part is unix epoch timestamp
    // fourth part is TZ
    var maybe_bad_parser = std.mem.splitBackwards(u8, input, " ");
    const tz_part = maybe_bad_parser.next() orelse return error.BadCommitTz;
    const time_part = maybe_bad_parser.next() orelse return error.BadCommitTime;
    const email_part = maybe_bad_parser.next() orelse return error.BadCommitEmail;
    const name_part = maybe_bad_parser.rest();
    _ = tz_part;
    std.debug.assert(email_part[0] == '<');
    std.debug.assert(email_part[email_part.len - 1] == '>');
    return .{
        .name = name_part,
        .email = std.mem.trim(u8, email_part, "<>"),
        .at = time.DateTime.initUnix(try std.fmt.parseInt(u64, time_part, 10)),
    };
}

pub const Commit = struct {
    tree: TreeId,
    parents: []const CommitId,
    author: UserAndAt,
    committer: UserAndAt,
    gpgsig: string,
    message: string,

    pub const UserAndAt = struct {
        name: string,
        email: string,
        at: time.DateTime,
    };
};

pub fn parseTree(alloc: std.mem.Allocator, treefile: string) !Tree {
    var iter = std.mem.split(u8, treefile, "\n");
    var children = std.ArrayList(Tree.Object).init(alloc);
    errdefer children.deinit();

    while (iter.next()) |line| {
        var jter = std.mem.split(u8, line, " ");
        const mode = jter.next().?;
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
    std.debug.assert(input.len == 6);
    return .{
        .type = @intToEnum(Tree.Object.Type, try std.fmt.parseInt(u16, input[0..3], 10)),
        .perm_user = @bitCast(Tree.Object.Perm, try std.fmt.parseInt(u3, input[3..][0..1], 8)),
        .perm_group = @bitCast(Tree.Object.Perm, try std.fmt.parseInt(u3, input[4..][0..1], 8)),
        .perm_other = @bitCast(Tree.Object.Perm, try std.fmt.parseInt(u3, input[5..][0..1], 8)),
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
pub fn getTreeDiff(alloc: std.mem.Allocator, dir: std.fs.Dir, commitid: CommitId, parentid: CommitId) !string {
    const result = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .cwd_dir = dir,
        .argv = &.{ "git", "diff-tree", "-p", "--raw", parentid.id, commitid.id },
        .max_output_bytes = 1024 * 1024 * 1024,
    });
    return std.mem.trim(u8, result.stdout, "\n");
}

pub fn parseTreeDiffMeta(input: string) !TreeDiffMeta {
    var result = std.mem.zeroes(TreeDiffMeta);
    var lineiter = std.mem.split(u8, input, "\n");

    while (lineiter.next()) |lin| {
        if (lin.len == 0) break;
        std.debug.assert(lin[0] == ':');
        result.files_changed += 1;
    }

    while (lineiter.next()) |lin| {
        std.debug.assert(lin.len > 0);
        switch (lin[0]) {
            // zig fmt: off
            'd' => continue, // diff --git a/src/Sema.zig b/src/Sema.zig
                             // deleted file mode 100644
            'n' => continue, // new file mode 100644
            'i' => continue, // index 327ff3800..df199be97 100644
            '@' => continue, // @@ -24629,10 +24634,11 @@
            ' ' => continue,
            '+' => result.lines_added += 1,
            '-' => result.lines_removed += 1,
            '\\' => continue, // \ No newline at end of file
            'B' => {
                // Binary files a/stage1/zig1.wasm and b/stage1/zig1.wasm differ
                result.lines_added += 1;
                result.lines_removed += 1;
            },
            else => {
                std.log.err("{s}", .{lin});
                std.log.err("{s}", .{input});
                @panic("unreachable");
            },
            // zig fmt: on
        }
    }

    // Every affected file in the diff has a preamble like below that we don't want to double count.
    //
    // diff --git a/notes/all_packages.txt b/notes/all_packages.txt
    // index c06b41d..e8f91cf 100644
    // --- a/notes/all_packages.txt
    // +++ b/notes/all_packages.txt
    // @@ -89,3 +89,4 @@ freedesktop/xorg/libsm
    result.lines_added -= result.files_changed;
    result.lines_removed -= result.files_changed;

    return result;
}

pub const TreeDiffMeta = struct {
    files_changed: u16,
    lines_added: u32,
    lines_removed: u32,
};

pub fn parseTreeDiff(alloc: std.mem.Allocator, input: string) !TreeDiff {
    var lineiter = std.mem.split(u8, input, "\n");
    var overview = std.ArrayList(TreeDiff.StateLine).init(alloc);
    var diffs = std.ArrayList(TreeDiff.Diff).init(alloc);

    while (lineiter.next()) |lin| {
        if (lin.len == 0) break;
        std.debug.assert(lin[0] == ':');

        // :100644 100644 c06b41d04c381f1841d445c0072219d9a7f57e17 e8f91cf7dd413ac65a362b0a170951033dba4762 M     notes/all_packages.txt
        var jter = std.mem.tokenize(u8, lin[1..], " ");
        const before_mode = try parseTreeMode(jter.next().?);
        const after_mode = try parseTreeMode(jter.next().?);

        const before_tree = ensureObjId(TreeId, jter.next().?);
        const after_tree = ensureObjId(TreeId, jter.next().?);

        var kter = std.mem.split(u8, jter.next().?, "\t"); // why is there a tab here git. why?
        const action_s = kter.next().?;

        try overview.append(.{
            .before = .{
                .mode = before_mode,
                .tree = before_tree,
            },
            .after = .{
                .mode = after_mode,
                .tree = after_tree,
            },
            .action = std.meta.stringToEnum(TreeDiff.Action, action_s).?,
            .sub_path = kter.rest(),
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
    std.debug.assert(std.mem.startsWith(u8, lineiter.next().?, "diff --git"));
    blk: while (true) {
        while (lineiter.next()) |lin| {
            if (std.mem.startsWith(u8, lin, "index")) break;
        }

        const before_path_raw = lineiter.next().?;
        if (std.mem.startsWith(u8, before_path_raw, "Binary files")) {
            try diffs.append(.{
                .before_path = overview.items[diffs.items.len].sub_path,
                .after_path = overview.items[diffs.items.len].sub_path,
                .content = before_path_raw,
            });
            _ = lineiter.index orelse break :blk;
            continue :blk;
        }
        const before_path = extras.trimPrefixEnsure(before_path_raw, "--- a/") orelse extras.trimPrefixEnsure(before_path_raw, "--- ").?;

        const after_path_raw = lineiter.next().?;
        const after_path = extras.trimPrefixEnsure(after_path_raw, "+++ b/") orelse extras.trimPrefixEnsure(after_path_raw, "+++ ").?;

        const start_index = lineiter.index.?;

        while (lineiter.next()) |lin| {
            if (std.mem.startsWith(u8, lin, "diff --git")) {
                const end_index = lineiter.index.? - lin.len - 2;
                try diffs.append(.{
                    .before_path = before_path,
                    .after_path = after_path,
                    .content = input[start_index..end_index],
                });
                continue :blk;
            }
        }
        try diffs.append(.{
            .before_path = before_path,
            .after_path = after_path,
            .content = input[start_index..],
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
    };

    pub const State = struct {
        mode: Tree.Object.Mode,
        tree: TreeId,
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
