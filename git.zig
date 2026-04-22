const std = @import("std");
const string = []const u8;
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

pub const CommitIdx = enum(u32) {
    _,

    pub fn reify(self: CommitIdx, r: *const Repository) *const Commit {
        return &r.commits.values()[@intFromEnum(self)];
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
            .index = @splat(.{ .id = "0000000000000000000000000000000000000000" }),
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
    unpacked_loose_objects: std.StringArrayHashMapUnmanaged(GitObject),
    unpacked_objects: std.AutoArrayHashMapUnmanaged(u64, GitObject),
    idx_content: std.StringArrayHashMapUnmanaged([]const u8),
    pack_content: std.StringArrayHashMapUnmanaged([]const u8),
    commits: std.StringArrayHashMapUnmanaged(Commit),
    trees: std.StringArrayHashMapUnmanaged(Tree),
    tags: std.StringArrayHashMapUnmanaged(Tag),

    pub fn init(gitdir: nfs.Dir, gpa: std.mem.Allocator) Repository {
        return .{
            .gitdir = gitdir,
            .gpa = gpa,
            .unpacked_loose_objects = .empty,
            .unpacked_objects = .empty,
            .idx_content = .empty,
            .pack_content = .empty,
            .commits = .empty,
            .trees = .empty,
            .tags = .empty,
        };
    }

    pub fn deinit(r: *Repository) void {
        for (r.unpacked_loose_objects.values()) |v| r.gpa.free(v.content);
        r.unpacked_loose_objects.deinit(r.gpa);
        for (r.unpacked_objects.values()) |v| r.gpa.free(v.content);
        r.unpacked_objects.deinit(r.gpa);
        for (r.idx_content.values()) |v| nfs.munmap(v);
        r.idx_content.deinit(r.gpa);
        for (r.pack_content.values()) |v| nfs.munmap(v);
        r.pack_content.deinit(r.gpa);
        r.commits.deinit(r.gpa);
        for (r.trees.values()) |*v| v.children.deinit(r.gpa);
        r.trees.deinit(r.gpa);
        r.tags.deinit(r.gpa);
    }

    pub fn getObject(r: *Repository, arena: std.mem.Allocator, oid: Id) anyerror!?GitObject {
        const t = tracer.trace(@src(), " {s}", .{oid});
        defer t.end();

        if (r.unpacked_loose_objects.get(oid)) |obj| {
            return obj;
        }
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
            var list: std.ArrayListUnmanaged(u8) = .empty;
            errdefer list.deinit(r.gpa);
            try list.ensureUnusedCapacity(r.gpa, 512);
            // try std.compress.flate.inflate.decompress(.zlib, bufr.anyReadable(), list.writer());
            try inflate_decompress(compressed_content, &list, r.gpa);
            const data = list.items;
            const header = data[0..std.mem.indexOfScalar(u8, data, 0).?];
            const _type_s = header[0..std.mem.indexOfScalar(u8, header, ' ').?];
            const _type = std.meta.stringToEnum(RefType, _type_s).?;
            const content_len = try extras.parseDigits(u64, header[_type_s.len + 1 ..], 10);
            list.replaceRangeAssumeCapacity(0, header.len + 1, "");
            const content = try list.toOwnedSlice(r.gpa);
            std.debug.assert(content.len == content_len);
            const obj: GitObject = .{ .type = _type, .content = content };
            try r.unpacked_loose_objects.put(r.gpa, oid, obj);
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
                    try arena.dupe(u8, entry.name),
                    idx_content,
                );
            }
        }
        const t4 = tracer.trace(@src(), " find pack_index/pack_offset", .{});
        errdefer t4.end();
        const pack_index, const pack_offset = blk: for (r.idx_content.keys(), r.idx_content.values()) |idx_path, idx_content| {
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
                break :blk .{ pack_index, pack_offset };
            } else {
                return error.Version1Idx;
            }
        } else return null;
        t4.end();

        // parse .pack
        return try r.getPackedObject(arena, oid, pack_index, pack_offset);
    }

    fn getPackedObject(r: *Repository, arena: std.mem.Allocator, maybe_oid: ?Id, pack_index: usize, pack_offset: usize) !GitObject {
        const t = tracer.trace(@src(), " {?s} {d} {d} {s}", .{ maybe_oid, pack_index, pack_offset, r.pack_content.keys()[pack_index] });
        defer t.end();

        const key = std.hash.Wyhash.hash(0, &(std.mem.toBytes(pack_index) ++ std.mem.toBytes(pack_offset)));
        if (r.unpacked_objects.get(key)) |o| return o;

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
                        var list: std.ArrayListUnmanaged(u8) = .empty;
                        errdefer list.deinit(r.gpa);
                        try list.ensureUnusedCapacity(r.gpa, 512);
                        // try std.compress.flate.inflate.decompress(.zlib, bufr.anyReadable(), list.writer());
                        try inflate_decompress(compressed_content, &list, r.gpa);
                        const _type = std.meta.stringToEnum(RefType, @tagName(ty)).?;
                        const content = try list.toOwnedSlice(r.gpa);
                        const obj: GitObject = .{ .type = _type, .content = content };
                        try r.unpacked_objects.put(r.gpa, key, obj);
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
                        const base_obj = try r.getPackedObject(arena, null, pack_index, base_pack_offset);
                        return r.getDeltadObject(maybe_oid, key, &packedobj_fbs, size, base_obj);
                    },
                    .ref_delta => {
                        const base_oid = extras.to_hex(packedobj_fbs.takeSlice(20)[0..20].*);
                        const base_obj = (try r.getObject(arena, &base_oid)).?;
                        return r.getDeltadObject(maybe_oid, key, &packedobj_fbs, size, base_obj);
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

    fn getDeltadObject(r: *Repository, maybe_oid: ?Id, key: u64, packedobj_fbs: *nio.FixedBufferStream([]const u8), size: usize, base_obj: GitObject) !GitObject {
        const compressed_content = packedobj_fbs.rest();
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(r.gpa);
        try list.ensureUnusedCapacity(r.gpa, size);
        // try std.compress.flate.inflate.decompress(.zlib, bufr.anyReadable(), list.writer(r.gpa));
        try inflate_decompress(compressed_content, &list, r.gpa);
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
        if (maybe_oid) |oid|
            try r.unpacked_loose_objects.put(r.gpa, oid, obj)
        else
            try r.unpacked_objects.put(r.gpa, key, obj);
        return obj;
    }

    pub fn getObjectA(r: *Repository, arena: std.mem.Allocator, oid: Id) !GitObject {
        return (try r.getObject(arena, oid)).?;
    }

    pub fn getObjectC(r: *Repository, arena: std.mem.Allocator, oid: Id) ![]const u8 {
        return (try r.getObjectA(arena, oid)).content;
    }

    const GitObject = struct {
        type: RefType,
        content: []const u8,
    };

    pub fn getBlob(r: *Repository, arena: std.mem.Allocator, id: BlobId) !?[]const u8 {
        if (try r.getObject(arena, id.id)) |obj| {
            if (obj.type == .blob) {
                return obj.content;
            }
        }
        return null;
    }

    pub fn getBlobA(r: *Repository, arena: std.mem.Allocator, id: Id) ![]const u8 {
        return (try r.getBlob(arena, .{ .id = id })).?;
    }

    pub fn getCommit(r: *Repository, arena: std.mem.Allocator, id: CommitId) !?struct { CommitId, CommitIdx } {
        const t = tracer.trace(@src(), " {s}", .{id.id});
        defer t.end();

        if (r.commits.getIndex(id.id)) |idx| {
            return .{ id, @enumFromInt(idx) };
        }
        if (try r.getObject(arena, id.id)) |obj| {
            if (obj.type == .commit) {
                const commit = try parseCommit(arena, obj.content);
                try r.commits.put(r.gpa, id.id, commit);
                const idx = r.commits.values().len - 1;
                return .{ id, @enumFromInt(idx) };
            }
        }
        return null;
    }

    pub fn getCommitA(r: *Repository, arena: std.mem.Allocator, id: Id) !CommitIdx {
        return (try r.getCommit(arena, .{ .id = id })).?.@"1";
    }

    pub fn getTree(r: *Repository, arena: std.mem.Allocator, id: TreeId) !?struct { TreeId, Tree } {
        const t = tracer.trace(@src(), " {s}", .{id.id});
        defer t.end();

        if (r.trees.getPtr(id.id)) |val| {
            return .{ id, val.* };
        }
        if (try r.getObject(arena, id.id)) |obj| {
            if (obj.type == .tree) {
                const MAL = MultiArrayList(Tree.Object);
                var children: MAL = .empty;
                errdefer children.deinit(r.gpa);
                try children.ensureUnusedCapacity(r.gpa, 33);
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

                    try children.append(r.gpa, .{
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

                const S = struct {
                    list: *MAL,

                    pub fn lessThan(s: @This(), a: usize, b: usize) bool {
                        const items = s.list.items.name;
                        return std.mem.order(u8, items[a], items[b]) == .lt;
                    }
                    pub fn swap(s: @This(), a: usize, b: usize) void {
                        // Remove after updating to Zig 0.17. Ref: https://codeberg.org/ziglang/zig/pulls/32016
                        inline for (@typeInfo(Tree.Object).@"struct".fields) |field| {
                            const its = @field(s.list.items, field.name);
                            std.mem.swap(@FieldType(Tree.Object, field.name), &its[a], &its[b]);
                        }
                    }
                };
                if (children.len() > 1000) std.mem.sortContext(0, children.len(), S{ .list = &children });

                const tree: Tree = .{ .children = children };
                try r.trees.put(r.gpa, id.id, tree);
                return .{ id, tree };
            }
        }
        return null;
    }

    pub fn getTreeA(r: *Repository, arena: std.mem.Allocator, id: Id) !Tree {
        return (try r.getTree(arena, .{ .id = id })).?.@"1";
    }

    pub fn getTag(r: *Repository, arena: std.mem.Allocator, id: TagId) !?struct { TagId, Tag } {
        const t = tracer.trace(@src(), " {s}", .{id.id});
        defer t.end();

        if (r.tags.getPtr(id.id)) |val| {
            return .{ id, val.* };
        }
        if (try r.getObject(arena, id.id)) |obj| {
            if (obj.type == .tag) {
                const tag = try parseTag(obj.content);
                try r.tags.put(r.gpa, id.id, tag);
                return .{ id, tag };
            }
        }
        return null;
    }

    pub fn getTagA(r: *Repository, arena: std.mem.Allocator, id: Id) !Tag {
        return (try r.getTag(arena, .{ .id = id })).?.@"1";
    }

    pub fn getHeads(r: *Repository, arena: std.mem.Allocator) ![]Ref {
        const t = tracer.trace(@src(), "", .{});
        defer t.end();

        return r.getRefs(arena, "heads");
    }

    pub fn getTags(r: *Repository, arena: std.mem.Allocator) ![]Ref {
        const t = tracer.trace(@src(), "", .{});
        defer t.end();

        return r.getRefs(arena, "tags");
    }

    pub fn getRefs(r: *Repository, arena: std.mem.Allocator, comptime kind: [:0]const u8) ![]Ref {
        const t = tracer.trace(@src(), "", .{});
        defer t.end();

        var map: std.StringArrayHashMapUnmanaged(Id) = .empty;
        try r.addPackedRefs(&map, arena, kind);
        try r.addDirRefs(&map, arena, kind);
        var list: std.ArrayListUnmanaged(Ref) = .empty;
        try list.ensureUnusedCapacity(arena, map.count());
        for (map.keys(), map.values()) |label, oid| list.appendAssumeCapacity(.{ .oid = oid, .label = label });
        return list.items;
    }

    fn addPackedRefs(r: *Repository, map: *std.StringArrayHashMapUnmanaged(Id), arena: std.mem.Allocator, comptime kind: [:0]const u8) !void {
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
            if (line[0] == '^') continue;
            if (line[0] == '#') continue;
            std.debug.assert(extras.matchesAll(u8, line[0..40], std.ascii.isHex));
            std.debug.assert(line[40] == ' ');
            const rest = extras.trimPrefixEnsure(line[41..], "refs/" ++ kind ++ "/") orelse continue;
            const oid = try arena.dupe(u8, line[0..40]);
            const label = try arena.dupeZ(u8, rest);
            try map.put(arena, label, oid[0..40]);
        }
    }

    fn addDirRefs(r: *Repository, map: *std.StringArrayHashMapUnmanaged(Id), arena: std.mem.Allocator, comptime kind: [:0]const u8) !void {
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
            try map.put(arena, label, oid[0..40]);
        }
    }

    pub fn getTreeCommits(r: *Repository, arena: std.mem.Allocator, base_oid: CommitId, dir_path: []const u8) ![]const CommitId {
        const t = tracer.trace(@src(), "", .{});
        defer t.end();

        // const start = std.time.milliTimestamp();

        const base_idx = try r.getCommitA(arena, base_oid.id);
        const base = base_idx.reify(r);
        const base_tree = (try traverseTo(r, arena, base.tree, dir_path)).?;
        const total = base_tree.children.len();

        var found: usize = 0;
        var result: std.StringArrayHashMapUnmanaged(CommitId) = .empty;
        defer result.deinit(r.gpa);
        for (base_tree.children.items.name) |name| try result.put(r.gpa, name, undefined);

        var set: std.bit_set.DynamicBitSetUnmanaged = try .initEmpty(r.gpa, total);
        defer set.deinit(r.gpa);

        var searched: usize = 0;
        var commit_id_prev = base_oid;
        var commit_id = base_oid;
        var commit_idx = base_idx;
        var commit = base;
        while (true) {
            if (commit.parents.len == 0) break;
            commit_id, commit_idx = (try r.getCommit(arena, commit.parents[0])).?;
            searched += 1;
            defer commit_id_prev = commit_id;
            commit = commit_idx.reify(r);
            const tree = try traverseTo(r, arena, commit.tree, dir_path) orelse {
                for (result.keys(), 0..) |k, i| {
                    if (set.isSet(i)) continue;
                    found += 1;
                    result.putAssumeCapacity(k, commit_id_prev);
                    set.set(i);
                    // std.log.debug("found [{d}/{d}] objects after searching {d} commits", .{ found, total, searched });
                    continue;
                }
                break;
            };
            for (result.keys(), 0..) |k, i| {
                if (set.isSet(i)) continue;
                const original = base_tree.get(k).?;
                const new = tree.get(k);
                if (new == null) {
                    found += 1;
                    result.putAssumeCapacity(k, commit_id_prev);
                    set.set(i);
                    // std.log.debug("found [{d}/{d}] objects after searching {d} commits", .{ found, total, searched });
                    continue;
                }
                if (!std.mem.eql(u8, new.?.id.erase(), original.id.erase())) {
                    found += 1;
                    result.putAssumeCapacity(k, commit_id_prev);
                    set.set(i);
                    // std.log.debug("found [{d}/{d}] objects after searching {d} commits", .{ found, total, searched });
                    continue;
                }
            }
            if (set.count() == total) {
                break;
            }
        }
        for (0..total, result.values()) |i, *v| {
            if (!set.isSet(i)) {
                v.* = base_oid;
            }
        }

        // const end = std.time.milliTimestamp();
        // std.log.debug("found {d} in {d}ms", .{ total, end - start });

        return try arena.dupe(CommitId, result.values());
    }
};

