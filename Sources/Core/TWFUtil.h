// Finder 内で使う共通処理。Finder の内部クラスには依存せず、
// メニュー項目はアクション名（言語に依存しない）で探す。
#pragma once
#import <AppKit/AppKit.h>
#import <os/log.h>

os_log_t TWFLog(void);

NSMenuItem *TWFFindMenuItem(NSMenu *menu, SEL action);
// メニュー項目の有効状態を確かめてから実行する。実行できなければ NO
BOOL TWFPerformMenuAction(SEL action);

// Finder のファイル表示ウインドウか（デスクトップ、情報、設定などは除く）
BOOL TWFIsBrowserWindow(NSWindow *w);
// 名前の変更や検索欄など、文字を入力中か
BOOL TWFIsTextEditing(void);
NSScreen *TWFScreenUnderMouse(void);
void TWFActivateFinder(void);

// 前面の Finder ウインドウが表示しているフォルダ。フォルダでなければ nil
NSString *TWFFrontWindowFolderPath(void);
// 新しい Finder ウインドウを作り、作られた NSWindow を返す（作れなければ nil）
void TWFCreateBrowserWindow(NSString *folderPath, void (^completion)(NSWindow *window));
