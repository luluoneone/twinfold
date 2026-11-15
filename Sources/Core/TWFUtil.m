#import "TWFUtil.h"

os_log_t TWFLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.lulu.twinfold", "core"); });
    return log;
}

NSMenuItem *TWFFindMenuItem(NSMenu *menu, SEL action) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == action) return item;
        if (item.submenu) {
            NSMenuItem *found = TWFFindMenuItem(item.submenu, action);
            if (found) return found;
        }
    }
    return nil;
}

BOOL TWFPerformMenuAction(SEL action) {
    NSMenuItem *item = TWFFindMenuItem(NSApp.mainMenu, action);
    if (!item) {
        os_log_error(TWFLog(), "menu action not found: %{public}s", sel_getName(action));
        return NO;
    }
    NSMenu *menu = item.menu;
    [menu update];
    if (!item.isEnabled) return NO;
    [menu performActionForItemAtIndex:[menu indexOfItem:item]];
    return YES;
}

BOOL TWFIsBrowserWindow(NSWindow *w) {
    // 隠した クイックウインドウはキーウインドウのまま残ることがあるので、見えていないものは対象にしない
    if (!w || !w.isVisible || [w isKindOfClass:NSPanel.class]) return NO;
    NSWindowStyleMask need = NSWindowStyleMaskTitled | NSWindowStyleMaskResizable;
    if ((w.styleMask & need) != need) return NO;
    return w.toolbar != nil;
}

BOOL TWFIsTextEditing(void) {
    NSResponder *r = NSApp.keyWindow.firstResponder;
    return [r isKindOfClass:NSText.class] || [r isKindOfClass:NSTextField.class];
}

NSScreen *TWFScreenUnderMouse(void) {
    NSPoint p = NSEvent.mouseLocation;
    for (NSScreen *s in NSScreen.screens) {
        if (NSMouseInRect(p, s.frame, NO)) return s;
    }
    return NSScreen.mainScreen;
}

void TWFActivateFinder(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
}

static NSString *TWFAppleScriptString(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    return [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

static NSAppleEventDescriptor *TWFRunScript(NSString *source) {
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&error];
    if (!result) {
        os_log(TWFLog(), "AppleScript failed: %{public}@", error[NSAppleScriptErrorMessage]);
    }
    return result;
}

NSString *TWFFrontWindowFolderPath(void) {
    // Finder 自身への AppleEvent は同じプロセス内で処理されるので、オートメーションの許可は要らない
    NSAppleEventDescriptor *r = TWFRunScript(
        @"tell application \"Finder\"\n"
        @"  if (count of Finder windows) is 0 then return \"\"\n"
        @"  try\n"
        @"    return POSIX path of (target of Finder window 1 as alias)\n"
        @"  on error\n"
        @"    return \"\"\n"
        @"  end try\n"
        @"end tell");
    NSString *path = r.stringValue;
    return path.length ? path : nil;
}

static NSWindow *TWFNewBrowserWindowSince(NSArray<NSWindow *> *before) {
    for (NSWindow *w in NSApp.orderedWindows) {
        if (![before containsObject:w] && TWFIsBrowserWindow(w)) return w;
    }
    for (NSWindow *w in NSApp.windows) {
        if (![before containsObject:w] && TWFIsBrowserWindow(w)) return w;
    }
    return nil;
}

static void TWFWaitForNewWindow(NSArray<NSWindow *> *before, int triesLeft, void (^completion)(NSWindow *)) {
    NSWindow *w = TWFNewBrowserWindowSince(before);
    if (w || triesLeft <= 0) {
        if (!w) os_log_error(TWFLog(), "new Finder window did not appear");
        completion(w);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        TWFWaitForNewWindow(before, triesLeft - 1, completion);
    });
}

void TWFCreateBrowserWindow(NSString *folderPath, void (^completion)(NSWindow *window)) {
    NSArray<NSWindow *> *before = NSApp.windows;
    BOOL requested = NO;
    if (folderPath.length) {
        NSString *src = [NSString stringWithFormat:
            @"tell application \"Finder\" to make new Finder window to (POSIX file \"%@\")",
            TWFAppleScriptString(folderPath)];
        requested = TWFRunScript(src) != nil;
    }
    if (!requested) requested = TWFPerformMenuAction(NSSelectorFromString(@"cmdNewFinderWindow:"));
    if (!requested) {
        completion(nil);
        return;
    }
    TWFWaitForNewWindow(before, 20, ^(NSWindow *w) {
        // 「タブで開く」設定のときは既存のウインドウのタブになるので、独立したウインドウに戻す
        if (w && w.tabbedWindows.count > 1) [w moveTabToNewWindow:nil];
        completion(w);
    });
}
