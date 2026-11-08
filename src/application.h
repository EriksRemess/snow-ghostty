#pragma once
#import <Cocoa/Cocoa.h>

typedef struct {
    int test_result;
    BOOL self_test, integration_test, keep_on_exit, explicit_cli;
    NSString *requested_capture;
} SnowApplicationState;
extern SnowApplicationState snow_app;

@class TerminalWindowController, TerminalView;
@interface AppDelegate : NSObject <NSApplicationDelegate> {
    NSMutableArray *controllers;
    int initial_fd; pid_t initial_pid;
    BOOL finished_launch, routed_launch, initial_consumed, terminating;
    BOOL secure_requested, secure_active, secure_suspended;
}
- (id)initWithFD:(int)master child:(pid_t)child;
- (void)createWindow:(id)sender;
- (void)newWindow:(id)sender;
- (void)newTab:(id)sender;
- (void)closeTab:(id)sender;
- (void)closeWindow:(id)sender;
- (void)nextTab:(id)sender;
- (void)previousTab:(id)sender;
- (void)nextWindow:(id)sender;
- (void)previousWindow:(id)sender;
- (void)showAbout:(id)sender;
- (void)showHelp:(id)sender;
- (void)showSettings:(id)sender;
- (BOOL)openConfigInEditor:(NSString *)path;
- (void)makeDefaultTerminal:(id)sender;
- (BOOL)launchArguments:(NSArray *)arguments error:(NSString **)error;
- (void)handleURL:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply;
- (void)openTerminalHere:(NSPasteboard *)pasteboard userData:(NSString *)data error:(NSString **)error;
- (TerminalWindowController *)activeController;
- (NSArray *)terminalWindows;
- (void)windowClosed:(TerminalWindowController *)controller;
- (TerminalView *)addTabWithFD:(int)master child:(pid_t)child retainOutput:(BOOL)retain;
- (void)removeTerminal:(TerminalView *)terminal;
- (void)closeTabItem:(NSTabViewItem *)item;
- (NSInteger)runCloseAlert:(NSAlert *)alert;
@end


@interface AppDelegate (Settings)
- (void)reloadConfiguration:(id)sender;
- (void)configurationReloadFailed;
- (void)toggleSecureKeyboardEntry:(id)sender;
- (BOOL)secureKeyboardEntryEnabled;
- (BOOL)secureKeyboardEntryActive;
- (void)updateSecureKeyboardEntry:(NSNotification *)note;
@end