const z = @cImport({
    @cInclude("zlib.h");
});

fn inflate_decompress(in: []const u8, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
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
        try out.appendSlice(allocator, buf[0 .. buf.len - strm.avail_out]);
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

fn traverseTo(r: *Repository, arena: std.mem.Allocator, treestart_id: TreeId, dir_path: []const u8) !?Tree {
    var tree = try r.getTreeA(arena, treestart_id.id);
    if (dir_path.len == 0) return tree;
    var iter = std.mem.splitScalar(u8, dir_path, '/');
    while (iter.next()) |segment| {
        const o = tree.get(segment) orelse return null;
        tree = try r.getTreeA(arena, o.id.tree.id);
    }
    return tree;
}

pub const Tree = struct {
    children: MultiArrayList(Object),

    pub fn get(self: Tree, name: string) ?Object {
        if (self.children.len() <= 1000) {
            for (self.children.items.name, 0..) |a_name, i| {
                if (std.mem.eql(u8, a_name, name)) {
                    return self.children.get(i);
                }
            }
            return null;
        }
        const i = std.sort.binarySearch([]const u8, self.children.items.name, name, extras.compareFnSlice(u8)) orelse return null;
        return self.children.get(i);
    }

    pub fn getBlob(self: Tree, name: string) ?Object {
        const o = self.get(name) orelse return null;
        if (o.id != .blob) return null;
        return o;
    }

    pub fn find(self: Tree, name: string) ?Object {
        for (self.children.items.name, 0..) |item, i| {
            if (std.ascii.eqlIgnoreCase(item, name)) {
                return self.children.get(i);
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
        name: [:0]const u8,

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

            pub fn eql(self: Mode, other: Mode) bool {
                if (self.type != other.type) return false;
                if (self.perm_user != other.perm_user) return false;
                if (self.perm_group != other.perm_group) return false;
                if (self.perm_other != other.perm_other) return false;
                return true;
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

    pub fn walk(self: Tree, r: *Repository, arena: std.mem.Allocator) !Walker {
        var stack: std.ArrayListUnmanaged(Walker.StackItem) = .empty;

        try stack.append(r.gpa, .{
            .tree = self,
            .idx = 0,
            .dirname_len = 0,
        });
        return .{
            .repo = r,
            .arena = arena,
            .stack = stack,
            .name_buffer = .empty,
        };
    }

    pub const Walker = struct {
        repo: *Repository,
        arena: std.mem.Allocator,
        stack: std.ArrayListUnmanaged(StackItem),
        name_buffer: std.ArrayListUnmanaged(u8),

        pub const Entry = struct {
            obj: Object,
            path: [:0]const u8,
        };

        const StackItem = struct {
            tree: Tree,
            idx: usize,
            dirname_len: usize,
        };

        pub fn next(self: *Walker) !?Walker.Entry {
            const gpa = self.repo.gpa;
            const arena = self.arena;
            while (self.stack.items.len != 0) {
                var top = &self.stack.items[self.stack.items.len - 1];
                var containing = top;
                var dirname_len = top.dirname_len;
                if (top.idx < top.tree.children.len()) {
                    const base = top.tree.children.get(top.idx);
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
                        const new_tree = try self.repo.getTreeA(arena, base.id.tree.id);
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

pub const Tag = struct {
    object: Id,
    type: RefType,
    tagger: ?UserAndAt,
    message: string,
};

pub const Ref = struct {
    oid: Id,
    label: string,
};

/// Variant on std.MultiArrayList but using an allocation per-field rather than a single for the entire structure.
fn MultiArrayList(T: type) type {
    return struct {
        items: Items,
        capacity: usize,

        comptime Elem: type = T,

        pub const empty: Self = .{
            .items = .{},
            .capacity = 0,
        };

        pub const Self = @This();

        const info = @typeInfo(T).@"struct";

        pub const Items = blk: {
            var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            for (info.fields, 0..) |f, i| {
                const empty_slice: []f.type = &[_]f.type{};
                fields[i] = .{
                    .name = f.name,
                    .type = []f.type,
                    .default_value_ptr = @ptrCast(&empty_slice),
                    .is_comptime = false,
                    .alignment = @alignOf(f.type),
                };
            }
            const _fields = fields;
            break :blk @Type(.{
                .@"struct" = .{
                    .layout = .auto,
                    .fields = &_fields,
                    .decls = &.{},
                    .is_tuple = false,
                },
            });
        };

        pub fn deinit(self: *const Self, gpa: std.mem.Allocator) void {
            inline for (info.fields) |f| {
                gpa.free(@field(self.items, f.name).ptr[0..self.capacity]);
            }
        }

        pub fn len(self: *const Self) usize {
            return @field(self.items, info.fields[0].name).len;
        }

        pub fn get(self: *const Self, index: usize) T {
            var result: T = undefined;
            inline for (info.fields) |f| {
                @field(result, f.name) = @field(self.items, f.name)[index];
            }
            return result;
        }

        pub fn ensureUnusedCapacity(self: *Self, gpa: std.mem.Allocator, additional_count: usize) !void {
            return self.ensureTotalCapacity(gpa, self.len() + additional_count);
        }

        pub fn ensureTotalCapacity(self: *Self, gpa: std.mem.Allocator, new_capacity: usize) !void {
            if (self.capacity >= new_capacity) return;
            const actual_new_capacity = growCapacity(self.capacity, new_capacity);
            const previous_len = self.len();
            var new_items: Items = .{};
            inline for (info.fields, 0..) |f, i| {
                errdefer inline for (info.fields[0..i]) |g| gpa.free(@field(new_items, g.name)[0..actual_new_capacity]);
                @field(new_items, f.name) = try gpa.alloc(f.type, actual_new_capacity);
                @field(new_items, f.name).len = previous_len;
            }
            inline for (info.fields) |f| {
                @memcpy(@field(new_items, f.name)[0..previous_len], @field(self.items, f.name)[0..previous_len]);
            }
            inline for (info.fields) |f| {
                gpa.free(@field(self.items, f.name)[0..previous_len]);
            }
            self.items = new_items;
            self.capacity = actual_new_capacity;
        }

        /// Called when memory growth is necessary. Returns a capacity larger than minimum that grows super-linearly.
        fn growCapacity(current: usize, minimum: usize) usize {
            var new = current;
            while (true) {
                new +|= new / 2 + init_capacity;
                if (new >= minimum) return new;
            }
        }

        const init_capacity = init: {
            var max = 1;
            for (info.fields) |field| max = @as(comptime_int, @max(max, @sizeOf(field.type)));
            break :init @as(comptime_int, @max(1, std.atomic.cache_line / max));
        };

        pub fn append(self: *Self, gpa: std.mem.Allocator, elem: T) !void {
            try self.ensureUnusedCapacity(gpa, 1);
            self.appendAssumeCapacity(elem);
        }

        pub fn appendAssumeCapacity(self: *Self, elem: T) void {
            const plen = self.len();
            std.debug.assert(plen < self.capacity);
            inline for (info.fields) |f| {
                @field(self.items, f.name).len += 1;
                @field(self.items, f.name)[plen] = @field(elem, f.name);
            }
        }
    };
}
