// 常駐アプリ（Agent）とFinder内のdylib（Core）で共有する名前と既定値。
#pragma once
#import <Foundation/Foundation.h>

#define TWFVersion @"0.4.2"
#define TWFDomain @"com.lulu.twinfold"

// Agent -> Core: object にコマンド名を入れて送る
#define TWFNoteCommand @"com.lulu.twinfold.command"
// Core -> Agent: ping への返事。userInfo に pid と version
#define TWFNotePong @"com.lulu.twinfold.pong"
// Core -> Agent: Finder 設定の画面からの依頼。object に依頼名
#define TWFNoteRequest @"com.lulu.twinfold.request"
#define TWFRequestDisable @"disable"
#define TWFRequestUninstall @"uninstall"
#define TWFAgentBundleID @"com.lulu.twinfold"

#define TWFCommandPing @"ping"
#define TWFCommandToggleQuickWindow @"toggle-quick-window"
#define TWFCommandReloadPrefs @"reload-prefs"
#define TWFCommandOpenSettings @"open-settings"

#define TWFPrefEnabled @"Enabled"  // NO なら組み込まず、通常の Finder のまま
#define TWFPrefQuickWindowEnabled @"QuickWindowEnabled"
#define TWFPrefQuickWindowHideOnDeactivate @"QuickWindowHideOnDeactivate"
#define TWFPrefQuickWindowPinned @"QuickWindowPinned"
#define TWFPrefQuickWindowHeight @"QuickWindowHeightFraction"
#define TWFPrefQuickWindowKeyCode @"QuickWindowKeyCode"
#define TWFPrefQuickWindowModifiers @"QuickWindowModifiers"  // Carbon の修飾キー（optionKey など）
#define TWFPrefQuickWindowKeyLabel @"QuickWindowKeyLabel"     // 表示用のキーの文字
#define TWFPrefAnimationDuration @"AnimationDuration"
#define TWFPrefCutPasteEnabled @"CutPasteEnabled"
#define TWFPrefDualEnabled @"DualEnabled"

static inline NSDictionary *TWFDefaultPrefs(void) {
    return @{
        TWFPrefEnabled: @YES,
        TWFPrefQuickWindowEnabled: @YES,
        TWFPrefQuickWindowHideOnDeactivate: @YES,
        TWFPrefQuickWindowPinned: @NO,
        TWFPrefQuickWindowHeight: @0.45,
        // control＋option＋F。どの配列のキーボードにも刻印があるキーにする（` は日本語配列で見つけにくい）
        TWFPrefQuickWindowKeyCode: @3,          // kVK_ANSI_F
        TWFPrefQuickWindowModifiers: @0x1800,   // controlKey | optionKey
        TWFPrefQuickWindowKeyLabel: @"F",
        TWFPrefAnimationDuration: @0.25,
        TWFPrefCutPasteEnabled: @YES,
        TWFPrefDualEnabled: @YES,
    };
}

// ホットキーの表示（例: ⌥`）。修飾キーの値は Carbon の cmdKey/shiftKey/optionKey/controlKey と同じ
static inline NSString *TWFHotKeyLabel(NSUserDefaults *prefs) {
    NSInteger mods = [prefs integerForKey:TWFPrefQuickWindowModifiers];
    NSMutableString *s = [NSMutableString string];
    if (mods & 0x1000) [s appendString:@"⌃"];
    if (mods & 0x0800) [s appendString:@"⌥"];
    if (mods & 0x0200) [s appendString:@"⇧"];
    if (mods & 0x0100) [s appendString:@"⌘"];
    [s appendString:[prefs stringForKey:TWFPrefQuickWindowKeyLabel] ?: @"?"];
    return s;
}

// ホットキーをキーの名前で並べる（例: control, option, F）。キーボードの刻印と同じ言葉にする
static inline NSArray<NSString *> *TWFHotKeyNames(NSUserDefaults *prefs) {
    NSInteger mods = [prefs integerForKey:TWFPrefQuickWindowModifiers];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (mods & 0x1000) [names addObject:@"control"];
    if (mods & 0x0800) [names addObject:@"option"];
    if (mods & 0x0200) [names addObject:@"shift"];
    if (mods & 0x0100) [names addObject:@"command"];
    NSString *key = [prefs stringForKey:TWFPrefQuickWindowKeyLabel] ?: @"?";
    [names addObject:[key isEqualToString:@"Space"] ? @"スペース" : key];
    return names;
}

// 例: control＋option＋F
static inline NSString *TWFHotKeySpokenLabel(NSUserDefaults *prefs) {
    return [TWFHotKeyNames(prefs) componentsJoinedByString:@"＋"];
}
