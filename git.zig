const std = @import("std");
const string = []const u8;
const time = @import("time");
const extras = @import("extras");
const tracer = @import("tracer");
const nfs = @import("nfs");
const nio = @import("nio");
const root = @import("root"); // temp

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
    const result = try root.child_process.run(alloc, .cwd(), .ignore, .pipe, .pipe, 1024, &.{ "git", "--version" });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    std.debug.assert(result.term == .exited and result.term.exited == 0);
    return try alloc.dupe(u8, extras.trimPrefixEnsure(std.mem.trimEnd(u8, result.stdout, "\n"), "git version ").?);
}

/// Returns the result of running `git rev-parse HEAD`
/// dir must already be pointing at the .git folder
pub fn getHEAD(alloc: std.mem.Allocator, dir: nfs.Dir) !?CommitId {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    const headfile = dir.readFileAlloc(alloc, "HEAD", 1024) catch |err| switch (err) {
        error.ENOENT => return null,
        else => |e| return e,
    };
    defer alloc.free(headfile);
    const h = std.mem.trimEnd(u8, headfile, "\n");

    if (std.mem.startsWith(u8, h, "ref:")) {
        blk: {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            @memcpy((&buf).ptr, h[5..]);
            buf[h[5..].len] = 0;
            const reffile = dir.readFileAlloc(alloc, buf[0..h[5..].len :0], 1024) catch |err| switch (err) {
                error.ENOENT => break :blk,
                else => |e| return e,
            };
            defer alloc.free(reffile);
            return ensureObjId(CommitId, try alloc.dupe(u8, std.mem.trimEnd(u8, reffile, "\n")));
        }
        blk: {
            const pckedrfs = dir.readFileAlloc(alloc, "packed-refs", 1024 * 1024 * 1024) catch |err| switch (err) {
                error.ENOENT => break :blk,
                else => |e| return e,
            };
            defer alloc.free(pckedrfs);
            var iter = std.mem.splitScalar(u8, pckedrfs, '\n');
            while (iter.next()) |line| {
                if (std.mem.startsWith(u8, line, "#")) continue;
                if (std.mem.startsWith(u8, line, "^")) continue;
                if (line.len == 0) continue;
                var jter = std.mem.splitScalar(u8, line, ' ');
                const objid = jter.next().?;
                const ref = jter.next().?;
                std.debug.assert(jter.next() == null);
                if (std.mem.eql(u8, h[5..], ref)) return ensureObjId(CommitId, try alloc.dupe(u8, objid));
            }
        }
        return null;
    }

    return ensureObjId(CommitId, try alloc.dupe(u8, h));
}

// 40 is length of sha1 hash
pub fn ensureObjId(comptime T: type, input: string) T {
    extras.assertLog(input.len == 40, "ensureObjId: {s}", .{input});
    return .{ .id = input[0..40] };
}

