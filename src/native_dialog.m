#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>

static char *copy_path(NSString *path) {
    if (path == nil) return NULL;
    const char *utf8 = [path UTF8String];
    if (utf8 == NULL) return NULL;
    size_t len = strlen(utf8);
    char *out = (char *)malloc(len + 1);
    if (out == NULL) return NULL;
    memcpy(out, utf8, len + 1);
    return out;
}

char *slab_open_project_dialog(void) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        [panel setCanChooseFiles:YES];
        [panel setCanChooseDirectories:NO];
        [panel setAllowsMultipleSelection:NO];
        [panel setAllowedFileTypes:@[@"slab"]];
        [panel setTitle:@"Open Slab Project"];
        if ([panel runModal] != NSModalResponseOK) return NULL;
        return copy_path([[panel URL] path]);
    }
}

char *slab_save_project_dialog(const char *default_name) {
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        [panel setAllowedFileTypes:@[@"slab"]];
        [panel setTitle:@"Save Slab Project"];
        [panel setNameFieldStringValue:[NSString stringWithUTF8String:(default_name != NULL ? default_name : "slab-project.slab")]];
        if ([panel runModal] != NSModalResponseOK) return NULL;
        return copy_path([[panel URL] path]);
    }
}

void slab_free_dialog_path(char *path) {
    free(path);
}
