// The macOS app around the raylib window: Finder opens, the menu bar, the
// window's title and document state. Main thread only.

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

// ── Finder opens (double-click, Open With, a drop on the Dock icon) ────
//
// AppKit hands documents to the app delegate's application:openURLs:.
// raylib's GLFW delegate has none, so we add one to its class before
// InitWindow: a double-click that launches slab arrives during InitWindow,
// later ones while the main loop polls events. The newest path waits here
// for the main loop to take.

static char *opened_path = NULL;

static void application_open_urls(id self, SEL _cmd, NSApplication *app, NSArray<NSURL *> *urls) {
    (void)self; (void)_cmd; (void)app;
    for (NSURL *url in urls) {
        if (![url isFileURL]) continue;
        const char *p = [[url path] UTF8String];
        if (p == NULL) continue;
        free(opened_path);
        opened_path = strdup(p);
    }
}

void slab_install_open_handler(void) {
    Class cls = objc_getClass("GLFWApplicationDelegate");
    if (cls == Nil) return;
    class_addMethod(cls, @selector(application:openURLs:), (IMP)application_open_urls, "v@:@@");
}

// The path Finder asked to open since the last call, or NULL; free() it.
char *slab_take_opened_path(void) {
    char *p = opened_path;
    opened_path = NULL;
    return p;
}

void slab_free_path(char *p) {
    free(p);
}

// ── The menu bar ───────────────────────────────────────────────────────
//
// GLFW builds the app menu (About, Hide, Quit) and the Window menu; we add
// File, Edit and View between them, and point About at Slab's own card. An item sets its command's bit (the
// item's tag, native_app.zig Command) for the main loop to take. Items
// with a key equivalent take that key before the window sees it, so the
// main loop runs each command once, from here.

static unsigned pending_commands = 0;

@interface SlabMenuTarget : NSObject
@end

@implementation SlabMenuTarget
- (void)command:(NSMenuItem *)item {
    pending_commands |= 1u << [item tag];
}
@end

static SlabMenuTarget *menu_target = nil;
static NSMenuItem *browser_item = nil;

static NSMenuItem *add_item(NSMenu *menu, NSString *title, int command, NSString *key, NSEventModifierFlags mods) {
    NSMenuItem *item = [menu addItemWithTitle:title action:@selector(command:) keyEquivalent:key];
    [item setKeyEquivalentModifierMask:mods];
    [item setTarget:menu_target];
    [item setTag:command];
    return item;
}

static NSMenu *add_menu(NSMenu *bar, NSString *title, NSInteger index) {
    NSMenuItem *holder = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    [holder setSubmenu:menu];
    [bar insertItem:holder atIndex:index];
    return menu;
}

// Commands, as in native_app.zig.
enum {
    CMD_NEW, CMD_OPEN, CMD_SAVE, CMD_SAVE_AS, CMD_CLEAN_UP, CMD_RENDER,
    CMD_UNDO, CMD_REDO, CMD_TOGGLE_BROWSER, CMD_ABOUT, CMD_BOUNCE,
};

// After InitWindow, once GLFW has made the menu bar.
void slab_install_menus(void) {
    @autoreleasepool {
        NSMenu *bar = [NSApp mainMenu];
        if (bar == nil || menu_target != nil) return;
        menu_target = [SlabMenuTarget new];
        const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
        const NSEventModifierFlags shift_cmd = NSEventModifierFlagCommand | NSEventModifierFlagShift;
        const NSEventModifierFlags alt_cmd = NSEventModifierFlagCommand | NSEventModifierFlagOption;

        // About Slab opens the About card instead of AppKit's panel.
        NSMenu *app = [[bar itemAtIndex:0] submenu];
        for (NSMenuItem *item in [app itemArray]) {
            if ([item action] != @selector(orderFrontStandardAboutPanel:)) continue;
            [item setAction:@selector(command:)];
            [item setTarget:menu_target];
            [item setTag:CMD_ABOUT];
        }

        NSMenu *file = add_menu(bar, @"File", 1);
        add_item(file, @"New Project", CMD_NEW, @"n", cmd);
        add_item(file, @"Open…", CMD_OPEN, @"o", cmd);
        [file addItem:[NSMenuItem separatorItem]];
        add_item(file, @"Save", CMD_SAVE, @"s", cmd);
        add_item(file, @"Save As…", CMD_SAVE_AS, @"s", shift_cmd);
        add_item(file, @"Clean Up Project", CMD_CLEAN_UP, @"", 0);
        [file addItem:[NSMenuItem separatorItem]];
        add_item(file, @"Export Audio…", CMD_RENDER, @"", 0);

        NSMenu *edit = add_menu(bar, @"Edit", 2);
        add_item(edit, @"Undo", CMD_UNDO, @"z", cmd);
        add_item(edit, @"Redo", CMD_REDO, @"z", shift_cmd);
        [edit addItem:[NSMenuItem separatorItem]];
        add_item(edit, @"Bounce Selection…", CMD_BOUNCE, @"", 0);

        NSMenu *view = add_menu(bar, @"View", 3);
        browser_item = add_item(view, @"Library Browser", CMD_TOGGLE_BROWSER, @"b", alt_cmd);
        [view addItem:[NSMenuItem separatorItem]];
        // Sent to the key window, which flips the item's title itself.
        NSMenuItem *full = [view addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
        [full setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagControl];
    }
}

unsigned slab_take_menu_commands(void) {
    unsigned c = pending_commands;
    pending_commands = 0;
    return c;
}

void slab_set_browser_checked(int on) {
    [browser_item setState:on ? NSControlStateValueOn : NSControlStateValueOff];
}

// ── The window ─────────────────────────────────────────────────────────

// Title, the file behind the title bar's proxy icon (NULL for none), and
// the close button's unsaved-changes dot.
void slab_set_window_document(void *window, const char *title, const char *path, int edited) {
    @autoreleasepool {
        NSWindow *w = (__bridge NSWindow *)window;
        if (w == nil) return;
        [w setTitle:[NSString stringWithUTF8String:title]];
        [w setRepresentedFilename:path != NULL ? [NSString stringWithUTF8String:path] : @""];
        [w setDocumentEdited:edited != 0];
    }
}

// ── Licenses ───────────────────────────────────────────────────────────

// Show the license files in Finder: the app's Contents/Resources/Licenses,
// or NOTICE in a dev build (both relative to the working directory).
void slab_show_licenses(void) {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *cwd = [fm currentDirectoryPath];
        for (NSString *name in @[ @"Licenses", @"NOTICE" ]) {
            NSString *path = [cwd stringByAppendingPathComponent:name];
            if (![fm fileExistsAtPath:path]) continue;
            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
            return;
        }
    }
}