pub fn parseCommit(alloc: std.mem.Allocator, commitfile: string, mailmap: *const std.hash_map.StringHashMapUnmanaged([]const u8), mailmap_names: *const std.hash_map.StringHashMapUnmanaged([]const u8)) !Commit {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var iter = std.mem.splitScalar(u8, commitfile, '\n');
    var result: Commit = .{
        .raw = commitfile,
        .tree = undefined,
        .parents = undefined,
        .author = undefined,
        .committer = undefined,
        .gpgsig = "",
        .message = undefined,
    };
    var parents = std.array_list.Managed(CommitId).init(alloc);
    errdefer parents.deinit();
    var f_start: usize = 0;
    while (true) {
        const line_start = iter.index.?;
        const line = iter.next() orelse break;
        if (line.len == 0) break;
        const space = std.mem.indexOfScalar(u8, line, ' ').?;
        const k = line[0..space];

        if (std.mem.eql(u8, k, "tree")) result.tree = .{ .id = line[space + 1 ..][0..40] };
        if (std.mem.eql(u8, k, "author")) result.author = try parseCommitUserAndAt(line[space + 1 ..]);
        if (std.mem.eql(u8, k, "committer")) result.committer = try parseCommitUserAndAt(line[space + 1 ..]);
        if (std.mem.eql(u8, k, "parent")) try parents.append(.{ .id = line[space + 1 ..][0..40] });
        if (std.mem.eql(u8, k, "gpgsig")) {
            f_start = line_start + 7;
            _ = iter.next().?;
            while (true) {
                const line2_start = iter.index.?;
                const line2 = iter.next() orelse break;
                if (line2.len == 0 or line2[0] != ' ') {
                    iter.index = line2_start;
                    break;
                }
            }
            result.gpgsig = commitfile[f_start .. iter.index.? - 1];
        }
    }
    result.parents = try parents.toOwnedSlice();
    result.author.email = mailmap.get(result.author.email) orelse result.author.email;
    result.author.name = mailmap_names.get(result.author.email) orelse result.author.name;
    result.committer.email = mailmap.get(result.committer.email) orelse result.committer.email;
    result.committer.name = mailmap_names.get(result.committer.email) orelse result.committer.name;
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
    var at = time.DateTime.initUnix(extras.parseDigits(u64, time_part, 10) catch unreachable);
    std.debug.assert(tz_part.len == 5);
    std.debug.assert(tz_part[0] == '-' or tz_part[0] == '+');
    const sign: i8 = if (tz_part[0] == '+') 1 else -1;
    const hrs = extras.parseDigits(u7, tz_part[1..][0..2], 10) catch unreachable;
    const mins = extras.parseDigits(u7, tz_part[3..][0..2], 10) catch unreachable;
    at.z_offset += hrs;
    at.z_offset *= 4;
    at.z_offset += mins / 15;
    at.z_offset *= sign;
    return at;
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

// TODO make this inspect .git manually
// TODO make this return a Reader when we implement it ourselves
pub fn getTreeDiff(alloc: std.mem.Allocator, dir: nfs.Dir, commitid: CommitId, parentid: ?CommitId) !string {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    if (parentid == null) {
        // 4b825dc642cb6eb9a060e54bf8d69288fbee4904 is a hardcode for the empty tree in git sha1
        // result of `printf | git hash-object -t tree --stdin`
        const result = try root.child_process.run(alloc, dir, .ignore, .pipe, .pipe, 1024 * 1024 * 1024, &.{ "git", "diff-tree", "-p", "--raw", "--full-index", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", commitid.id });
        std.debug.assert(result.term == .exited and result.term.exited == 0);
        return std.mem.trim(u8, result.stdout, "\n");
    }
    const result = try root.child_process.run(alloc, dir, .ignore, .pipe, .pipe, 1024 * 1024 * 1024, &.{ "git", "diff-tree", "-p", "--raw", "--full-index", parentid.?.id, commitid.id });
    std.debug.assert(result.term == .exited and result.term.exited == 0);
    return std.mem.trim(u8, result.stdout, "\n");
}

// TODO make this inspect .git manually
pub fn getTreeDiffOnlyStat(alloc: std.mem.Allocator, dir: nfs.Dir, commitid: CommitId, parentid: ?CommitId) !string {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    if (parentid == null) {
        // 4b825dc642cb6eb9a060e54bf8d69288fbee4904 is a hardcode for the empty tree in git sha1
        // result of `printf | git hash-object -t tree --stdin`
        const result = try root.child_process.run(alloc, dir, .ignore, .pipe, .ignore, 1024 * 1024 * 1024, &.{ "git", "diff-tree", "--stat=2048", "--stat-graph-width=32", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", commitid.id });
        std.debug.assert(result.term == .exited and result.term.exited == 0);
        return result.stdout;
    }
    const result = try root.child_process.run(alloc, dir, .ignore, .pipe, .ignore, 1024 * 1024 * 1024, &.{ "git", "diff-tree", "--stat=2048", "--stat-graph-width=32", parentid.?.id, commitid.id });
    std.debug.assert(result.term == .exited and result.term.exited == 0);
    return result.stdout;
}

// TODO make this inspect .git manually
pub fn getTreeDiffOnlyDiff(alloc: std.mem.Allocator, dir: nfs.Dir, commitid: CommitId, parentid: ?CommitId) !string {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    if (parentid == null) {
        // 4b825dc642cb6eb9a060e54bf8d69288fbee4904 is a hardcode for the empty tree in git sha1
        // result of `printf | git hash-object -t tree --stdin`
        const result = try root.child_process.run(alloc, dir, .ignore, .pipe, .ignore, 1024 * 1024 * 1024, &.{ "git", "diff-tree", "--patch", "--full-index", "--patience", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", commitid.id });
        if (!(result.term == .exited and result.term.exited == 0)) std.log.err("{s}", .{result.stderr});
        std.debug.assert(result.term == .exited and result.term.exited == 0);
        return result.stdout;
    }
    const result = try root.child_process.run(alloc, dir, .ignore, .pipe, .ignore, 1024 * 1024 * 1024, &.{ "git", "diff-tree", "--patch", "--full-index", "--patience", parentid.?.id, commitid.id });
    if (!(result.term == .exited and result.term.exited == 0)) std.log.err("{s}", .{result.stderr});
    std.debug.assert(result.term == .exited and result.term.exited == 0);
    return result.stdout;
}

// TODO make this inspect .git manually
pub fn getFormatPatch(alloc: std.mem.Allocator, dir: nfs.Dir, commitid: CommitId, parentid: ?CommitId) !string {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    if (parentid == null) {
        const result = try root.child_process.run(alloc, dir, .ignore, .pipe, .pipe, 1024 * 1024 * 1024, &.{ "git", "format-patch", "--stdout", "--full-index", "--patience", "--root", commitid.id });
        if (!(result.term == .exited and result.term.exited == 0)) std.log.err("{s}", .{result.stderr});
        std.debug.assert(result.term == .exited and result.term.exited == 0);
        return result.stdout;
    }
    const result = try root.child_process.run(alloc, dir, .ignore, .pipe, .pipe, 1024 * 1024 * 1024, &.{ "git", "format-patch", "--stdout", "--full-index", "--patience", parentid.?.id ++ "..." ++ commitid.id });
    if (!(result.term == .exited and result.term.exited == 0)) std.log.err("{s}", .{result.stderr});
    std.debug.assert(result.term == .exited and result.term.exited == 0);
    return result.stdout;
}

// TODO make this inspect .git manually
// TODO make this return a Reader when we implement it ourselves
pub fn getTreeDiffPath(alloc: std.mem.Allocator, dir: nfs.Dir, commitid: CommitId, parentid: ?CommitId, path: []const u8) !string {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    if (parentid == null) {
        // 4b825dc642cb6eb9a060e54bf8d69288fbee4904 is a hardcode for the empty tree in git sha1
        // result of `printf | git hash-object -t tree --stdin`
        const result = try root.child_process.run(alloc, dir, .ignore, .pipe, .pipe, 1024 * 1024 * 1024, &.{ "git", "diff-tree", "-p", "--raw", "--full-index", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", commitid.id, "--", path });
        std.debug.assert(result.term == .exited and result.term.exited == 0);
        return std.mem.trim(u8, result.stdout, "\n");
    }
    const result = try root.child_process.run(alloc, dir, .ignore, .pipe, .pipe, 1024 * 1024 * 1024, &.{ "git", "diff-tree", "-p", "--raw", "--full-index", parentid.?.id, commitid.id, "--", path });
    std.debug.assert(result.term == .exited and result.term.exited == 0);
    return std.mem.trim(u8, result.stdout, "\n");
}

pub fn parseTreeDiff(alloc: std.mem.Allocator, input: string) !TreeDiff {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var lineiter = std.mem.splitScalar(u8, input, '\n');
    var overview = std.array_list.Managed(TreeDiff.StateLine).init(alloc);
    var diffs = std.array_list.Managed(TreeDiff.Diff).init(alloc);
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

        var kter = std.mem.splitScalar(u8, jter.rest(), '\t');
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
            .index = @splat(.{ .id = "0000000000000000000000000000000000000000" }),
            .before_path = overview.items[i].sub_path,
            .after_path = overview.items[i].sub_path,
            .before_mode = overview.items[i].before.mode,
            .after_mode = overview.items[i].after.mode,
            .subs = 0,
            .adds = 0,
            .content = "",
        });
        const diff = &diffs.items[diffs.items.len - 1];
        if (overview.items[i].action == .T) diff.before_mode = .none;
        if (overview.items[i].action == .T) diff.after_mode = .none;

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
                if (extras.trimPrefixEnsure(lin, "new file mode ")) |sl| {
                    diff.after_mode = parseTreeMode(sl) catch unreachable;
                    lineiter.index.? += lin.len + 1;
                    continue;
                }
                if (extras.trimPrefixEnsure(lin, "deleted file mode ")) |sl| {
                    diff.before_mode = parseTreeMode(sl) catch unreachable;
                    lineiter.index.? += lin.len + 1;
                    continue;
                }
                if (extras.trimPrefixEnsure(lin, "old mode ")) |sl| {
                    diff.before_mode = parseTreeMode(sl) catch unreachable;
                    lineiter.index.? += lin.len + 1;
                    continue;
                }
                if (extras.trimPrefixEnsure(lin, "new mode ")) |sl| {
                    diff.after_mode = parseTreeMode(sl) catch unreachable;
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
        before_mode: Tree.Object.Mode,
        after_mode: Tree.Object.Mode,
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

pub fn parseTag(tagfile: string) !Tag {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var iter = std.mem.splitScalar(u8, tagfile, '\n');
    var result: Tag = .{
        .raw = tagfile,
        .object = undefined,
        .type = undefined,
        .tagger = null,
        .gpgsig = "",
        .message = undefined,
    };
    const object = extras.trimPrefixEnsure(iter.next().?, "object ").?;
    std.debug.assert(object.len == 40);
    result.object = object[0..40];
    const ty = extras.trimPrefixEnsure(iter.next().?, "type ").?;
    result.type = std.meta.stringToEnum(RefType, ty).?;
    const tag = extras.trimPrefixEnsure(iter.next().?, "tag ").?;
    _ = tag;
    var f_start: usize = 0;
    while (true) {
        const line_start = iter.index.?;
        const line = iter.next() orelse break;
        if (line.len == 0) break;
        const space = std.mem.indexOfScalar(u8, line, ' ').?;
        const k = line[0..space];
        if (std.mem.eql(u8, k, "tagger")) result.tagger = try parseCommitUserAndAt(line[space + 1 ..]);
        if (std.mem.eql(u8, k, "gpgsig")) {
            f_start = line_start + 7;
            _ = iter.next().?;
            while (true) {
                const line2_start = iter.index.?;
                const line2 = iter.next() orelse break;
                if (line2.len == 0 or line2[0] != ' ') {
                    iter.index = line2_start;
                    break;
                }
            }
            result.gpgsig = tagfile[f_start .. iter.index.? - 1];
        }
    }
    result.message = iter.rest();
    return result;
}

// TODO make this inspect .git/objects
pub fn getBlame(alloc: std.mem.Allocator, dir: nfs.Dir, at: CommitId, sub_path: string) !string {
    const t = tracer.trace(@src(), " {s} -- {s}", .{ at.id, sub_path });
    defer t.end();

    const result = try root.child_process.run(alloc, dir, .ignore, .pipe, .pipe, 1024 * 1024 * 1024, &.{ "git", "blame", "-p", at.id, "--", sub_path });
    extras.assertLog(result.term == .exited and result.term.exited == 0, "{s}", .{result.stderr});
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
    unpacked_loose_objects: std.StringArrayHashMapUnmanaged(GitObject),
    unpacked_objects: std.AutoArrayHashMapUnmanaged(u64, GitObject),
    unpacked_objects_window: usize,
    idx_content: std.StringArrayHashMapUnmanaged([]const u8),
    pack_content: std.StringArrayHashMapUnmanaged([]const u8),
    commits: std.StringArrayHashMapUnmanaged(*Commit),
    trees: std.StringArrayHashMapUnmanaged(*Tree),
    tags: std.StringArrayHashMapUnmanaged(*Tag),
    mailmap_content: []const u8,
    mailmap: std.hash_map.StringHashMapUnmanaged([]const u8),
    mailmap_names: std.hash_map.StringHashMapUnmanaged([]const u8),

    pub const CacheBehavior = enum { no_cache, cache };

    pub fn init(gitdir: nfs.Dir, gpa: std.mem.Allocator) Repository {
        return .{
            .gitdir = gitdir,
            .gpa = gpa,
            .unpacked_loose_objects = .empty,
            .unpacked_objects = .empty,
            .unpacked_objects_window = 0,
            .idx_content = .empty,
            .pack_content = .empty,
            .commits = .empty,
            .trees = .empty,
            .tags = .empty,
            .mailmap_content = "",
            .mailmap = .empty,
            .mailmap_names = .empty,
        };
    }

    pub fn deinit(r: *Repository) void {
        for (r.unpacked_loose_objects.values()) |v| r.gpa.free(v.content);
        r.unpacked_loose_objects.deinit(r.gpa);
        for (r.unpacked_objects.values()) |v| r.gpa.free(v.content);
        r.unpacked_objects.deinit(r.gpa);
        for (r.idx_content.keys()) |k| r.gpa.free(k);
        for (r.idx_content.values()) |v| nfs.munmap(v);
        r.idx_content.deinit(r.gpa);
        for (r.pack_content.values()) |v| nfs.munmap(v);
        r.pack_content.deinit(r.gpa);
        for (r.commits.values()) |v| v.destroy(r);
        r.commits.deinit(r.gpa);
        for (r.trees.values()) |v| v.destroy(r);
        r.trees.deinit(r.gpa);
        for (r.tags.values()) |v| v.destroy(r);
        r.tags.deinit(r.gpa);
        r.mailmap.deinit(r.gpa);
        r.mailmap_names.deinit(r.gpa);
    }

    pub fn initMailmap(r: *Repository) !void {
        const headid = try getHEAD(r.gpa, r.gitdir) orelse return;
        const head = try r.getCommitA(headid.id, .cache);
        const tree = try r.getTreeA(head.tree.id, .cache);
        const blob = tree.get(".mailmap") orelse return;
        if (blob.id != .blob) return;
        const mailmap_content = try r.getBlobA(blob.id.blob.id, .cache);

        var mailmap: std.hash_map.StringHashMapUnmanaged([]const u8) = .empty;
        var mailmap_names: std.hash_map.StringHashMapUnmanaged([]const u8) = .empty;
        if (mailmap_content.len > 0) {
            var iter = std.mem.splitScalar(u8, mailmap_content, '\n');
            while (iter.next()) |line| {
                if (std.mem.startsWith(u8, line, "#")) continue;
                var jter = std.mem.splitScalar(u8, line, '<');
                const name = std.mem.trim(u8, jter.next().?, " ");
                var first: ?[]const u8 = null;
                while (jter.next()) |fntry| {
                    const email = fntry[0 .. std.mem.indexOfScalar(u8, fntry, '>') orelse continue];
                    if (first == null) {
                        first = email;
                        try mailmap_names.put(r.gpa, email, name);
                        continue;
                    }
                    try mailmap.put(r.gpa, email, first.?);
                }
            }
        }
        r.mailmap_content = mailmap_content;
        r.mailmap = mailmap;
        r.mailmap_names = mailmap_names;
    }

    pub fn getObject(r: *Repository, oid: Id, cache_behavior: CacheBehavior) anyerror!?GitObject {
        const t = tracer.trace(@src(), " {s}", .{oid});
        defer t.end();

        if (cache_behavior == .cache) if (r.unpacked_loose_objects.get(oid)) |obj| {
            return obj;
        };
        if (oid.len == 40) blk: { //sha1 object
            var sub_path: [49:0]u8 = "objects/00/00000000000000000000000000000000000000".*;
            @memcpy(sub_path[8..][0..2], oid[0..2]);
            @memcpy(sub_path[11..], oid[2..]);
            const objfile = r.gitdir.openFile(&sub_path, .{}) catch |err| switch (err) {
                error.ENOENT => break :blk,
                else => |e| return e,
            };
            defer objfile.close();
            const compressed_content = try objfile.mmap();
            defer nfs.munmap(compressed_content);
            var list: nio.AllocatingWriter = .init(r.gpa);
            errdefer list.deinit();
            try list.ensureUnusedCapacity(512);
            try inflate_decompress(compressed_content, &list);
            const data = list.items;
            const header = data[0..std.mem.indexOfScalar(u8, data, 0).?];
            const _type_s = header[0..std.mem.indexOfScalar(u8, header, ' ').?];
            const _type = std.meta.stringToEnum(RefType, _type_s).?;
            const content_len = try extras.parseDigits(u64, header[_type_s.len + 1 ..], 10);
            list.replaceRangeAssumeCapacity(0, header.len + 1, "");
            const content = try list.toOwnedSlice();
            std.debug.assert(content.len == content_len);
            const obj: GitObject = .{ .type = _type, .content = content };
            if (cache_behavior == .cache) try r.unpacked_loose_objects.put(r.gpa, oid, obj);
            return obj;
        }

        // read .idx
        if (r.idx_content.count() == 0) {
            const t2 = tracer.trace(@src(), " read objects/pack", .{});
            defer t2.end();
            const packdir = try r.gitdir.openDir("objects/pack", .{});
            defer packdir.close();
            var iter = packdir.iterate();
            while (try iter.next()) |entry| {
                const t3 = tracer.trace(@src(), " {s}", .{entry.name});
                defer t3.end();
                if (entry.type != .REG) continue;
                if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
                // std.log.debug("packdir iterate: {s}", .{entry.name});

                const idx_file = try packdir.openFile(entry.name, .{});
                defer idx_file.close();
                const idx_content = try idx_file.mmap();
                errdefer nfs.munmap(idx_content);
                try r.idx_content.put(
                    r.gpa,
                    try r.gpa.dupe(u8, entry.name),
                    idx_content,
                );
            }
        }
        const pack_index, const pack_offset = try r.getObjectPackIndex(oid) orelse return null;
        // parse .pack
        return try r.getPackedObject(pack_index, pack_offset, cache_behavior);
    }

    fn getObjectPackIndex(r: *Repository, oid: Id) !?[2]usize {
        const t = tracer.trace(@src(), " {s}", .{oid});
        defer t.end();

        for (r.idx_content.keys(), r.idx_content.values()) |idx_path, idx_content| {
            if (std.mem.startsWith(u8, idx_content, "\xfftOc")) {
                var idx_fbs: nio.FixedBufferStream([]const u8) = .init(idx_content);
                _ = idx_fbs.takeSlice(4);
                std.debug.assert(idx_fbs.takeInt(u32, .big) == 2);
                const fanout_be_bytes = idx_fbs.takeSlice(255 * 4);
                _ = fanout_be_bytes;
                const object_count = idx_fbs.takeInt(u32, .big);
                const name_bytes = idx_fbs.takeSlice(object_count * 20);
                const crc32_bytes = idx_fbs.takeSlice(object_count * 4);
                _ = crc32_bytes;
                const offsets_be = idx_fbs.takeIntSlice(u32, object_count);
                const largeoffsets_be: []align(1) const u64 = @ptrCast(idx_fbs.rest());

                // std.sort.binarySearch;
                const i = bll: {
                    var low: usize = 0;
                    var high: usize = object_count;
                    while (low < high) {
                        const mid = low + (high - low) / 2;
                        const object_id = &extras.to_hex(name_bytes[mid * 20 ..][0..20].*);
                        switch (std.mem.order(u8, oid, object_id)) {
                            .eq => break :bll mid,
                            .gt => low = mid + 1,
                            .lt => high = mid,
                        }
                    }
                    continue;
                };

                const pack_offset_candidate = @byteSwap(offsets_be[i]);
                const pack_offset = if (pack_offset_candidate & 0x80000000 == 0) pack_offset_candidate else @byteSwap(largeoffsets_be[pack_offset_candidate & 0x7fffffff]);
                // std.log.debug("found {s} in {s} at offset {d} {d}", .{ oid, idx_path, pack_offset_candidate, pack_offset });

                const pack_index = r.pack_content.getIndex(idx_path) orelse clk: {
                    var pack_path: [128]u8 = @splat(0);
                    @memcpy(pack_path[0..13], "objects/pack/");
                    @memcpy(pack_path[13..][0..idx_path.len], idx_path);
                    @memcpy(pack_path[13..][idx_path.len - 4 ..][0..5], ".pack");
                    const pack_name_nidx = std.mem.indexOfScalar(u8, &pack_path, 0).?;
                    const pack_name = pack_path[0..pack_name_nidx :0];
                    const pack_file = try r.gitdir.openFile(pack_name, .{});
                    defer pack_file.close();
                    const pack_content = try pack_file.mmap();
                    errdefer nfs.munmap(pack_content);
                    try r.pack_content.put(r.gpa, idx_path, pack_content);
                    break :clk r.pack_content.count() - 1;
                };
                return .{ pack_index, pack_offset };
            }
            return error.UnexpectedIdxVersion;
        }
        return null;
    }

    fn getPackedObject(r: *Repository, pack_index: usize, pack_offset: usize, cache_behavior: CacheBehavior) !GitObject {
        const t = tracer.trace(@src(), " {d} {d} {s}", .{ pack_index, pack_offset, r.pack_content.keys()[pack_index] });
        defer t.end();

        const key = std.hash.Wyhash.hash(0, &(std.mem.toBytes(pack_index) ++ std.mem.toBytes(pack_offset)));
        if (cache_behavior == .cache) if (r.unpacked_objects.get(key)) |o| return o;

        const pack_content = r.pack_content.values()[pack_index];
        if (!std.mem.eql(u8, pack_content[0..4], "PACK")) return error.InvalidGitPack;
        const pack_version = std.mem.readInt(u32, pack_content[4..][0..4], .big);
        switch (pack_version) {
            2 => {
                const packedobj_content = pack_content[pack_offset..];
                var packedobj_fbs = nio.FixedBufferStream([]const u8).init(packedobj_content);
                const PackedObjType = enum(u3) { none, commit, tree, blob, tag, reserved, ofs_delta, ref_delta };
                var c: usize = packedobj_fbs.takeArray(1)[0];
                const ty: PackedObjType = @enumFromInt((c >> 4) & 7);
                var size: usize = c & 15;
                var shift: u6 = 4;
                while (c & 0x80 > 0) {
                    c = packedobj_fbs.takeArray(1)[0];
                    size += (c & 0x7f) << shift;
                    shift += 7;
                }
                // std.log.debug("pack_index={d} pack_offset={d} type={s} size={d}", .{ pack_index, pack_offset, @tagName(ty), size });
                const t2 = tracer.trace(@src(), " 2 {s} {d}", .{ @tagName(ty), size });
                defer t2.end();
                switch (ty) {
                    .none => {
                        unreachable;
                    },
                    .reserved => {
                        unreachable;
                    },
                    .commit, .tree, .blob, .tag => {
                        const compressed_content = packedobj_fbs.rest();
                        var list: nio.AllocatingWriter = .init(r.gpa);
                        errdefer list.deinit();
                        try list.ensureUnusedCapacity(512);
                        try inflate_decompress(compressed_content, &list);
                        const _type = std.meta.stringToEnum(RefType, @tagName(ty)).?;
                        const content = try list.toOwnedSlice();
                        const obj: GitObject = .{ .type = _type, .content = content };
                        const window_max = 1024 * 128;
                        if (cache_behavior == .cache) {
                            if (r.unpacked_objects.count() < window_max) {
                                try r.unpacked_objects.put(r.gpa, key, obj);
                            } else {
                                const item = &r.unpacked_objects.values()[r.unpacked_objects_window];
                                r.gpa.free(item.content);
                                r.unpacked_objects.keys()[r.unpacked_objects_window] = key;
                                item.* = obj;
                            }
                            r.unpacked_objects_window += 1;
                            r.unpacked_objects_window %= window_max;
                        }
                        return obj;
                    },
                    .ofs_delta => {
                        var offset: usize = 0;
                        while (true) {
                            const c2: usize = packedobj_fbs.takeArray(1)[0];
                            offset = (offset << 7) | (c2 & 0x7f);
                            if (c2 & 0x80 == 0) break;
                            offset += 1;
                        }
                        const base_pack_offset = pack_offset - offset;
                        const base_obj = try r.getPackedObject(pack_index, base_pack_offset, cache_behavior);
                        defer if (cache_behavior == .no_cache) r.gpa.free(base_obj.content);
                        return r.getDeltadObject(key, &packedobj_fbs, size, base_obj, cache_behavior);
                    },
                    .ref_delta => {
                        const base_oid = extras.to_hex(packedobj_fbs.takeSlice(20)[0..20].*);
                        const base_obj = (try r.getObject(&base_oid, cache_behavior)).?;
                        defer if (cache_behavior == .no_cache) r.gpa.free(base_obj.content);
                        return r.getDeltadObject(key, &packedobj_fbs, size, base_obj, cache_behavior);
                    },
                }
                comptime unreachable;
            },
            3 => {
                return error.ReservedPackVersion;
            },
            else => return error.InvalidGitPack,
        }
    }

    fn getDeltadObject(r: *Repository, key: u64, packedobj_fbs: *nio.FixedBufferStream([]const u8), size: usize, base_obj: GitObject, cache_behavior: CacheBehavior) !GitObject {
        const compressed_content = packedobj_fbs.rest();
        var list: nio.AllocatingWriter = .init(r.gpa);
        defer list.deinit();
        try list.ensureUnusedCapacity(size);
        try inflate_decompress(compressed_content, &list);
        std.debug.assert(list.items.len == size);
        // std.log.debug("maybe_oid={?s} size={d}", .{ maybe_oid, size });
        // std.log.debug("transformation data=[{d}]{d}", .{ list.items.len, list.items });

        var unpackedobj_fbs = nio.FixedBufferStream([]const u8).init(list.items);

        var list2: std.ArrayListUnmanaged(u8) = .empty;
        errdefer list2.deinit(r.gpa);

        var base_size: usize = 0;
        while (true) {
            const c2: usize = unpackedobj_fbs.takeArray(1)[0];
            base_size = (base_size << 7) | (c2 & 0x7f);
            if (c2 & 0x80 == 0) break;
            base_size += 1;
        }
        // std.log.debug("base_size={d}", .{base_size});

        var obj_size: usize = 0;
        while (true) {
            const c2: usize = unpackedobj_fbs.takeArray(1)[0];
            obj_size = (obj_size << 7) | (c2 & 0x7f);
            if (c2 & 0x80 == 0) break;
            obj_size += 1;
        }
        // std.log.debug("obj_size={d}", .{obj_size});

        while (unpackedobj_fbs.pos < unpackedobj_fbs.buffer.len) {
            const c2 = unpackedobj_fbs.takeArray(1)[0];
            if (c2 & 0x80 > 0) {
                // copy range from base
                var b: extras.RingBuffer(u8, 7) = .{};
                for (0..7) |i| {
                    const mask = @as(u8, 1) << @intCast(i);
                    b.append(if (c2 & mask > 0) unpackedobj_fbs.takeArray(1)[0] else 0);
                }
                const start: u32 = @bitCast(b.items[0..4].*);
                var nbytes: u24 = @bitCast(b.items[4..7].*);
                if (nbytes == 0) nbytes = 0x10000;
                // std.log.debug("- copy from base: start={d} nbytes={d}", .{ start, nbytes });
                // std.log.debug("  - {d} {d}", .{ c2, b.items });
                const bytes = base_obj.content[start..][0..nbytes];
                // std.log.debug("{s}\n", .{bytes});
                try list2.appendSlice(r.gpa, bytes);
            } else {
                // append new data
                const nbytes = c2 & 0x7f;
                // std.log.debug("- append new bytes={d}", .{nbytes});
                if (nbytes == 0) continue;
                const bytes = unpackedobj_fbs.takeSlice(nbytes);
                // std.log.debug("{s}\n", .{bytes});
                try list2.appendSlice(r.gpa, bytes);
            }
        }

        // std.log.debug("- done {d}", .{list2.items.len});
        // std.log.debug("{s}\n", .{list2.items});
        const _type = base_obj.type;
        const content = try list2.toOwnedSlice(r.gpa);
        const obj: GitObject = .{ .type = _type, .content = content };
        const window_max = 1024 * 128;
        if (cache_behavior == .cache) {
            if (r.unpacked_objects.count() < window_max) {
                try r.unpacked_objects.put(r.gpa, key, obj);
            } else {
                const item = &r.unpacked_objects.values()[r.unpacked_objects_window];
                r.gpa.free(item.content);
                r.unpacked_objects.keys()[r.unpacked_objects_window] = key;
                item.* = obj;
            }
            r.unpacked_objects_window += 1;
            r.unpacked_objects_window %= window_max;
        }
        return obj;
    }

    pub fn getObjectA(r: *Repository, oid: Id, cache_behavior: CacheBehavior) !GitObject {
        return (try r.getObject(oid, cache_behavior)).?;
    }

    pub fn getObjectC(r: *Repository, oid: Id, cache_behavior: CacheBehavior) ![]const u8 {
        return (try r.getObjectA(oid, cache_behavior)).content;
    }

    pub fn getObjectS(r: *Repository, oid: Id, cache_behavior: CacheBehavior) !usize {
        const content = try r.getObjectC(oid, cache_behavior);
        defer if (cache_behavior == .no_cache) r.gpa.free(content);
        return content.len;
    }

    const GitObject = struct {
        type: RefType,
        content: []const u8,
    };

    pub fn getBlob(r: *Repository, id: BlobId, cache_behavior: CacheBehavior) !?[]const u8 {
        if (try r.getObject(id.id, cache_behavior)) |obj| {
            if (obj.type == .blob) {
                if (cache_behavior == .cache) return try r.gpa.dupe(u8, obj.content);
                return obj.content;
            }
        }
        return null;
    }

    pub fn getBlobA(r: *Repository, id: Id, cache_behavior: CacheBehavior) ![]const u8 {
        return (try r.getBlob(.{ .id = id }, cache_behavior)).?;
    }

    pub fn getCommit(r: *Repository, id: CommitId, cache_behavior: CacheBehavior) !?struct { CommitId, *Commit } {
        const t = tracer.trace(@src(), " {s}", .{id.id});
        defer t.end();

        if (cache_behavior == .cache) if (r.commits.get(id.id)) |val| {
            return .{ id, val };
        };
        if (try r.getObject(id.id, .no_cache)) |obj| {
            if (obj.type == .commit) {
                const raw = obj.content;
                errdefer r.gpa.free(raw);
                const commit = try r.gpa.create(Commit);
                errdefer r.gpa.destroy(commit);
                commit.* = try parseCommit(r.gpa, raw, &r.mailmap, &r.mailmap_names);
                if (cache_behavior == .cache) try r.commits.put(r.gpa, id.id, commit);
                return .{ id, commit };
            }
            r.gpa.free(obj.content);
        }
        return null;
    }

    pub fn getCommitA(r: *Repository, id: Id, cache_behavior: CacheBehavior) !*Commit {
        return (try r.getCommit(.{ .id = id }, cache_behavior)).?.@"1";
    }

    pub fn getTree(r: *Repository, id: TreeId, cache_behavior: CacheBehavior) !?struct { TreeId, *Tree } {
        const t = tracer.trace(@src(), " {s}", .{id.id});
        defer t.end();

        if (cache_behavior == .cache) if (r.trees.get(id.id)) |val| {
            return .{ id, val };
        };
        if (try r.getObject(id.id, .cache)) |obj| {
            if (obj.type == .tree) {
                const raw = try r.gpa.dupe(u8, obj.content);
                errdefer r.gpa.free(raw);
                var children: std.ArrayList(Tree.Object) = .empty;
                errdefer children.deinit(r.gpa);
                try children.ensureUnusedCapacity(r.gpa, 33);
                var i: usize = 0;
                while (i < raw.len) {
                    const mode_end = std.mem.indexOfScalar(u8, raw[i..], ' ').?;
                    const mode = raw[i..][0..mode_end];
                    i += mode_end + 1;

                    const name_end = std.mem.indexOfScalar(u8, raw[i..], 0).?;
                    const name = raw[i..][0..name_end :0];
                    i += name_end + 1;

                    const oid_raw = raw[i..][0..20].*;
                    const oid_hex = extras.to_hex(oid_raw);
                    i += 20;

                    var mode_buf: [6]u8 = @splat('0');
                    @memcpy(mode_buf[6 - mode.len ..], mode);
                    const mode_real = try parseTreeMode(&mode_buf);

                    try children.append(r.gpa, .{
                        .mode = mode_real,
                        .name = name,
                        .id_bytes = oid_hex,
                        .id = undefined,
                    });
                }

                const children_slice = try children.toOwnedSlice(r.gpa);
                errdefer r.gpa.free(children_slice);
                for (children_slice) |*item| item.id = switch (item.mode.type) {
                    .file => .{ .blob = .{ .id = &item.id_bytes } },
                    .directory => .{ .tree = .{ .id = &item.id_bytes } },
                    .submodule => .{ .commit = .{ .id = &item.id_bytes } },
                    .symlink => .{ .blob = .{ .id = &item.id_bytes } },
                    .none => unreachable,
                };
                const tree = try r.gpa.create(Tree);
                errdefer r.gpa.destroy(tree);
                tree.* = .{ .raw = raw, .children = children_slice };
                if (cache_behavior == .cache) try r.trees.put(r.gpa, id.id, tree);
                return .{ id, tree };
            }
        }
        return null;
    }

    pub fn getTreeA(r: *Repository, id: Id, cache_behavior: CacheBehavior) !*Tree {
        return (try r.getTree(.{ .id = id }, cache_behavior)).?.@"1";
    }

    pub fn getTag(r: *Repository, id: TagId, cache_behavior: CacheBehavior) !?struct { TagId, *Tag } {
        const t = tracer.trace(@src(), " {s}", .{id.id});
        defer t.end();

        if (cache_behavior == .cache) if (r.tags.get(id.id)) |val| {
            return .{ id, val };
        };
        if (try r.getObject(id.id, .cache)) |obj| {
            if (obj.type == .tag) {
                const raw = try r.gpa.dupe(u8, obj.content);
                errdefer r.gpa.free(raw);
                const tag = try r.gpa.create(Tag);
                errdefer r.gpa.destroy(tag);
                tag.* = try parseTag(raw);
                if (cache_behavior == .cache) try r.tags.put(r.gpa, id.id, tag);
                return .{ id, tag };
            }
        }
        return null;
    }

    pub fn getTagA(r: *Repository, id: Id, cache_behavior: CacheBehavior) !*Tag {
        return (try r.getTag(.{ .id = id }, cache_behavior)).?.@"1";
    }

    pub fn getHeads(r: *Repository, arena: std.mem.Allocator) ![]Ref {
        const t = tracer.trace(@src(), "", .{});
        defer t.end();

        const refs = try r.getRefs(arena, "heads");
        for (refs) |*e| e.commit = e.oid;
        return refs;
    }

    pub fn getTags(r: *Repository, arena: std.mem.Allocator) ![]Ref {
        const t = tracer.trace(@src(), "", .{});
        defer t.end();

        return r.getRefs(arena, "tags");
    }

    pub fn getRefs(r: *Repository, arena: std.mem.Allocator, comptime kind: [:0]const u8) ![]Ref {
        const t = tracer.trace(@src(), "", .{});
        defer t.end();

        var map: std.StringArrayHashMapUnmanaged(struct { Id, ?Id }) = .empty;
        try r.addPackedRefs(&map, arena, kind);
        try r.addDirRefs(&map, arena, kind);
        var list: std.ArrayListUnmanaged(Ref) = .empty;
        try list.ensureUnusedCapacity(arena, map.count());
        for (map.keys(), map.values()) |label, vals| list.appendAssumeCapacity(.{ .label = label, .oid = vals[0], .commit = vals[1] });
        return list.items;
    }

    fn addPackedRefs(r: *Repository, map: *std.StringArrayHashMapUnmanaged(struct { Id, ?Id }), arena: std.mem.Allocator, comptime kind: [:0]const u8) !void {
        const t = tracer.trace(@src(), "", .{});
        defer t.end();

        var file = r.gitdir.openFile("packed-refs", .{}) catch |err| switch (err) {
            error.ENOENT => return,
            else => |e| return e,
        };
        defer file.close();
        const content = try file.mmap();
        defer nfs.munmap(content);
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) break;
            if (line[0] == '#') continue;
            if (line[0] == '^') {
                map.values()[map.count() - 1][1] = ensureObjId(CommitId, try arena.dupe(u8, line[1..])).id;
                continue;
            }
            std.debug.assert(extras.matchesAll(u8, line[0..40], std.ascii.isHex));
            std.debug.assert(line[40] == ' ');
            const rest = extras.trimPrefixEnsure(line[41..], "refs/" ++ kind ++ "/") orelse continue;
            const oid = try arena.dupe(u8, line[0..40]);
            const label = try arena.dupeZ(u8, rest);
            try map.put(arena, label, .{ oid[0..40], null });
        }
    }

    fn addDirRefs(r: *Repository, map: *std.StringArrayHashMapUnmanaged(struct { Id, ?Id }), arena: std.mem.Allocator, comptime kind: [:0]const u8) !void {
        const t = tracer.trace(@src(), "", .{});
        defer t.end();

        var dir = try r.gitdir.openDir("refs/" ++ kind, .{});
        defer dir.close();
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.type != .REG) continue;
            var file = try dir.openFile(entry.path, .{});
            defer file.close();
            const label = try arena.dupeZ(u8, entry.path);
            const oid = try file.readAlloc(arena, 40);
            try map.put(arena, label, .{ oid[0..40], null });
        }
    }

    pub fn getTreeCommits(r: *Repository, arena: std.mem.Allocator, base_oid: CommitId, dir_path: []const u8) ![]const CommitId {
        const t = tracer.trace(@src(), "", .{});
        defer t.end();

        // const start = time.milliTimestamp();

        const base = try r.getCommitA(base_oid.id, .no_cache);
        const base_tree_id, const base_tree_id_parent = try traverseTo(r, base.tree, dir_path);
        defer if (base_tree_id_parent) |p| p.destroy(r);
        const base_tree = try r.getTreeA(base_tree_id.?.id, .cache);
        const total = base_tree.children.len;

        var found: usize = 0;
        var result: std.StringArrayHashMapUnmanaged(CommitId) = .empty;
        defer result.deinit(r.gpa);
        for (base_tree.children) |obj| try result.put(r.gpa, obj.name, undefined);

        var set: std.bit_set.DynamicBitSetUnmanaged = try .initEmpty(r.gpa, total);
        defer set.deinit(r.gpa);

        var searched: usize = 1;
        var commit_id_prev = base_oid;
        var commit_id = base_oid;
        var commit_prev_prev: ?*Commit = null;
        var commit_prev: ?*Commit = null;
        var commit = base;
        var tree_id = base_tree_id.?;
        while (true) : ({
            if (commit_prev_prev) |p| p.destroy(r);
            commit_prev_prev = commit_prev;
            commit_prev = commit;
            commit_id_prev = commit_id;
            commit_id, commit = (try r.getCommit(commit.parents[0], .no_cache)).?;
        }) {
            searched += 1;
            if (commit.parents.len == 0) break;
            const new_tree_id, const new_tree_id_parent = try traverseTo(r, commit.tree, dir_path);
            defer if (new_tree_id_parent) |p| p.destroy(r);
            if (new_tree_id == null) {
                var i: usize = 0;
                while (findFirstUnset(set, i)) |j| : (i += 1) {
                    i = j;
                    const k = result.keys()[i];
                    found += 1;
                    result.putAssumeCapacity(k, .{ .id = (try r.gpa.dupe(u8, commit_id_prev.id))[0..40] });
                    set.set(i);
                    // std.log.debug("found [{d}/{d}] objects after searching {d} commits, found {s}", .{ found, total, searched, k });
                    continue;
                }
                break;
            }
            if (new_tree_id.?.eql(tree_id)) continue;
            tree_id = new_tree_id.?;
            const tree = try r.getTreeA(tree_id.id, .no_cache);
            defer tree.destroy(r);
            var i: usize = 0;
            while (findFirstUnset(set, i)) |j| : (i += 1) {
                i = j;
                const k = result.keys()[i];
                const new = tree.get(k);
                if (new == null) {
                    found += 1;
                    result.putAssumeCapacity(k, .{ .id = (try r.gpa.dupe(u8, commit_id_prev.id))[0..40] });
                    set.set(i);
                    // std.log.debug("found [{d}/{d}] objects after searching {d} commits, at {d} found {s}", .{ found, total, searched, i, k });
                    continue;
                }
                if (!std.mem.eql(u8, new.?.id.erase(), base_tree.children[i].id.erase())) {
                    found += 1;
                    result.putAssumeCapacity(k, .{ .id = (try r.gpa.dupe(u8, commit_id_prev.id))[0..40] });
                    set.set(i);
                    // std.log.debug("found [{d}/{d}] objects after searching {d} commits, at {d} found {s}", .{ found, total, searched, i, k });
                    continue;
                }
            }
            if (set.count() == total) {
                break;
            }
        }
        for (0..total, result.values()) |i, *v| {
            if (!set.isSet(i)) {
                v.* = commit_id;
            }
        }

        // const end = time.milliTimestamp();
        // std.log.debug("found {d} in {d}ms", .{ total, end - start });

        return try arena.dupe(CommitId, result.values());
    }

    pub fn diffFileIterator(r: *Repository, writable: anytype, commitid_from: ?CommitId, commitid_to: CommitId, S: type) !void {
        const A = struct {
            fn item(e: *Repository, w: anytype, mode: Tree.Object.Mode, id: Id, p: ?*const PathListNode, name: []const u8) !void {
                try S.item(e, w, .none, mode, &@splat('0'), id, .A, p, name);
            }
            fn dir(e: *Repository, w: anytype, t: Id, p: ?*const PathListNode, o: usize) !void {
                const tree = try e.getTreeA(t, .cache);
                for (tree.children[o..]) |obj| {
                    if (obj.mode.type == .directory) {
                        try dir(e, w, obj.id.tree.id, &.{ .prev = p, .data = obj.name }, 0);
                        continue;
                    }
                    try item(e, w, obj.mode, obj.id.erase(), p, obj.name);
                }
            }
            pub fn either(e: *Repository, w: anytype, p: ?*const PathListNode, obj: Tree.Object) !void {
                if (obj.mode.type == .directory) {
                    return dir(e, w, obj.id.tree.id, &.{ .prev = p, .data = obj.name }, 0);
                }
                return item(e, w, obj.mode, obj.id.erase(), p, obj.name);
            }
        };
        const D = struct {
            fn item(e: *Repository, w: anytype, mode: Tree.Object.Mode, id: Id, p: ?*const PathListNode, name: []const u8) !void {
                try S.item(e, w, mode, .none, id, &@splat('0'), .D, p, name);
            }
            fn dir(e: *Repository, w: anytype, t: Id, p: ?*const PathListNode, o: usize) !void {
                const tree = try e.getTreeA(t, .cache);
                for (tree.children[o..]) |obj| {
                    if (obj.mode.type == .directory) {
                        try dir(e, w, obj.id.tree.id, &.{ .prev = p, .data = obj.name }, 0);
                        continue;
                    }
                    try item(e, w, obj.mode, obj.id.erase(), p, obj.name);
                }
            }
            pub fn either(e: *Repository, w: anytype, p: ?*const PathListNode, obj: Tree.Object) !void {
                if (obj.mode.type == .directory) {
                    return dir(e, w, obj.id.tree.id, &.{ .prev = p, .data = obj.name }, 0);
                }
                return item(e, w, obj.mode, obj.id.erase(), p, obj.name);
            }
        };
        const M = struct {
            fn dir(e: *Repository, w: anytype, b_t: Id, a_t: Id, p: ?*const PathListNode) !void {
                var before_i: usize = 0;
                const before_tree = try e.getTreeA(b_t, .cache);
                const before_children = before_tree.children;

                var after_i: usize = 0;
                const after_tree = try e.getTreeA(a_t, .cache);
                const after_children = after_tree.children;

                while (true) {
                    if (after_i == after_tree.children.len) {
                        try D.dir(e, w, b_t, p, before_i);
                        break;
                    }
                    if (before_i == before_tree.children.len) {
                        try A.dir(e, w, a_t, p, after_i);
                        break;
                    }

                    const before = before_children[before_i];
                    const after = after_children[after_i];

                    switch (before.order(after)) {
                        .eq => {
                            if (std.mem.eql(u8, before.id.erase(), after.id.erase())) {
                                if (!std.mem.eql(u8, &before.mode.intbytes(), &after.mode.intbytes())) {
                                    try S.item(
                                        e,
                                        w,
                                        before.mode,
                                        after.mode,
                                        before.id.erase(),
                                        after.id.erase(),
                                        .M,
                                        p,
                                        after.name,
                                    );
                                }
                                before_i += 1;
                                after_i += 1;
                                continue;
                            }
                            if (before.mode.type != after.mode.type) {
                                try S.item(
                                    e,
                                    w,
                                    before.mode,
                                    after.mode,
                                    before.id.erase(),
                                    after.id.erase(),
                                    .T,
                                    p,
                                    after.name,
                                );
                                before_i += 1;
                                after_i += 1;
                                continue;
                            }
                            if (before.mode.type == .directory) {
                                try dir(
                                    e,
                                    w,
                                    before.id.tree.id,
                                    after.id.tree.id,
                                    &.{ .prev = p, .data = after.name },
                                );
                                before_i += 1;
                                after_i += 1;
                                continue;
                            }
                            try S.item(
                                e,
                                w,
                                before.mode,
                                after.mode,
                                before.id.erase(),
                                after.id.erase(),
                                .M,
                                p,
                                after.name,
                            );
                            before_i += 1;
                            after_i += 1;
                            continue;
                        },
                        .lt => {
                            const after_item = after_tree.get(before.name) orelse {
                                try D.either(e, w, p, before);
                                before_i += 1;
                                continue;
                            };
                            const before_item = before_tree.get(after.name) orelse {
                                try A.either(e, w, p, after);
                                after_i += 1;
                                continue;
                            };
                            if (std.mem.eql(u8, &after_item.id_bytes, &before.id_bytes)) {
                                before_i += 1;
                                continue;
                            }
                            if (std.mem.eql(u8, &before_item.id_bytes, &after.id_bytes)) {
                                after_i += 1;
                                continue;
                            }
                            {
                                try D.either(e, w, p, before);
                                before_i += 1;
                                try A.either(e, w, p, after);
                                after_i += 1;
                                continue;
                            }
                            comptime unreachable;
                        },
                        .gt => {
                            const before_item = before_tree.get(after.name) orelse {
                                try A.either(e, w, p, after);
                                after_i += 1;
                                continue;
                            };
                            const after_item = after_tree.get(before.name) orelse {
                                try D.either(e, w, p, before);
                                before_i += 1;
                                continue;
                            };
                            if (std.mem.eql(u8, &before_item.id_bytes, &after.id_bytes)) {
                                after_i += 1;
                                continue;
                            }
                            if (std.mem.eql(u8, &after_item.id_bytes, &before.id_bytes)) {
                                before_i += 1;
                                continue;
                            }
                            {
                                try A.either(e, w, p, after);
                                before_i += 1;
                                try D.either(e, w, p, before);
                                after_i += 1;
                                continue;
                            }
                            comptime unreachable;
                        },
                    }
                    comptime unreachable;
                }
            }
        };
        if (commitid_from == null) {
            const commit = try r.getCommitA(commitid_to.id, .cache);
            try A.dir(r, writable, commit.tree.id, null, 0);
            return;
        }
        const before_commit = try r.getCommitA(commitid_from.?.id, .cache);
        const after_commit = try r.getCommitA(commitid_to.id, .cache);
        try M.dir(r, writable, before_commit.tree.id, after_commit.tree.id, null);
    }

    pub fn writeTreeDiffOnlyRaw(r: *Repository, writable: anytype, commitid: CommitId, parentid: ?CommitId) !void {
        const S = struct {
            fn item(e: *Repository, w: anytype, b_mode: Tree.Object.Mode, a_mode: Tree.Object.Mode, b_id: Id, a_id: Id, action: TreeDiff.Action, p: ?*const PathListNode, name: []const u8) !void {
                _ = e;
                if (p == null) {
                    try w.writevAll(&.{ ":", &b_mode.intbytes(), " ", &a_mode.intbytes(), " ", b_id, " ", a_id, " ", @tagName(action), "\t", name, "\n" });
                    return;
                }
                try w.writevAll(&.{ ":", &b_mode.intbytes(), " ", &a_mode.intbytes(), " ", b_id, " ", a_id, " ", @tagName(action), "\t" });
                try p.?.nprint(w);
                try w.writevAll(&.{ "/", name, "\n" });
            }
        };
        return diffFileIterator(r, writable, parentid, commitid, S);
    }

    pub fn writeTreeDiffOnlySummary(r: *Repository, writable: anytype, commitid: CommitId, parentid: ?CommitId) !void {
        const S = struct {
            fn item(e: *Repository, w: anytype, b_mode: Tree.Object.Mode, a_mode: Tree.Object.Mode, b_id: Id, a_id: Id, action: TreeDiff.Action, p: ?*const PathListNode, name: []const u8) !void {
                _ = e;
                _ = b_id;
                _ = a_id;
                switch (action) {
                    .A => {
                        if (p == null) {
                            try w.writevAll(&.{ " create mode ", &a_mode.intbytes(), " ", name, "\n" });
                            return;
                        }
                        try w.writevAll(&.{ " create mode ", &a_mode.intbytes(), " " });
                        try p.?.nprint(w);
                        try w.writevAll(&.{ "/", name, "\n" });
                    },
                    .D => {
                        if (p == null) {
                            try w.writevAll(&.{ " delete mode ", &b_mode.intbytes(), " ", name, "\n" });
                            return;
                        }
                        try w.writevAll(&.{ " delete mode ", &b_mode.intbytes(), " " });
                        try p.?.nprint(w);
                        try w.writevAll(&.{ "/", name, "\n" });
                    },
                    .M => {
                        if (!std.mem.eql(u8, &b_mode.intbytes(), &a_mode.intbytes())) {
                            if (p == null) {
                                try w.writevAll(&.{ " mode change ", &b_mode.intbytes(), " => ", &a_mode.intbytes(), " ", name, "\n" });
                                return;
                            }
                            try w.writevAll(&.{ " mode change ", &b_mode.intbytes(), " => ", &a_mode.intbytes(), " " });
                            try p.?.nprint(w);
                            try w.writevAll(&.{ "/", name, "\n" });
                        }
                    },
                    .T => {
                        if (p == null) {
                            try w.writevAll(&.{ " mode change ", &b_mode.intbytes(), " => ", &a_mode.intbytes(), " ", name, "\n" });
                            return;
                        }
                        try w.writevAll(&.{ " mode change ", &b_mode.intbytes(), " => ", &a_mode.intbytes(), " " });
                        try p.?.nprint(w);
                        try w.writevAll(&.{ "/", name, "\n" });
                    },
                    else => {},
                }
            }
        };
        return diffFileIterator(r, writable, parentid, commitid, S);
    }

    pub fn revListAll(r: *Repository, alloc: std.mem.Allocator, from: CommitId, sub_path: string) ![]const u8 {
        const t = tracer.trace(@src(), " {s} -- {s}", .{ from.id, sub_path });
        defer t.end();

        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(alloc);

        const base = try r.getCommitA(from.id, .no_cache);
        const base_tree = try r.getTreeA(base.tree.id, .no_cache);
        const base_obj, const base_id_parent = (try idFor(r, base_tree, sub_path)).?;

        var prev_prev_commit: ?*Commit = null;
        var prev_commit = base;
        var prev_tree: ?*Tree = base_id_parent;
        var prev_obj = try r.gpa.create(Tree.Object);
        prev_obj.* = base_obj.*;
        defer r.gpa.destroy(prev_obj);

        while (true) {
            if (prev_commit.parents.len == 0) {
                if (prev_tree != null) {
                    try list.appendSlice(alloc, (if (prev_prev_commit) |p| p.parents[0].id else from.id) ++ "\n");
                }
                break;
            }
            const next_commit = try r.getCommitA(prev_commit.parents[0].id, .no_cache);
            const next_commit_tree = try r.getTreeA(next_commit.tree.id, .no_cache);
            const next_obj, const next_tree = try idFor(r, next_commit_tree, sub_path) orelse {
                if (prev_tree == null) {
                    if (prev_prev_commit) |p| p.destroy(r);
                    prev_prev_commit = prev_commit;
                    prev_commit = next_commit;
                    prev_tree = null;
                    continue;
                }
                try list.appendSlice(alloc, (if (prev_prev_commit) |p| p.parents[0].id else from.id) ++ "\n");
                // break; // we don't pass --remove-empty
                if (prev_prev_commit) |p| p.destroy(r);
                prev_prev_commit = prev_commit;
                prev_commit = next_commit;
                prev_tree = null;
                continue;
            };
            if (prev_tree != null and std.mem.eql(u8, &next_obj.id_bytes, &prev_obj.id_bytes) and next_obj.mode.eql(prev_obj.mode)) {
                if (prev_prev_commit) |p| p.destroy(r);
                prev_prev_commit = prev_commit;
                prev_commit = next_commit;
                prev_tree = next_tree;
                continue;
            }
            try list.appendSlice(alloc, (if (prev_prev_commit) |p| p.parents[0].id else from.id) ++ "\n");
            if (prev_prev_commit) |p| p.destroy(r);
            prev_prev_commit = prev_commit;
            prev_commit = next_commit;
            prev_tree = next_tree;
            prev_obj.* = next_obj.*;
            continue;
        }

        return list.toOwnedSlice(alloc);
    }
};

const z = @cImport({
    @cInclude("zlib.h");
});

fn inflate_decompress(in: []const u8, out: *nio.AllocatingWriter) !void {
    // {
    //     var reader: std.Io.Reader = .fixed(in);
    //     var buf: [std.compress.flate.max_window_len]u8 = @splat(0);
    //     var d: std.compress.flate.Decompress = .init(&reader, .zlib, &buf);
    //     var w = out.anyWritable().toStd(&.{});
    //     _ = d.reader.streamRemaining(&w.sw) catch |err| switch (err) {
    //         error.ReadFailed => return d.err.?,
    //         error.WriteFailed => return error.OutOfMemory,
    //     };
    //     return;
    // }
    var strm: z.z_stream = std.mem.zeroes(z.z_stream);
    {
        const ret: ZlibCode = @enumFromInt(z.inflateInit(&strm));
        if (ret == .Z_MEM_ERROR) return error.OutOfMemory;
        std.debug.assert(ret != .Z_VERSION_ERROR);
        std.debug.assert(ret != .Z_STREAM_ERROR);
    }
    defer {
        const ret: ZlibCode = @enumFromInt(z.inflateEnd(&strm));
        std.debug.assert(ret != .Z_STREAM_ERROR);
        std.debug.assert(ret == .Z_OK);
    }
    // std.log.debug("inflate_decompress: -> {*} {d}", .{ in.ptr, in.len });
    strm.next_in = @constCast(in.ptr);
    strm.avail_in = @truncate(in.len);

    while (true) {
        var buf: [16384]u8 = @splat(0);
        strm.next_out = &buf;
        strm.avail_out = buf.len;
        // std.log.debug("inflate_decompress: -> {*} {*} {d} {d}", .{ strm.next_in, strm.next_out, strm.avail_in, strm.avail_out });
        const ret: ZlibCode = @enumFromInt(z.inflate(&strm, z.Z_SYNC_FLUSH));
        // std.log.debug("inflate_decompress: <- {*} {*} {d} {d} {s}", .{ strm.next_in, strm.next_out, strm.avail_in, strm.avail_out, @tagName(ret) });
        std.debug.assert(ret != .Z_STREAM_ERROR);
        std.debug.assert(ret != .Z_BUF_ERROR);
        if (ret == .Z_MEM_ERROR) return error.OutOfMemory;
        if (ret == .Z_DATA_ERROR) return error.Z_DATA_ERROR;
        if (ret == .Z_NEED_DICT) return error.Z_NEED_DICT;
        // Z_ERRNO
        // Z_VERSION_ERROR
        std.debug.assert(ret == .Z_OK or ret == .Z_STREAM_END);
        try out.writeAll(buf[0 .. buf.len - strm.avail_out]);
        if (ret == .Z_STREAM_END) break;
    }
}

const ZlibCode = enum(c_int) {
    Z_OK = 0,
    Z_STREAM_END = 1,
    Z_NEED_DICT = 2,
    Z_ERRNO = -1,
    Z_STREAM_ERROR = -2,
    Z_DATA_ERROR = -3,
    Z_MEM_ERROR = -4,
    Z_BUF_ERROR = -5,
    Z_VERSION_ERROR = -6,
};

fn traverseTo(r: *Repository, treestart_id: TreeId, dir_path: []const u8) !struct { ?TreeId, ?*Tree } {
    var id = treestart_id;
    if (dir_path.len == 0) return .{ id, null };
    var iter = std.mem.splitScalar(u8, dir_path, '/');
    var prev: ?*Tree = null;
    while (iter.next()) |segment| {
        const p = prev;
        const tree = try r.getTreeA(id.id, .no_cache);
        defer prev = tree;
        if (p) |_| p.?.destroy(r);
        const o = tree.get(segment) orelse return .{ null, tree };
        if (o.id != .tree) return .{ null, tree };
        id = o.id.tree;
    }
    return .{ id, prev };
}

pub const Tree = struct {
    raw: []const u8,
    children: []const Object,

    pub fn destroy(t: *Tree, r: *Repository) void {
        r.gpa.free(t.children);
        r.gpa.free(t.raw);
        r.gpa.destroy(t);
    }

    pub fn get(self: *Tree, name: string) ?*const Object {
        // modified std.sort.binarySearch
        const i = blk: {
            var low: usize = 0;
            var high: usize = self.children.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                switch (Object.search(name, self.children[mid])) {
                    .eq => break :blk mid,
                    .gt => low = mid + 1,
                    .lt => high = mid,
                }
            }
            for (self.children[low..], 0..) |item, i| {
                if (std.mem.startsWith(u8, item.name, name)) {
                    if (item.name[name.len..].len == 0) {
                        break :blk low + i;
                    }
                    if (std.math.order(item.name[name.len..][0], '/') == .gt) {
                        return null;
                    }
                    continue;
                }
                break;
            }
            return null;
        };
        return &self.children[i];
    }

    pub fn getBlob(self: *Tree, name: string, hint: Object.Type) ?*const Object {
        const o = self.get(name, hint) orelse return null;
        if (o.id != .blob) return null;
        return o;
    }

    pub fn find(self: *Tree, name: string) ?Object {
        for (self.children, 0..) |item, i| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) {
                return self.children[i];
            }
        }
        return null;
    }

    pub fn findBlob(self: *Tree, name: string) ?Object {
        const o = self.find(name) orelse return null;
        if (o.id != .blob) return null;
        return o;
    }

    pub const Object = struct {
        mode: Mode,
        id_bytes: [40]u8,
        id: AnyId,
        name: [:0]const u8,

        fn search(a: []const u8, b: Object) std.math.Order {
            if (a.ptr != b.name.ptr) {
                const n = @min(a.len, b.name.len);
                for (a[0..n], b.name[0..n]) |lhs_elem, rhs_elem| {
                    switch (std.math.order(lhs_elem, rhs_elem)) {
                        .eq => continue,
                        .lt => return .lt,
                        .gt => return .gt,
                    }
                }
            }
            return switch (std.math.order(a.len, b.name.len)) {
                .lt => .lt,
                .gt => if (b.mode.type == .directory) std.math.order(a[b.name.len], '/') else .gt,
                .eq => .eq,
            };
        }

        pub fn order(lhs: Object, rhs: Object) std.math.Order {
            if (lhs.name.ptr != rhs.name.ptr) {
                const n = @min(lhs.name.len, rhs.name.len);
                for (lhs.name[0..n], rhs.name[0..n]) |lhs_elem, rhs_elem| {
                    switch (std.math.order(lhs_elem, rhs_elem)) {
                        .eq => continue,
                        .lt => return .lt,
                        .gt => return .gt,
                    }
                }
            }
            const l_is_dir = lhs.mode.type == .directory;
            const r_is_dir = rhs.mode.type == .directory;
            return switch (std.math.order(lhs.name.len, rhs.name.len)) {
                .lt => if (l_is_dir) std.math.order('/', rhs.name[lhs.name.len]) else .lt,
                .gt => if (r_is_dir) std.math.order(lhs.name[rhs.name.len], '/') else .gt,
                .eq => if (l_is_dir and r_is_dir) .eq else if (l_is_dir) .gt else if (r_is_dir) .lt else .eq,
            };
        }

        pub const Mode = struct {
            type: Type,
            perm_user: Perm,
            perm_group: Perm,
            perm_other: Perm,

            pub const none = std.mem.zeroes(Mode);

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

            pub fn eql(self: Mode, other: Mode) bool {
                if (self.type != other.type) return false;
                if (self.perm_user != other.perm_user) return false;
                if (self.perm_group != other.perm_group) return false;
                if (self.perm_other != other.perm_other) return false;
                return true;
            }

            pub fn intbytes(self: Mode) [6]u8 {
                var b: [6]u8 = @splat('-');
                @memcpy(b[0..3], switch (self.type) {
                    .file => "100",
                    .directory => "040",
                    .submodule => "160",
                    .symlink => "120",
                    .none => "000",
                });
                b[3] = @as(u8, @as(u3, @bitCast(self.perm_user))) + '0';
                b[4] = @as(u8, @as(u3, @bitCast(self.perm_group))) + '0';
                b[5] = @as(u8, @as(u3, @bitCast(self.perm_other))) + '0';
                return b;
            }

            pub fn octal(self: Mode) u9 {
                const O = packed struct {
                    other: Perm,
                    group: Perm,
                    user: Perm,
                };
                const o: O = .{
                    .other = self.perm_other,
                    .group = self.perm_group,
                    .user = self.perm_user,
                };
                return @bitCast(o);
            }
        };

        pub const Type = enum(u8) {
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

    pub fn walk(self: *Tree, r: *Repository) !Walker {
        var stack: std.ArrayListUnmanaged(Walker.StackItem) = .empty;

        try stack.append(r.gpa, .{
            .tree = self,
            .idx = 0,
            .dirname_len = 0,
        });
        return .{
            .repo = r,
            .stack = stack,
            .name_buffer = .empty,
        };
    }

    pub const Walker = struct {
        repo: *Repository,
        stack: std.ArrayListUnmanaged(StackItem),
        name_buffer: std.ArrayListUnmanaged(u8),

        pub const Entry = struct {
            obj: Object,
            path: [:0]const u8,
        };

        const StackItem = struct {
            tree: *Tree,
            idx: usize,
            dirname_len: usize,
        };

        pub fn next(self: *Walker) !?Walker.Entry {
            const gpa = self.repo.gpa;
            while (self.stack.items.len != 0) {
                var top = &self.stack.items[self.stack.items.len - 1];
                var containing = top;
                var dirname_len = top.dirname_len;
                if (top.idx < top.tree.children.len) {
                    const base = top.tree.children[top.idx];
                    top.idx += 1;
                    self.name_buffer.shrinkRetainingCapacity(dirname_len);
                    if (self.name_buffer.items.len != 0) {
                        try self.name_buffer.append(gpa, '/');
                        dirname_len += 1;
                    }
                    try self.name_buffer.ensureUnusedCapacity(gpa, base.name.len + 1);
                    self.name_buffer.appendSliceAssumeCapacity(base.name);
                    self.name_buffer.appendAssumeCapacity(0);
                    if (base.id == .tree) {
                        const new_tree = try self.repo.getTreeA(base.id.tree.id, .cache);
                        {
                            // errdefer new_dir.close();
                            try self.stack.append(gpa, .{
                                .tree = new_tree,
                                .idx = 0,
                                .dirname_len = self.name_buffer.items.len - 1,
                            });
                            top = &self.stack.items[self.stack.items.len - 1];
                            containing = &self.stack.items[self.stack.items.len - 2];
                        }
                    }
                    return .{
                        .obj = base,
                        .path = self.name_buffer.items[0 .. self.name_buffer.items.len - 1 :0],
                    };
                } else {
                    var item = self.stack.pop().?;
                    _ = &item;
                    // if (self.stack.items.len != 0) item.iter.dir.close();
                }
            }
            return null;
        }

        pub fn deinit(self: *Walker) void {
            const gpa = self.repo.gpa;
            // for (self.stack.items) |*item| item.iter.dir.close();
            self.stack.deinit(gpa);
            self.name_buffer.deinit(gpa);
        }
    };
};

pub const Commit = struct {
    raw: []const u8,
    tree: TreeId,
    parents: []const CommitId,
    author: UserAndAt,
    committer: UserAndAt,
    gpgsig: []const u8,
    message: string,

    pub fn destroy(t: *Commit, r: *Repository) void {
        r.gpa.free(t.parents);
        r.gpa.free(t.raw);
        r.gpa.destroy(t);
    }

    pub fn signature(t: *const Commit, allocator: std.mem.Allocator) !Signature {
        return .from(allocator, t.gpgsig, t.raw);
    }
};

pub const UserAndAt = struct {
    name: string,
    email: string,
    at: time.DateTime,
};

pub const Tag = struct {
    raw: []const u8,
    object: Id,
    type: RefType,
    tagger: ?UserAndAt,
    gpgsig: []const u8,
    message: string,

    pub fn destroy(t: *Tag, r: *Repository) void {
        r.gpa.free(t.raw);
        r.gpa.destroy(t);
    }

    pub fn signature(t: *const Tag, allocator: std.mem.Allocator) !Signature {
        return .from(allocator, t.gpgsig, t.raw);
    }
};

pub const Ref = struct {
    label: string,
    oid: Id,
    commit: ?Id,
};

pub const Signature = union(enum) {
    none,
    unrecognized,
    ssh: Ssh,

    pub const Ssh = struct {
        publickey: []const u8,
        hash_algorithm: []const u8,
        signature: []const u8,
        valid: ?bool,
    };

    // https://www.ietf.org/archive/id/draft-josefsson-sshsig-format-03.html
    // https://datatracker.ietf.org/doc/html/rfc4251#section-5
    // https://pkg.go.dev/golang.org/x/crypto/ssh#pkg-constants
    pub fn from(allocator: std.mem.Allocator, pem_sig: []const u8, content_plus_gpgsig: []const u8) !Signature {
        if (pem_sig.len == 0) {
            return .none;
        }
        if (std.mem.startsWith(u8, pem_sig, "-----BEGIN SSH SIGNATURE-----\n") and std.mem.endsWith(u8, pem_sig, "\n -----END SSH SIGNATURE-----")) {
            const sigcontent = pem_sig[30 .. pem_sig.len - 29];
            var fixed: nio.FixedBufferStream([]const u8) = .init(sigcontent);
            var skip = nio.SkipReader(void).from(&fixed, "\n ");
            var b64r = nio.Base64Reader(void).from(&skip);
            if (!std.mem.eql(u8, &try b64r.readArray(6), "SSHSIG")) return .unrecognized;
            const sigversion = try b64r.readInt(u32, .big);
            if (sigversion != 1) return .unrecognized;
            const publickey = try b64r.readAlloc(allocator, try b64r.readInt(u32, .big));
            errdefer allocator.free(publickey);
            const namespace = try b64r.readAlloc(allocator, try b64r.readInt(u32, .big));
            defer allocator.free(namespace);
            const reserved = try b64r.readAlloc(allocator, try b64r.readInt(u32, .big));
            defer allocator.free(reserved);
            const hash_algorithm = try b64r.readAlloc(allocator, try b64r.readInt(u32, .big));
            errdefer allocator.free(hash_algorithm);
            const signature = try b64r.readAlloc(allocator, try b64r.readInt(u32, .big));
            errdefer allocator.free(signature);
            if (!std.mem.eql(u8, namespace, "git")) return .unrecognized;
            if (reserved.len > 0) return .unrecognized;

            var message = extras.ManyArrayList(u8).init(allocator);
            defer message.deinit();
            try message.appendSlice(try message.add(), content_plus_gpgsig);
            message.lengths.items.len = 0;
            {
                var iter = std.mem.splitScalar(u8, content_plus_gpgsig, '\n');
                while (iter.next()) |line| {
                    try message.lengths.append(allocator, line.len + 1);
                }
                var skipping = false;
                var i: usize = 0;
                while (i < message.lengths.items.len) : (i += 1) {
                    if (!skipping and std.mem.startsWith(u8, message.items(i), "gpgsig ")) {
                        skipping = true;
                        message.remove(i);
                        i -= 1;
                        continue;
                    }
                    if (!skipping) {
                        continue;
                    }
                    if (skipping and std.mem.startsWith(u8, message.items(i), " ")) {
                        message.remove(i);
                        i -= 1;
                        continue;
                    }
                    break;
                }
            }

            var signed_data: nio.AllocatingWriter = .init(allocator);
            defer signed_data.deinit();
            try signed_data.writeAll("SSHSIG");
            try signed_data.writeInt(u32, @intCast(namespace.len), .big);
            try signed_data.writeAll(namespace);
            try signed_data.writeInt(u32, @intCast(reserved.len), .big);
            try signed_data.writeAll(reserved);
            try signed_data.writeInt(u32, @intCast(hash_algorithm.len), .big);
            try signed_data.writeAll(hash_algorithm);
            if (std.mem.eql(u8, hash_algorithm, "sha256")) {
                const H = std.crypto.hash.sha2.Sha256;
                try signed_data.writeInt(u32, H.digest_length, .big);
                try signed_data.writeAll(&extras.hashBytes(H, message.list.items));
            }
            if (std.mem.eql(u8, hash_algorithm, "sha512")) {
                const H = std.crypto.hash.sha2.Sha512;
                try signed_data.writeInt(u32, H.digest_length, .big);
                try signed_data.writeAll(&extras.hashBytes(H, message.list.items));
            }

            var valid: ?bool = null;
            var sigfixed: nio.FixedBufferStream([]const u8) = .init(signature);
            const sigformat = try sigfixed.readAlloc(allocator, try sigfixed.readInt(u32, .big));
            defer allocator.free(sigformat);
            var pkfixed: nio.FixedBufferStream([]const u8) = .init(publickey);
            const pkformat = try pkfixed.readAlloc(allocator, try pkfixed.readInt(u32, .big));
            defer allocator.free(pkformat);

            if (std.mem.eql(u8, sigformat, "ssh-rsa")) {
                // intentionally skipped
            }
            if (std.mem.eql(u8, sigformat, "ssh-ed25519")) blk: {
                const ed = std.crypto.sign.Ed25519;
                const pk_len = pkfixed.readInt(u32, .big) catch break :blk;
                if (pk_len != ed.PublicKey.encoded_length) break :blk;
                const pk_bytes = pkfixed.readArray(ed.PublicKey.encoded_length) catch break :blk;
                const pk = ed.PublicKey.fromBytes(pk_bytes) catch break :blk;
                const sig_len = sigfixed.readInt(u32, .big) catch break :blk;
                if (sig_len != ed.Signature.encoded_length) break :blk;
                const sig_bytes = sigfixed.readArray(ed.Signature.encoded_length) catch break :blk;
                const sig = ed.Signature.fromBytes(sig_bytes);
                valid = if (sig.verifyStrict(signed_data.items, pk)) true else |_| false;
            }
            // ssh-dss (dsa)
            // ecdsa-sha2-nistp256
            // sk-ecdsa-sha2-nistp256@openssh.com
            // ecdsa-sha2-nistp384
            // ecdsa-sha2-nistp521
            // sk-ssh-ed25519@openssh.com
            // rsa-sha2-256
            // rsa-sha2-512

            return .{
                .ssh = .{
                    .publickey = publickey,
                    .hash_algorithm = hash_algorithm,
                    .signature = signature,
                    .valid = valid,
                },
            };
        }
        return .unrecognized;
    }
};

pub fn findFirstUnset(set: std.bit_set.DynamicBitSetUnmanaged, after: usize) ?usize {
    const MaskInt = std.bit_set.DynamicBitSetUnmanaged.MaskInt;
    if (after >= set.bit_length) return null;
    if (!set.isSet(after)) return after;
    var maski = after / @bitSizeOf(MaskInt);
    while (set.masks[maski] == std.math.maxInt(MaskInt)) maski += 1;
    var mask = set.masks[maski];
    mask |= (@as(usize, 1) << @intCast((after -| (maski * @bitSizeOf(MaskInt))) % @bitSizeOf(MaskInt))) - 1;
    if (mask == std.math.maxInt(MaskInt)) maski += 1;
    while (set.masks[maski] == std.math.maxInt(MaskInt)) maski += 1;
    if (mask == std.math.maxInt(MaskInt)) mask = set.masks[maski];
    const candidate = maski * @bitSizeOf(MaskInt) + @ctz(~mask);
    if (candidate >= set.bit_length) return null;
    return candidate;
}

const PathListNode = struct {
    prev: ?*const @This(),
    data: []const u8,

    pub fn nprint(node: *const PathListNode, writable: anytype) !void {
        if (node.prev == null) {
            try writable.writeAll(node.data);
            return;
        }
        try nprint(node.prev.?, writable);
        try writable.writevAll(&.{ "/", node.data });
    }
};

/// Consumes 'tree' and returns a new owned 'Tree' in the tuple.
pub fn idFor(r: *Repository, tree: *Tree, sub_path: []const u8) !?struct { *const Tree.Object, *Tree } {
    const s_idx = std.mem.indexOfScalar(u8, sub_path, '/');
    const seg = sub_path[0 .. s_idx orelse sub_path.len];
    const obj = tree.get(seg) orelse {
        tree.destroy(r);
        return null;
    };
    switch (obj.id) {
        .tree => |id| {
            defer tree.destroy(r);
            if (s_idx == null) return null;
            const new_tree = try r.getTreeA(id.id, .no_cache);
            return idFor(r, new_tree, sub_path[s_idx.? + 1 ..]);
        },
        else => {
            if (s_idx != null) {
                tree.destroy(r);
                return null;
            }
            return .{ obj, tree };
        },
    }
}
