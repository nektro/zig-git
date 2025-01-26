const std = @import("std");
const git = @import("git");

test {
    _ = &git.getBranches;
    _ = &git.getHEAD;
    _ = &git.getObject;
    _ = &git.getObjectSize;
    _ = &git.getTags;
    _ = &git.getTreeDiff;
    _ = &git.getType;
    _ = &git.isType;
    _ = &git.parseCommit;
    _ = &git.parseTreeDiff;
    _ = &git.parseTreeDiffMeta;
    _ = &git.revList;
    _ = &git.version;
}
