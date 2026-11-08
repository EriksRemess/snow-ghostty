#pragma once
#import <Cocoa/Cocoa.h>
@class AppDelegate, TerminalView;

@interface TerminalWindowController : NSObject <NSWindowDelegate,NSTabViewDelegate> {
    NSWindow *window;
    TerminalView *view;
    NSTabView *tabs;
    int fd; pid_t pid;
    BOOL retained_launch, initial_diagnostics, confirming_close, closed;
    NSMutableArray *deferred_exits;
    AppDelegate *owner; // application owns its window controllers
}
- (id)initWithFD:(int)master child:(pid_t)child retainOutput:(BOOL)retain owner:(AppDelegate *)application;
- (void)createWindow:(id)sender;
- (void)newTab:(id)sender;
- (void)closeTab:(id)sender;
- (void)closeWindow:(id)sender;
- (void)nextTab:(id)sender;
- (void)previousTab:(id)sender;
- (void)terminalExited:(TerminalView *)terminal;
- (TerminalView *)addTabWithFD:(int)master child:(pid_t)child retainOutput:(BOOL)retain;
- (void)removeTerminal:(TerminalView *)terminal;
- (void)closeTabItem:(NSTabViewItem *)item;
- (BOOL)confirmClosing:(NSArray *)terminals action:(NSString *)action;
- (NSInteger)runCloseAlert:(NSAlert *)alert;
- (void)closeWithoutConfirmation;
- (void)shutdown;
- (NSWindow *)terminalWindow;
- (NSTabView *)terminalTabs;
- (NSArray *)terminals;
- (BOOL)ownsWindow:(NSWindow *)candidate;
- (void)restoreFromFullscreen;
- (void)setDiagnostics:(BOOL)enabled;
@end
