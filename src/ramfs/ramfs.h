#ifndef RAMFS
#define RAMFS

struct File {
};

struct Folder {
};

struct RootDir {
    struct File* files[64];
    struct Folder* folders[16];
};

#endif
