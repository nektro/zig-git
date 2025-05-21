const std = @import("std");
const git = @import("git");
const extras = @import("extras");
const expect = @import("expect").expect;

test {
    _ = &git.version;
    _ = &git.getHEAD;
    _ = &git.getTags;
    _ = &git.revList;
}

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var git_dir = try std.fs.cwd().openDir(".git", .{});
    defer git_dir.close();
    const branch_refs = try git.getBranches(alloc, git_dir);
    const branch_names = try extras.mapBy(alloc, branch_refs, .label);
    try expect(branch_names).toEqualStringSlice(&.{"master"});
}

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var git_dir = try std.fs.cwd().openDir(".git", .{});
    defer git_dir.close();
    try expect(try git.getObject(alloc, git_dir, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e")).toEqualString(
        \\tree 5403fecad0fde9120535321f222a061abc2849d9
        \\parent c39f57f6bb01664a7146ddbfc3debe76ec135f44
        \\author Meghan Denny <hello@nektro.net> 1692246864 -0700
        \\committer Meghan Denny <hello@nektro.net> 1692246864 -0700
        \\
        \\update to Zig 0.11
        \\
    );
}

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var git_dir = try std.fs.cwd().openDir(".git", .{});
    defer git_dir.close();
    try expect(try git.getObjectSize(alloc, git_dir, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e")).toEqual(229);
    try expect(try git.getObjectSize(alloc, git_dir, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e")).toEqual(45 + 47 + 55 + 58 + 0 + 18 + 6);
}

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var git_dir = try std.fs.cwd().openDir(".git", .{});
    defer git_dir.close();
    try expect(try git.isType(alloc, git_dir, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e", .blob)).toEqual(false);
    try expect(try git.isType(alloc, git_dir, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e", .tree)).toEqual(false);
    try expect(try git.isType(alloc, git_dir, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e", .commit)).toEqual(true);
    try expect(try git.isType(alloc, git_dir, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e", .tag)).toEqual(false);
}

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var git_dir = try std.fs.cwd().openDir(".git", .{});
    defer git_dir.close();
    try expect(try git.getType(alloc, git_dir, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e")).toEqual(.commit);
}

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var git_dir = try std.fs.cwd().openDir(".git", .{});
    defer git_dir.close();
    const c = try git.parseCommit(alloc, try git.getObject(alloc, git_dir, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e"));
    try expect(c.tree.id).toEqualString("5403fecad0fde9120535321f222a061abc2849d9");
    try expect(c.parents.len).toEqual(1);
    try expect(c.parents[0].id).toEqualString("c39f57f6bb01664a7146ddbfc3debe76ec135f44");
    try expect(c.author.name).toEqualString("Meghan Denny");
    try expect(c.author.email).toEqualString("hello@nektro.net");
    // TODO: test .at when we upgrade to 0.14 and have decl literals
    try expect(c.committer.name).toEqualString("Meghan Denny");
    try expect(c.committer.email).toEqualString("hello@nektro.net");
    // TODO: test .at when we upgrade to 0.14 and have decl literals
    try expect(c.message).toEqualString(
        \\update to Zig 0.11
        \\
    );
}

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var git_dir = try std.fs.cwd().openDir(".git", .{});
    defer git_dir.close();
    try expect(try git.getObject(alloc, git_dir, "5403fecad0fde9120535321f222a061abc2849d9")).toEqualString(
        // zig fmt: off
        "100644 blob 8e8d2ceba4b327ce9db93f988492d0e21a461012\t.gitattributes\n" ++
        "100644 blob bb2a57bd81d13975f2a74ae5dd0e652de07bb8a7\t.gitignore\n" ++
        "100644 blob 37be0c1cfa4f097edbb1fb5c0585cd18cb08df13\tLICENSE\n" ++
        "100644 blob b229eadbd5d6655c2dfbaca5a5f68f2f8f3c5454\tgit.zig\n" ++
        "100644 blob bb3f1c135632cfca760bd84fb18acdab8dae8ec3\tzig.mod\n" ++
        ""
        // zig fmt: on
    );
}

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var git_dir = try std.fs.cwd().openDir(".git", .{});
    defer git_dir.close();
    const t = try git.parseTree(alloc, try git.getObject(alloc, git_dir, "5403fecad0fde9120535321f222a061abc2849d9"));
    // TODO: test fields when we upgrade to 0.14 and have decl literals
    // try expect(try extras.mapBy(alloc, t.children, .id)).toEqualSlice(&.{
    //     .{ .blob = .{ .id = "8e8d2ceba4b327ce9db93f988492d0e21a461012" } },
    //     .{ .blob = .{ .id = "bb2a57bd81d13975f2a74ae5dd0e652de07bb8a7" } },
    //     .{ .blob = .{ .id = "37be0c1cfa4f097edbb1fb5c0585cd18cb08df13" } },
    //     .{ .blob = .{ .id = "b229eadbd5d6655c2dfbaca5a5f68f2f8f3c5454" } },
    //     .{ .blob = .{ .id = "bb3f1c135632cfca760bd84fb18acdab8dae8ec3" } },
    // });
    try expect(try extras.mapBy(alloc, t.children, .name)).toEqualStringSlice(&.{
        ".gitattributes",
        ".gitignore",
        "LICENSE",
        "git.zig",
        "zig.mod",
    });
}

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var git_dir = try std.fs.cwd().openDir(".git", .{});
    defer git_dir.close();
    try expect(try git.getTreeDiff(alloc, git_dir, .{ .id = "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e" }, .{ .id = "c39f57f6bb01664a7146ddbfc3debe76ec135f44" })).toEqualString(
        // zig fmt: off
        ":100644 100644 73c7032166db0eb23c4be11a4ff8ff26ec47c582 b229eadbd5d6655c2dfbaca5a5f68f2f8f3c5454 M\tgit.zig\n" ++
        "\n" ++
        "diff --git a/git.zig b/git.zig\n" ++
        "index 73c7032..b229ead 100644\n" ++
        "--- a/git.zig\n" ++
        "+++ b/git.zig\n" ++
        "@@ -251,10 +251,10 @@ pub fn parseTree(alloc: std.mem.Allocator, treefile: string) !Tree {\n" ++
        " fn parseTreeMode(input: string) !Tree.Object.Mode {\n" ++
        "     std.debug.assert(input.len == 6);\n" ++
        "     return .{\n" ++
        "-        .type = @intToEnum(Tree.Object.Type, try std.fmt.parseInt(u16, input[0..3], 10)),\n" ++
        "-        .perm_user = @bitCast(Tree.Object.Perm, try std.fmt.parseInt(u3, input[3..][0..1], 8)),\n" ++
        "-        .perm_group = @bitCast(Tree.Object.Perm, try std.fmt.parseInt(u3, input[4..][0..1], 8)),\n" ++
        "-        .perm_other = @bitCast(Tree.Object.Perm, try std.fmt.parseInt(u3, input[5..][0..1], 8)),\n" ++
        "+        .type = @enumFromInt(try std.fmt.parseInt(u16, input[0..3], 10)),\n" ++
        "+        .perm_user = @bitCast(try std.fmt.parseInt(u3, input[3..][0..1], 8)),\n" ++
        "+        .perm_group = @bitCast(try std.fmt.parseInt(u3, input[4..][0..1], 8)),\n" ++
        "+        .perm_other = @bitCast(try std.fmt.parseInt(u3, input[5..][0..1], 8)),\n" ++
        "     };\n" ++
        " }\n" ++
        " " ++
        ""
        // zig fmt: on
    );
}

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var git_dir = try std.fs.cwd().openDir(".git", .{});
    defer git_dir.close();
    const t = try git.parseTreeDiffMeta(try git.getTreeDiff(alloc, git_dir, .{ .id = "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e" }, .{ .id = "c39f57f6bb01664a7146ddbfc3debe76ec135f44" }));
    try expect(t.files_changed).toEqual(1);
    try expect(t.lines_added).toEqual(4);
    try expect(t.lines_removed).toEqual(4);
}

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var git_dir = try std.fs.cwd().openDir(".git", .{});
    defer git_dir.close();
    const t = try git.parseTreeDiff(alloc, try git.getTreeDiff(alloc, git_dir, .{ .id = "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e" }, .{ .id = "c39f57f6bb01664a7146ddbfc3debe76ec135f44" }));
    _ = t; // TODO: test fields when we upgrade to 0.14 and have decl literals
}
