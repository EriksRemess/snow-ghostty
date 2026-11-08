#import "application.h"
#import "window.h"
#import "terminal.h"
#import "session.h"
#import "desktop.h"
#import "menus.h"
#import "config.h"
#import <ApplicationServices/ApplicationServices.h>
#include <unistd.h>

SnowApplicationState snow_app={0};

@implementation AppDelegate
- (id)initWithFD:(int)master child:(pid_t)child
{
    self=[super init];
    if (self) {
        initial_fd=master; initial_pid=child; controllers=[[NSMutableArray alloc] init];
        snow_install_menus(self); [NSApp setServicesProvider:self];
        NSNotificationCenter *center=[NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(updateSecureKeyboardEntry:) name:NSWindowDidBecomeKeyNotification object:nil];
        [center addObserver:self selector:@selector(updateSecureKeyboardEntry:) name:NSWindowDidResignKeyNotification object:nil];
    }
    return self;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    (void)note; finished_launch=YES;
    [self performSelector:@selector(createWindow:) withObject:nil afterDelay:0.2];
}
- (TerminalWindowController *)activeController
{
    for (TerminalWindowController *controller in controllers) if ([controller ownsWindow:[NSApp keyWindow]]) return controller;
    for (TerminalWindowController *controller in controllers) if ([controller ownsWindow:[NSApp mainWindow]]) return controller;
    return [controllers lastObject];
}
- (TerminalWindowController *)controllerForTerminal:(TerminalView *)terminal
{
    for (TerminalWindowController *controller in controllers) if ([[controller terminals] containsObject:terminal]) return controller;
    return nil;
}
- (NSArray *)terminalWindows { return [controllers valueForKey:@"terminalWindow"]; }
- (TerminalWindowController *)openWindowWithFD:(int)master child:(pid_t)child retainOutput:(BOOL)retain diagnostics:(BOOL)diagnostics
{
    TerminalWindowController *previous=[self activeController]; [previous restoreFromFullscreen];
    NSWindow *previousWindow=[previous terminalWindow];
    TerminalWindowController *controller=[[[TerminalWindowController alloc] initWithFD:master child:child retainOutput:retain owner:self] autorelease];
    [controller setDiagnostics:diagnostics]; [controllers addObject:controller]; [controller createWindow:nil];
    if (previousWindow) {
        NSWindow *window=[controller terminalWindow]; NSRect frame=[previousWindow frame];
        [window setFrameTopLeftPoint:NSMakePoint(NSMinX(frame)+24,NSMaxY(frame)-24)];
        [window setFrame:[window constrainFrameRect:[window frame] toScreen:[previousWindow screen]] display:YES];
    }
    return controller;
}
- (void)createWindow:(id)sender
{
    (void)sender;
    if (initial_consumed) return; initial_consumed=YES;
    int master=initial_fd; pid_t child=initial_pid; initial_fd=-1; initial_pid=0;
    if (routed_launch) { snow_session_close(master,child); return; }
    [self openWindowWithFD:master child:child retainOutput:snow_app.keep_on_exit diagnostics:YES];
}
- (void)newWindow:(id)sender
{
    (void)sender;
    if (!initial_consumed && !routed_launch) { [self createWindow:nil]; return; }
    if (!initial_consumed) [self createWindow:nil];
    int master=-1; pid_t child=0;
    if (!snow_session_spawn(NULL,getenv("HOME"),NULL,NULL,&master,&child)) {
        NSAlert *alert=[[[NSAlert alloc] init] autorelease]; [alert setMessageText:@"Could not start a new terminal session."]; [alert runModal]; return;
    }
    [self openWindowWithFD:master child:child retainOutput:NO diagnostics:NO];
}
- (BOOL)launchArguments:(NSArray *)arguments error:(NSString **)error
{
    if (!arguments) return NO;
    NSString *directory=nil,*file=nil,*url=nil;
    for (NSUInteger i=0;i<[arguments count];i++) {
        NSString *option=[arguments objectAtIndex:i];
        if (i+1>=[arguments count]) { if(error)*error=@"Missing session argument."; return NO; }
        NSString *value=[arguments objectAtIndex:++i];
        if ([option isEqualToString:@"--working-directory"]) directory=value;
        else if ([option isEqualToString:@"--execute-file"]) file=value;
        else if ([option isEqualToString:@"--ssh"]) url=value;
        else { if(error)*error=@"Invalid session argument."; return NO; }
    }
    if (file && url) { if(error)*error=@"Choose a script or SSH connection."; return NO; }
    if (file) {
        NSArray *checked=snow_file_arguments(file,NO,error);
        if (!checked || ![[checked objectAtIndex:0] isEqualToString:@"--execute-file"]) return NO;
        file=[checked objectAtIndex:1]; if(!directory)directory=[file stringByDeletingLastPathComponent];
    }
    if (directory) {
        BOOL isDirectory=NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
            if(error)*error=@"Working directory must be an existing folder."; return NO;
        }
    }
    NSArray *ssh=url ? snow_ssh_arguments(url,error) : nil;
    if (url && !ssh) return NO;
    char **ssh_argv=NULL;
    if (ssh) {
        ssh_argv=calloc([ssh count]+1,sizeof(char *)); if(!ssh_argv)return NO;
        for (NSUInteger i=0;i<[ssh count];i++) ssh_argv[i]=strdup([[ssh objectAtIndex:i] UTF8String]);
    }
    int master=-1; pid_t child=0;
    BOOL ok=snow_session_spawn(NULL,directory ? [directory fileSystemRepresentation] : getenv("HOME"),
        file ? [file fileSystemRepresentation] : NULL,ssh_argv,&master,&child);
    if (ssh_argv) { for (char **arg=ssh_argv;*arg;arg++) free(*arg); free(ssh_argv); }
    if (!ok) { if(error)*error=@"Could not start the terminal session."; return NO; }
    if (!initial_consumed) routed_launch=YES;
    [self openWindowWithFD:master child:child retainOutput:file || url diagnostics:NO]; return YES;
}
- (BOOL)application:(NSApplication *)app openFile:(NSString *)path
{
    (void)app; NSString *error=nil;
    if (!finished_launch && snow_app.explicit_cli) return YES;
    BOOL ok=[self launchArguments:snow_file_arguments(path,NO,&error) error:&error];
    if (!ok) { NSAlert *alert=[[[NSAlert alloc] init] autorelease]; [alert setMessageText:error ?: @"Could not open this file."]; [alert runModal]; }
    return ok;
}
- (void)handleURL:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply
{
    (void)reply; NSString *text=[[event paramDescriptorForKeyword:keyDirectObject] stringValue],*error=nil;
    if (!snow_ssh_arguments(text,&error) || ![self launchArguments:[NSArray arrayWithObjects:@"--ssh",text,nil] error:&error]) {
        NSAlert *alert=[[[NSAlert alloc] init] autorelease]; [alert setMessageText:error ?: @"Could not open SSH URL."]; [alert runModal];
    }
}
- (void)openTerminalHere:(NSPasteboard *)pasteboard userData:(NSString *)data error:(NSString **)error
{
    (void)data; NSArray *paths=[pasteboard propertyListForType:NSFilenamesPboardType];
    if (![paths count]) { NSString *path=[pasteboard stringForType:NSStringPboardType]; if(path)paths=[NSArray arrayWithObject:path]; }
    if (![paths count]) { if(error)*error=@"Select a folder or file in Finder."; return; }
    for (NSString *path in paths) if (![self launchArguments:snow_file_arguments(path,YES,error) error:error]) return;
}
- (void)makeDefaultTerminal:(id)sender
{
    (void)sender; NSString *error=nil; BOOL ok=snow_make_default(&error);
    NSAlert *alert=[[[NSAlert alloc] init] autorelease];
    [alert setMessageText:ok ? @"Snow Ghostty opens .command files and SSH links by default." : error]; [alert runModal];
}
- (void)newTab:(id)sender
{
    TerminalWindowController *controller=[self activeController];
    if (controller) [controller newTab:sender]; else [self newWindow:sender];
}
- (void)closeTab:(id)sender
{
    TerminalWindowController *controller=[self activeController];
    if (controller) [controller closeTab:sender]; else [[NSApp keyWindow] performClose:sender];
}
- (void)closeWindow:(id)sender
{
    TerminalWindowController *controller=[self activeController];
    if (controller) [controller closeWindow:sender]; else [[NSApp keyWindow] performClose:sender];
}
- (void)nextTab:(id)sender { [[self activeController] nextTab:sender]; }
- (void)previousTab:(id)sender { [[self activeController] previousTab:sender]; }
- (void)cycleWindow:(NSInteger)direction
{
    NSInteger count=[controllers count]; if(count<2)return;
    TerminalWindowController *current=[self activeController]; [current restoreFromFullscreen];
    NSInteger index=[controllers indexOfObjectIdenticalTo:current];
    TerminalWindowController *next=[controllers objectAtIndex:(index+count+direction)%count];
    NSWindow *window=[next terminalWindow]; if ([window isMiniaturized]) [window deminiaturize:nil];
    [[[next terminalTabs] window] makeKeyAndOrderFront:nil];
}
- (void)nextWindow:(id)sender { (void)sender; [self cycleWindow:1]; }
- (void)previousWindow:(id)sender { (void)sender; [self cycleWindow:-1]; }
- (void)showAbout:(id)sender { (void)sender; [[self activeController] restoreFromFullscreen]; snow_show_about(ghostty_version()); }
- (void)showHelp:(id)sender
{
    (void)sender; [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/EriksRemess/snow-ghostty/blob/main/USAGE.md"]];
}
- (BOOL)openConfigInEditor:(NSString *)path
{
    NSWorkspace *workspace=[NSWorkspace sharedWorkspace];
    CFStringRef identifier=LSCopyDefaultRoleHandlerForContentType(CFSTR("public.plain-text"),kLSRolesEditor);
    NSString *editor=identifier ? [workspace absolutePathForAppBundleWithIdentifier:(NSString *)identifier] : nil;
    if (identifier) CFRelease(identifier);
    return editor ? [workspace openFile:path withApplication:editor] : [workspace openFile:path];
}
- (void)showSettings:(id)sender
{
    (void)sender; [[self activeController] restoreFromFullscreen];
    NSString *path=imac_config_path();
    if (!path || ![self openConfigInEditor:path]) {
        NSAlert *alert=[[[NSAlert alloc] init] autorelease];
        [alert setMessageText:@"Could not open the configuration file in the default editor."];
        [alert setInformativeText:path ?: @"No configuration file is loaded."]; [alert runModal];
    }
}
- (NSMenu *)applicationDockMenu:(NSApplication *)sender
{
    (void)sender; NSMenu *menu=[[[NSMenu alloc] initWithTitle:@"Snow Ghostty"] autorelease];
    NSMenuItem *item=[menu addItemWithTitle:@"New Window" action:@selector(newWindow:) keyEquivalent:@""];
    [item setTarget:self]; return menu;
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible
{
    (void)sender;
    if (![controllers count]) [self newWindow:nil];
    else if (!visible) { NSWindow *window=[[self activeController] terminalWindow]; [window deminiaturize:nil]; [window makeKeyAndOrderFront:nil]; }
    return YES;
}
- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if ([item action]==@selector(toggleSecureKeyboardEntry:)) { [item setState:secure_requested ? NSOnState : NSOffState]; return YES; }
    if ([item action]==@selector(reloadConfiguration:)) return YES;
    if ([item action]==@selector(nextWindow:) || [item action]==@selector(previousWindow:)) return [controllers count]>1;
    if ([item action]==@selector(newTab:) || [item action]==@selector(newWindow:)) return YES;
    if ([item action]==@selector(showAbout:) || [item action]==@selector(showHelp:) || [item action]==@selector(showSettings:) || [item action]==@selector(makeDefaultTerminal:)) return YES;
    TerminalWindowController *controller=[self activeController];
    if (controller) return [controller validateMenuItem:item];
    if ([item action]==@selector(closeTab:) || [item action]==@selector(closeWindow:)) return ([[NSApp keyWindow] styleMask]&NSClosableWindowMask)!=0;
    return NO;
}
- (TerminalView *)addTabWithFD:(int)master child:(pid_t)child retainOutput:(BOOL)retain
{
    TerminalWindowController *controller=[self activeController];
    if (!controller) controller=[self openWindowWithFD:master child:child retainOutput:retain diagnostics:NO];
    else return [controller addTabWithFD:master child:child retainOutput:retain];
    return (TerminalView *)[[[controller terminalTabs] selectedTabViewItem] view];
}
- (void)removeTerminal:(TerminalView *)terminal { [[self controllerForTerminal:terminal] removeTerminal:terminal]; }
- (void)closeTabItem:(NSTabViewItem *)item { [[self controllerForTerminal:[item view]] closeTabItem:item]; }
- (NSInteger)runCloseAlert:(NSAlert *)alert { return [alert runModal]; }
- (void)windowClosed:(TerminalWindowController *)controller
{
    [controllers removeObjectIdenticalTo:controller]; [self updateSecureKeyboardEntry:nil];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { (void)app; return NO; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app
{
    (void)app; if(terminating)return NSTerminateNow;
    NSMutableArray *terminals=[NSMutableArray array];
    for (TerminalWindowController *controller in controllers) [terminals addObjectsFromArray:[controller terminals]];
    if ([[self activeController] confirmClosing:terminals action:@"Quit"] || ![controllers count]) { terminating=YES; return NSTerminateNow; }
    return NSTerminateCancel;
}
- (void)applicationWillTerminate:(NSNotification *)note
{
    (void)note; [NSObject cancelPreviousPerformRequestsWithTarget:self];
    secure_requested=NO; [self updateSecureKeyboardEntry:nil];
    for (TerminalWindowController *controller in controllers) [controller shutdown];
    snow_session_close(initial_fd,initial_pid); initial_fd=-1; initial_pid=0;
    if (snow_app.self_test || snow_app.integration_test) exit(snow_app.test_result);
}
- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    secure_requested=NO; [self updateSecureKeyboardEntry:nil];
    for (TerminalWindowController *controller in controllers) [controller shutdown];
    [controllers release]; [super dealloc];
}
@end
