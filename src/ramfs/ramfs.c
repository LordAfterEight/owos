#include "ramfs.h"
#include "../std/mem.h"
#include "../std/string.h"
#include "../std/std.h"
#include "../shell/shell_definitions.h"
#include "../fonts/OwOSFont_8x16.h"
#include <stddef.h>

void root_init(struct Folder* root) {
    owos_memcpy(root->name, "root", sizeof("root"));
    root->file_pointer = 0;
    root->folder_pointer = 0;

    for (int i = 0; i < MAX_FILES; i++)
        root->files[i] = NULL;

    for (int i = 0; i < MAX_FOLDERS; i++)
        root->folders[i] = NULL;
}

struct File* new_file(char name[]) {
    if (file_pool_used >= MAX_FILES)
        return NULL;

    struct File* f = &file_pool[file_pool_used++];

    owos_memcpy(f->name, name, MAX_NAME_LENGTH);
    f->name[MAX_NAME_LENGTH - 1] = '\0';

    f->length = 0;
    f->data = file_data_pool[file_pool_used - 1];

    owos_memset(f->data, 0, MAX_FILE_DATA);

    return f;
}

struct Folder* new_folder(char name[]) {
    if (folder_pool_used >= MAX_TOTAL_FOLDERS)
        return NULL;

    struct Folder* f = &folder_pool[folder_pool_used++];

    owos_memcpy(f->name, name, MAX_NAME_LENGTH);
    f->name[MAX_NAME_LENGTH - 1] = '\0';

    f->file_pointer = 0;
    f->folder_pointer = 0;
    owos_memset(f->files,   0, sizeof(f->files));
    owos_memset(f->folders, 0, sizeof(f->folders));

    return f;
}

int move_folder(char* folder_name, char* dest_name) {
    int src_idx = -1;
    struct Folder* moving = NULL;
    for (int i = 0; i < root_dir.folder_pointer; i++) {
        if (root_dir.folders[i] && strcmp(root_dir.folders[i]->name, folder_name) == 0) {
            src_idx = i;
            moving = root_dir.folders[i];
            break;
        }
    }
    if (src_idx == -1) {
        shell_println("No such folder to move", 0xFF7777, false, &OwOSFont_8x16);
        return -1;
    }

    struct Folder* dest = NULL;
    for (int i = 0; i < root_dir.folder_pointer; i++) {
        if (root_dir.folders[i] && strcmp(root_dir.folders[i]->name, dest_name) == 0) {
            dest = root_dir.folders[i];
            break;
        }
    }
    if (dest == NULL) {
        shell_println("No such destination folder", 0xFF7777, false, &OwOSFont_8x16);
        return -1;
    }
    if (dest->folder_pointer >= MAX_FOLDERS) {
        shell_println("Destination full", 0xFF7777, false, &OwOSFont_8x16);
        return -1;
    }

    if (src_idx < root_dir.folder_pointer - 1) {
        owos_memmove((void*)&root_dir.folders[src_idx],
                (void*)&root_dir.folders[src_idx + 1],
                (root_dir.folder_pointer - src_idx - 1) * sizeof(struct Folder*));
    }
    root_dir.folder_pointer--;
    root_dir.folders[root_dir.folder_pointer] = NULL;

    dest->folders[dest->folder_pointer] = moving;
    dest->folder_pointer++;

    char buf[128];
    format(buf, "Moved %s into %s", dest_name, folder_name);
    shell_println(buf, 0x77FF77, false, &OwOSFont_8x16);

    return 0;
}

volatile struct Folder root_dir = {0};
