#import "application.h"
#import "window.h"
#import "terminal.h"
#import "config.h"
#import <Carbon/Carbon.h>

@implementation AppDelegate (Settings)
- (void)configurationReloadFailed
{
    NSAlert *alert=[[[NSAlert alloc] init] autorelease];
    [alert setMessageText:@"Could not reload configuration."];
    [alert setInformativeText:imac_config_error() ?: @"The current settings have been preserved."];
    [[alert window] setLevel:MAX(NSModalPanelWindowLevel,[[[[self activeController] terminalTabs] window] level]+1)];
    [alert runModal];
}
- (void)reloadConfiguration:(id)sender
{
    (void)sender;
    if (!imac_config_reload()) { [self configurationReloadFailed]; return; }
    for (TerminalWindowController *controller in controllers)
        for (TerminalView *view in [controller terminals]) [view applyConfiguration];
}
- (BOOL)secureKeyboardEntryEnabled { return secure_requested; }
- (BOOL)secureKeyboardEntryActive { return secure_active; }
- (void)updateSecureKeyboardEntry:(NSNotification *)note
{
    BOOL resigned=[[note name] isEqualToString:NSWindowDidResignKeyNotification];
    BOOL desired=secure_requested && !secure_suspended && !resigned && [NSApp isActive] &&
        [[self activeController] ownsWindow:[NSApp keyWindow]];
    if (desired==secure_active) return;
    OSStatus status=desired ? EnableSecureEventInput() : DisableSecureEventInput();
    if (status==noErr) secure_active=desired;
    else fprintf(stderr,"Could not %s secure keyboard entry: %ld\n",desired ? "enable" : "disable",(long)status);
}
- (void)toggleSecureKeyboardEntry:(id)sender
{
    (void)sender; secure_requested=!secure_requested; [self updateSecureKeyboardEntry:nil];
    if (secure_requested && !secure_active && [NSApp isActive] &&
        [[self activeController] ownsWindow:[NSApp keyWindow]]) {
        secure_requested=NO;
        NSAlert *alert=[[[NSAlert alloc] init] autorelease];
        [alert setMessageText:@"Could not enable Secure Keyboard Entry."];
        [alert runModal];
    }
}
- (void)applicationDidBecomeActive:(NSNotification *)note { secure_suspended=NO; [self updateSecureKeyboardEntry:note]; }
- (void)applicationWillResignActive:(NSNotification *)note
{
    (void)note; secure_suspended=YES;
    if (secure_active) {
        OSStatus status=DisableSecureEventInput();
        if (status==noErr) secure_active=NO;
        else fprintf(stderr,"Could not release secure keyboard entry: %ld\n",(long)status);
    }
}
@end
