id: 0k64oe2nuzvjgz226ufvimjhialghxdgmlzusonbma31flnd
name: git
main: git.zig
license: MPL-2.0
description: Inspect into the depths of your .git folder purely from Zig
dependencies:
  - src: git https://github.com/nektro/zig-time
  - src: git https://github.com/nektro/zig-extras
  - src: git https://github.com/nektro/zig-tracer
  - src: git https://github.com/nektro/zig-nfs
  - src: git https://github.com/nektro/zig-nio

  - src: git https://github.com/madler/zlib tag-v1.3.2
    license: Zlib
    c_include_dirs:
      -
    c_source_files:
      - inftrees.c
      - inflate.c
      - adler32.c
      - zutil.c
      - trees.c
      - gzclose.c
      - gzwrite.c
      - gzread.c
      - deflate.c
      - compress.c
      - crc32.c
      - infback.c
      - gzlib.c
      - uncompr.c
      - inffast.c
    c_source_flags:
      - -DZ_HAVE_UNISTD_H=1

root_dependencies:
  - src: git https://github.com/nektro/zig-extras
  - src: git https://github.com/nektro/zig-expect
  - src: git https://github.com/nektro/zig-nfs
