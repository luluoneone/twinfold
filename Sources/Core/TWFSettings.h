// Finder 設定ウインドウのツールバー（一般・タグ・サイドバー・詳細）の右に
// 「Twinfold」タブを足し、選ばれたら Twinfold の設定画面を重ねて表示する。
#pragma once
#import <AppKit/AppKit.h>

@class TWFQuickWindow;

@interface TWFSettings : NSObject
- (instancetype)initWithPrefs:(NSUserDefaults *)prefs quickWindow:(TWFQuickWindow *)quickWindow;
// Finder 設定を開いて Twinfold のタブを選ぶ
- (void)openPane;
@end

// dylib と同じ場所（Twinfold.app/Contents/Resources）にあるファイル
NSString *TWFResourcePath(NSString *name);
// dylib を含む Twinfold.app
NSURL *TWFAgentAppURL(void);
