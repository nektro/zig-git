id: 0k64oe2nuzvjgz226ufvimjhialghxdgmlzusonbma31flnd
name: git
main: git.zig
license: MIT
description: Inspect into the depths of your .git folder purely from Zig
dependencies:
  - src: git https://github.com/nektro/zig-time
  - src: git https://github.com/nektro/zig-extras
  - src: git https://github.com/nektro/zig-tracer
  - src: git https://github.com/nektro/zig-nfs
root_dependencies:
  - src: git https://github.com/nektro/zig-extras
  - src: git https://github.com/nektro/zig-expect
  - src: git https://github.com/nektro/zig-nfs
