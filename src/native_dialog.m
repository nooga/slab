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

// A project is a .slab folder (a package) or a bare .slab file. Folders
// stay enabled so the panel can navigate; the caller rejects a chosen
// folder that isn't a .slab.
@interface SlabProjectFilter : NSObject <NSOpenSavePanelDelegate>
@end

@implementation SlabProjectFilter
- (BOOL)panel:(id)sender shouldEnableURL:(NSURL *)url {
    NSNumber *dir = nil;
    [url getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
    if ([dir boolValue]) return YES;
    return [[[url pathExtension] lowercaseString] isEqualToString:@"slab"];
}
@end

char *slab_open_project_dialog(void) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        SlabProjectFilter *filter = [SlabProjectFilter new];
        [panel setDelegate:filter];
        [panel setCanChooseFiles:YES];
        [panel setCanChooseDirectories:YES];
        [panel setAllowsMultipleSelection:NO];
        [panel setTitle:@"Open Slab Project"];
        if ([panel runModal] != NSModalResponseOK) return NULL;
        return copy_path([[panel URL] path]);
    }
}

// Move a file to the Trash (Clean Up, docs/25); 1 when it went.
void slab_reveal(const char *path) {
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
    }
}

void slab_open(const char *target) {
    @autoreleasepool {
        NSString *s = [NSString stringWithUTF8String:target];
        NSURL *url = [s hasPrefix:@"/"] ? [NSURL fileURLWithPath:s] : [NSURL URLWithString:s];
        if (url) [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

int slab_trash(const char *path) {
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        return [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:nil error:nil] ? 1 : 0;
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

char *slab_open_audio_dialog(void) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        [panel setCanChooseFiles:YES];
        [panel setCanChooseDirectories:NO];
        [panel setAllowsMultipleSelection:NO];
        [panel setAllowedFileTypes:@[@"wav", @"wave", @"flac", @"aif", @"aiff"]];
        [panel setTitle:@"Load Audio Sample"];
        if ([panel runModal] != NSModalResponseOK) return NULL;
        return copy_path([[panel URL] path]);
    }
}

char *slab_open_keymap_dialog(void) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        [panel setCanChooseFiles:YES];
        [panel setCanChooseDirectories:YES];
        [panel setAllowsMultipleSelection:NO];
        [panel setAllowedFileTypes:@[@"wav", @"wave", @"flac", @"sfz"]];
        [panel setTitle:@"Load Sample, SFZ or Folder of Samples"];
        if ([panel runModal] != NSModalResponseOK) return NULL;
        return copy_path([[panel URL] path]);
    }
}

char *slab_choose_folder_dialog(const char *start) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        [panel setCanChooseFiles:NO];
        [panel setCanChooseDirectories:YES];
        [panel setCanCreateDirectories:YES];
        [panel setAllowsMultipleSelection:NO];
        [panel setTitle:@"Export To"];
        [panel setPrompt:@"Choose"];
        if (start != NULL && *start) [panel setDirectoryURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:start] isDirectory:YES]];
        if ([panel runModal] != NSModalResponseOK) return NULL;
        return copy_path([[panel URL] path]);
    }
}

char *slab_save_audio_dialog(const char *default_name, const char *ext) {
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        [panel setAllowedFileTypes:@[[NSString stringWithUTF8String:ext]]];
        [panel setTitle:@"Save Audio"];
        [panel setNameFieldStringValue:[NSString stringWithUTF8String:(default_name != NULL ? default_name : "bounce.wav")]];
        if ([panel runModal] != NSModalResponseOK) return NULL;
        return copy_path([[panel URL] path]);
    }
}

void slab_free_dialog_path(char *path) {
    free(path);
}
