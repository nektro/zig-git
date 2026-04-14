const std = @import("std");
const git = @import("git");
const extras = @import("extras");
const expect = @import("expect").expect;
const nfs = @import("nfs");

test {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const git_dir = try nfs.cwd().openDir(".git", .{});
    defer git_dir.close();
    var repo: git.Repository = .init(git_dir, gpa);
    defer repo.deinit();
    const branch_refs = try repo.getHeads(alloc);
    const branch_names = try extras.mapBy(alloc, branch_refs, .label);
    try expect(branch_names).toEqualStringSlice(&.{"master"});
}

test {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const git_dir = try nfs.cwd().openDir(".git", .{});
    defer git_dir.close();
    var repo: git.Repository = .init(git_dir, gpa);
    defer repo.deinit();
    try expect(try repo.getObjectC(alloc, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e")).toEqualString(
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
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const git_dir = try nfs.cwd().openDir(".git", .{});
    defer git_dir.close();
    var repo: git.Repository = .init(git_dir, gpa);
    defer repo.deinit();
    try expect((try repo.getObjectC(alloc, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e")).len).toEqual(229);
    try expect((try repo.getObjectC(alloc, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e")).len).toEqual(45 + 47 + 55 + 58 + 0 + 18 + 6);
}

test {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const git_dir = try nfs.cwd().openDir(".git", .{});
    defer git_dir.close();
    var repo: git.Repository = .init(git_dir, gpa);
    defer repo.deinit();
    try expect((try repo.getObjectA(alloc, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e")).type == .blob).toEqual(false);
    try expect((try repo.getObjectA(alloc, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e")).type == .tree).toEqual(false);
    try expect((try repo.getObjectA(alloc, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e")).type == .commit).toEqual(true);
    try expect((try repo.getObjectA(alloc, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e")).type == .tag).toEqual(false);
}

test {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const git_dir = try nfs.cwd().openDir(".git", .{});
    defer git_dir.close();
    var repo: git.Repository = .init(git_dir, gpa);
    defer repo.deinit();
    try expect((try repo.getObjectA(alloc, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e")).type).toEqual(.commit);
}

test {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const git_dir = try nfs.cwd().openDir(".git", .{});
    defer git_dir.close();
    var repo: git.Repository = .init(git_dir, gpa);
    defer repo.deinit();
    const c = try repo.getCommitA(alloc, "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e");
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
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const git_dir = try nfs.cwd().openDir(".git", .{});
    defer git_dir.close();
    var repo: git.Repository = .init(git_dir, gpa);
    defer repo.deinit();
    try expect(try repo.getObjectC(alloc, "5403fecad0fde9120535321f222a061abc2849d9")).toEqualString(
        // zig fmt: off
        "100644 .gitattributes\x00" ++ .{0x8e,0x8d,0x2c,0xeb,0xa4,0xb3,0x27,0xce,0x9d,0xb9,0x3f,0x98,0x84,0x92,0xd0,0xe2,0x1a,0x46,0x10,0x12} ++
        "100644 .gitignore\x00" ++ .{0xbb,0x2a,0x57,0xbd,0x81,0xd1,0x39,0x75,0xf2,0xa7,0x4a,0xe5,0xdd,0x0e,0x65,0x2d,0xe0,0x7b,0xb8,0xa7} ++
        "100644 LICENSE\x00" ++ .{0x37,0xbe,0x0c,0x1c,0xfa,0x4f,0x09,0x7e,0xdb,0xb1,0xfb,0x5c,0x05,0x85,0xcd,0x18,0xcb,0x08,0xdf,0x13} ++
        "100644 git.zig\x00" ++ .{0xb2,0x29,0xea,0xdb,0xd5,0xd6,0x65,0x5c,0x2d,0xfb,0xac,0xa5,0xa5,0xf6,0x8f,0x2f,0x8f,0x3c,0x54,0x54} ++
        "100644 zig.mod\x00" ++ .{0xbb,0x3f,0x1c,0x13,0x56,0x32,0xcf,0xca,0x76,0x0b,0xd8,0x4f,0xb1,0x8a,0xcd,0xab,0x8d,0xae,0x8e,0xc3} ++
        ""
        // zig fmt: on
    );
}

test {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const git_dir = try nfs.cwd().openDir(".git", .{});
    defer git_dir.close();
    var repo: git.Repository = .init(git_dir, gpa);
    defer repo.deinit();
    const t = try repo.getTreeA(alloc, "5403fecad0fde9120535321f222a061abc2849d9");
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
    const git_dir = try nfs.cwd().openDir(".git", .{});
    defer git_dir.close();
    try expect(try git.getTreeDiff(alloc, git_dir, .{ .id = "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e" }, .{ .id = "c39f57f6bb01664a7146ddbfc3debe76ec135f44" })).toEqualString(
        // zig fmt: off
        ":100644 100644 73c7032166db0eb23c4be11a4ff8ff26ec47c582 b229eadbd5d6655c2dfbaca5a5f68f2f8f3c5454 M\tgit.zig\n" ++
        "\n" ++
        "diff --git a/git.zig b/git.zig\n" ++
        "index 73c7032166db0eb23c4be11a4ff8ff26ec47c582..b229eadbd5d6655c2dfbaca5a5f68f2f8f3c5454 100644\n" ++
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
    const git_dir = try nfs.cwd().openDir(".git", .{});
    defer git_dir.close();
    const t = try git.parseTreeDiff(alloc, try git.getTreeDiff(alloc, git_dir, .{ .id = "a542da41f1f0c59fdd0e1527cf5ff9de3f6a0c8e" }, .{ .id = "c39f57f6bb01664a7146ddbfc3debe76ec135f44" }));
    _ = t; // TODO: test fields when we upgrade to 0.14 and have decl literals
}

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try git.parseTreeDiff(alloc, @embedFile("./testdata/diff-9feb6b667c77c187f547deaf10cd1f04e92fe192")); // magnolia-desktop
}
test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try git.parseTreeDiff(alloc, @embedFile("./testdata/diff-f2ccd4d1333aad1175550daf616b061388e1864f")); // magnolia-desktop
}
test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try git.parseTreeDiff(alloc, @embedFile("./testdata/diff-47ed809ce10bdfa99351c72935467c9afae47e36")); // magnolia-desktop
}
test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try git.parseTreeDiff(alloc, @embedFile("./testdata/diff-15700f9e1c919a3f0c492415d982a09f5e8122cd")); // magnolia-desktop
}
test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try git.parseTreeDiff(alloc, @embedFile("./testdata/diff-8480815a00f341a9058a26bf86f34368184615d6")); // magnolia-desktop
}
test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try git.parseTreeDiff(alloc, @embedFile("./testdata/diff-c37d23f45ae6bd0db6b072180d7b84566c7dc8a2")); // zig
}
test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try git.parseTreeDiff(alloc, @embedFile("./testdata/diff-f58200e3f2967a06f343c9fc9dcae9de18def92a")); // zig
}
test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try git.parseTreeDiff(alloc, @embedFile("./testdata/diff-d9165aacce3629d503f87cd2c3f612629127641b")); // zig
}
test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try git.parseCommit(alloc, @embedFile("./testdata/commit-afdc41cfd61db23f545d9239b61695e2ae991713")); // zig
}
test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try git.parseTreeDiff(alloc, @embedFile("./testdata/diff-1f7390f3999e80f775dbc0e62f1dcb071c3bed77")); // zig
}
test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try git.parseTreeDiff(alloc, @embedFile("./testdata/diff-a0482e3446cea426bf16571e0000423ed5b25af0")); // linux
}
test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try git.parseTreeDiff(alloc, @embedFile("./testdata/diff-e90937e756938f03d37d4cae7c82316a3a425944")); // linux
}
