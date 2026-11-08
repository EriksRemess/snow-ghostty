#import "window.h"
#import "application.h"
#import "terminal.h"
#import "session.h"
#import "tabs.h"
#include <unistd.h>

@implementation TerminalWindowController
- (id)initWithFD:(int)master child:(pid_t)child retainOutput:(BOOL)retain owner:(AppDelegate *)application
{
    self=[super init]; if(self) { fd=master; pid=child; retained_launch=retain; owner=application; } return self;
}
- (TerminalView *)addTabWithFD:(int)master child:(pid_t)child retainOutput:(BOOL)retain
{
    NSTabViewItem *item=[[[NSTabViewItem alloc] initWithIdentifier:nil] autorelease];
    TerminalView *terminal=[[[TerminalView alloc] initWithFrame:[tabs contentRect] fd:master child:child] autorelease];
    terminal->tab_item=item; terminal->tab_host=tabs; terminal->retain_output=retain;
    [terminal setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];
    [item setLabel:@"Snow Ghostty"]; [item setView:terminal]; [item setInitialFirstResponder:terminal];
    [tabs addTabViewItem:item]; [tabs selectTabViewItem:item];
    [[tabs window] makeKeyAndOrderFront:nil]; [[tabs window] makeFirstResponder:terminal];
    [terminal reshape]; snow_session_start(master);
    [terminal updateTitle];
    return terminal;
}
- (void)newTab:(id)sender
{
    (void)sender; int master=-1; pid_t child=0;
    if (!snow_session_spawn(NULL,getenv("HOME"),NULL,NULL,&master,&child)) {
        NSAlert *alert=[[[NSAlert alloc] init] autorelease];
        [alert setMessageText:@"Could not start a new terminal session."]; [alert runModal]; return;
    }
    [self addTabWithFD:master child:child retainOutput:NO];
}
- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)item
{
    (void)tabView;
    view=(TerminalView *)[item view];
    [[tabs window] setTitle:[item label]];
    [[tabs window] makeFirstResponder:view];
    [[view openGLContext] update]; [view reshape]; [view setNeedsDisplay:YES];
    [(SnowTabView *)tabs refreshTabLabels];
}
- (void)removeTerminal:(TerminalView *)terminal
{
    NSTabViewItem *item=nil;
    for (NSTabViewItem *candidate in [tabs tabViewItems]) if ([candidate view]==terminal) { item=candidate; break; }
    if (!item) return;
    if ([tabs numberOfTabViewItems]==1) { [self closeWithoutConfirmation]; return; }
    [terminal closeSession]; [tabs removeTabViewItem:item];
    view=(TerminalView *)[[tabs selectedTabViewItem] view];
    [[tabs window] makeFirstResponder:view]; [view reshape]; [view setNeedsDisplay:YES];
}
- (NSInteger)runCloseAlert:(NSAlert *)alert { return [owner runCloseAlert:alert]; }
- (BOOL)confirmClosing:(NSArray *)terminals action:(NSString *)action
{
    if (confirming_close) return NO;
    NSMutableSet *names=[NSMutableSet set];
    for (TerminalView *terminal in terminals) [names addObjectsFromArray:snow_session_running_jobs(terminal->child,terminal->retain_output)];
    if (![names count]) return YES;
    confirming_close=YES;
    NSAlert *alert=[[[NSAlert alloc] init] autorelease];
    [alert setAlertStyle:NSWarningAlertStyle];
    [alert setMessageText:[action isEqualToString:@"Quit"] ? @"Quit Snow Ghostty?" : [action stringByAppendingString:@"?"]];
    [alert setInformativeText:[NSString stringWithFormat:@"Running processes: %@.\nClosing will end their terminal sessions.",
        [[[names allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)] componentsJoinedByString:@", "]]];
    [alert addButtonWithTitle:@"Cancel"]; [alert addButtonWithTitle:action];
    [[[alert buttons] objectAtIndex:0] setKeyEquivalent:@"\r"];
    [[[alert buttons] objectAtIndex:1] setKeyEquivalent:@""];
    // Put the native panel above the temporary view-fullscreen window without
    // leaving fullscreen when the user cancels.
    [[alert window] setLevel:MAX(NSModalPanelWindowLevel,[[tabs window] level]+1)];
    NSInteger response=NSAlertFirstButtonReturn;
    @try { response=[self runCloseAlert:alert]; }
    @finally {
        confirming_close=NO;
        for (TerminalView *terminal in deferred_exits)
            [self performSelector:@selector(terminalExited:) withObject:terminal afterDelay:0];
        [deferred_exits removeAllObjects];
    }
    [[tabs window] makeKeyAndOrderFront:nil]; [[tabs window] makeFirstResponder:view];
    return response==NSAlertSecondButtonReturn;
}
- (void)terminalExited:(TerminalView *)terminal
{
    if (confirming_close) {
        if (!deferred_exits) deferred_exits=[[NSMutableArray alloc] init];
        if (![deferred_exits containsObject:terminal]) [deferred_exits addObject:terminal];
        return;
    }
    [self removeTerminal:terminal];
}
- (void)closeTabItem:(NSTabViewItem *)item
{
    TerminalView *terminal=[item view];
    if ([self confirmClosing:[NSArray arrayWithObject:terminal] action:@"Close Tab"]) [self removeTerminal:terminal];
}
- (void)closeTab:(id)sender
{
    (void)sender;
    if ([NSApp keyWindow]!=[tabs window]) { [[NSApp keyWindow] performClose:nil]; return; }
    [self closeTabItem:[tabs selectedTabViewItem]];
}
- (void)closeWindow:(id)sender
{
    (void)sender;
    if ([NSApp keyWindow]==[tabs window]) {
        if (![self confirmClosing:[[tabs tabViewItems] valueForKey:@"view"] action:@"Close Window"]) return;
        [self closeWithoutConfirmation];
    }
    else [[NSApp keyWindow] performClose:nil];
}
- (void)nextTab:(id)sender
{
    (void)sender; NSInteger count=[tabs numberOfTabViewItems];
    if (count) [tabs selectTabViewItemAtIndex:([tabs indexOfTabViewItem:[tabs selectedTabViewItem]]+1)%count];
}
- (void)previousTab:(id)sender
{
    (void)sender; NSInteger count=[tabs numberOfTabViewItems];
    if (count) [tabs selectTabViewItemAtIndex:([tabs indexOfTabViewItem:[tabs selectedTabViewItem]]+count-1)%count];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    BOOL terminal=[NSApp keyWindow]==[tabs window];
    if ([item action]==@selector(closeTab:)) {
        [item setTitle:terminal ? @"Close Tab" : @"Close"];
        return terminal || ([[NSApp keyWindow] styleMask]&NSClosableWindowMask)!=0;
    }
    if ([item action]==@selector(closeWindow:)) return terminal || ([[NSApp keyWindow] styleMask]&NSClosableWindowMask)!=0;
    if ([item action]==@selector(nextTab:) || [item action]==@selector(previousTab:))
        return terminal && [tabs numberOfTabViewItems]>1;
    return YES;
}
- (void)createWindow:(id)sender
{
    (void)sender;
    window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,916,616)
        styleMask:NSTitledWindowMask|NSClosableWindowMask|NSMiniaturizableWindowMask|NSResizableWindowMask|NSTexturedBackgroundWindowMask
        backing:NSBackingStoreBuffered defer:NO];
    [window setAutorecalculatesContentBorderThickness:NO forEdge:NSMaxYEdge];
    [window setContentBorderThickness:0 forEdge:NSMaxYEdge];
    [window setMovableByWindowBackground:NO];
    [window setTitle:@"Snow Ghostty"]; [window setReleasedWhenClosed:NO]; [window setDelegate:self];
    [window setMinSize:NSMakeSize(320,200)];
    tabs=[[SnowTabView alloc] initWithFrame:[[window contentView] bounds]];
    [tabs setTabViewType:NSNoTabsNoBorder]; [tabs setAllowsTruncatedLabels:YES];
    [tabs setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable]; [tabs setDelegate:self];
    [window setContentView:tabs];
    view=[self addTabWithFD:fd child:pid retainOutput:retained_launch]; fd=-1; pid=0;
    [window center]; [window makeKeyAndOrderFront:nil]; [window makeFirstResponder:view];
    [NSApp activateIgnoringOtherApps:YES];
    if (initial_diagnostics) [view startDiagnostics];
}
- (BOOL)windowShouldClose:(id)sender
{
    return sender!=window || [self confirmClosing:[self terminals] action:@"Close Window"];
}
- (void)windowWillClose:(NSNotification *)note
{
    if ([note object]!=window) return;
    [[self retain] autorelease]; [self shutdown]; [owner windowClosed:self];
}
- (void)closeWithoutConfirmation
{
    if (closed) return;
    [[self retain] autorelease]; [self shutdown]; [window close]; [owner windowClosed:self];
}
- (void)shutdown
{
    if (closed) return; closed=YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    if ([tabs isInFullScreenMode]) [tabs exitFullScreenModeWithOptions:nil];
    for (TerminalView *terminal in [self terminals]) [terminal closeSession];
    snow_session_close(fd,pid); fd=-1; pid=0;
    [window setDelegate:nil]; [tabs setDelegate:nil];
}
- (void)setDiagnostics:(BOOL)enabled { initial_diagnostics=enabled; }
- (NSWindow *)terminalWindow { return window; }
- (NSTabView *)terminalTabs { return tabs; }
- (NSArray *)terminals { return [[tabs tabViewItems] valueForKey:@"view"] ?: [NSArray array]; }
- (BOOL)ownsWindow:(NSWindow *)candidate { return candidate && (candidate==window || candidate==[tabs window]); }
- (void)restoreFromFullscreen { if ([view isTerminalFullscreen]) [view toggleFullscreen:nil]; }
- (void)dealloc
{
    [self shutdown]; [deferred_exits release]; [tabs release]; [window release]; [super dealloc];
}
@end
