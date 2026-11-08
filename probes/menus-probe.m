// Exercise the shared production modules in an isolated native app.
#import "application.h"
#import "window.h"
#import "terminal.h"
#import "config.h"
#import "platform.h"
#import "session.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>
#include <util.h>
#include <sys/ioctl.h>
#import <Carbon/Carbon.h>

static BOOL passed=YES;
static BOOL captureWindow(NSWindow *window, NSString *path);

@interface ModalButtonChooser : NSObject {
@public
    NSAlert *alert;
    NSUInteger choice;
    BOOL clicked;
    NSString *capture;
}
- (void)choose:(NSTimer *)timer;
@end
@implementation ModalButtonChooser
- (void)choose:(NSTimer *)timer
{
    if (![[alert window] isVisible]) return;
    [timer invalidate];
    if (capture) captureWindow([alert window],capture);
    clicked=YES;
    NSButton *button=[[alert buttons] objectAtIndex:choice];
    [NSApp sendAction:[button action] to:[button target] from:button];
    // Timer-driven actions do not supply the mouse-up event that normally
    // wakes Snow Leopard's modal nextEvent loop after stopModalWithCode:.
    [NSApp postEvent:[NSEvent otherEventWithType:NSApplicationDefined location:NSZeroPoint modifierFlags:0
        timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:YES];
}
@end

@interface MenuProbeDelegate : AppDelegate {
@public
    unsigned confirmations, reload_errors;
    NSString *opened_config;
    BOOL cancel_next;
    NSString *last_message, *last_info, *confirmation_capture;
}
@end
@implementation MenuProbeDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note { (void)note; }
- (BOOL)openConfigInEditor:(NSString *)path { [opened_config release]; opened_config=[path copy]; return YES; }
- (void)configurationReloadFailed { reload_errors++; }
- (NSInteger)runCloseAlert:(NSAlert *)alert
{
    confirmations++;
    [last_message release]; last_message=[[alert messageText] copy];
    [last_info release]; last_info=[[alert informativeText] copy];
    ModalButtonChooser *chooser=[[[ModalButtonChooser alloc] init] autorelease];
    chooser->alert=alert; chooser->choice=cancel_next ? 0 : 1; chooser->capture=confirmation_capture; cancel_next=NO;
    NSTimer *timer=[NSTimer timerWithTimeInterval:0.1 target:chooser selector:@selector(choose:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    NSInteger result=[super runCloseAlert:alert]; [timer invalidate];
    if (!chooser->clicked) passed=NO;
    return result;
}
- (void)dealloc { [last_message release]; [last_info release]; [opened_config release]; [super dealloc]; }
@end

static void verify_menu(BOOL ok, const char *message)
{
    fprintf(stderr,"%s: %s\n",message,ok ? "PASS" : "FAIL");
    if (!ok) passed=NO;
}

static void pump(void)
{
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:0.15];
    while ([until timeIntervalSinceNow]>0) {
        NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:until
            inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event) [NSApp sendEvent:event];
        [NSApp updateWindows];
    }
}

static NSMenu *menu(NSString *title) { return [[[NSApp mainMenu] itemWithTitle:title] submenu]; }

static BOOL modifiedShortcut(NSString *text, unsigned short code, NSUInteger modifiers)
{
    NSEvent *event=[NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:modifiers
        timestamp:0 windowNumber:[[NSApp keyWindow] windowNumber] context:nil characters:text
        charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
    return [[NSApp mainMenu] performKeyEquivalent:event];
}
static BOOL shortcut(NSString *text, unsigned short code) { return modifiedShortcut(text,code,NSCommandKeyMask); }

static void waitForTabs(NSTabView *tabs, NSInteger count)
{
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4];
    while ([tabs numberOfTabViewItems]!=count && [deadline timeIntervalSinceNow]>0) pump();
}

static void collectText(NSView *view, NSMutableString *text)
{
    if ([view isKindOfClass:[NSTextField class]]) [text appendFormat:@"%@\n",[(NSTextField *)view stringValue]];
    if ([view isKindOfClass:[NSTextView class]]) [text appendFormat:@"%@\n",[(NSTextView *)view string]];
    for (NSView *child in [view subviews]) collectText(child,text);
}

static BOOL captureWindow(NSWindow *window, NSString *path)
{
    CGImageRef image=CGWindowListCreateImage(CGRectNull,kCGWindowListOptionIncludingWindow,
        (CGWindowID)[window windowNumber],kCGWindowImageBoundsIgnoreFraming);
    if (!image) return NO;
    NSBitmapImageRep *bitmap=[[[NSBitmapImageRep alloc] initWithCGImage:image] autorelease];
    BOOL ok=[[bitmap representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]] writeToFile:path atomically:YES];
    CGImageRelease(image); return ok;
}

typedef struct {
    CGWindowID window;
    CGRect rect;
    pthread_mutex_t lock;
    BOOL stop;
    unsigned samples, bright, unexpected;
    GhosttyColorRgb expected;
    CGImageRef flash;
    FILE *log;
} SwitchTrace;

static void *sampleSwitches(void *data)
{
    SwitchTrace *trace=data;
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB(); uint8_t pixels[8*8*4];
    CGContextRef context=CGBitmapContextCreate(pixels,8,8,8,8*4,space,kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    while (context) {
        pthread_mutex_lock(&trace->lock); BOOL stop=trace->stop; pthread_mutex_unlock(&trace->lock);
        if (stop) break;
        CGImageRef frame=CGWindowListCreateImage(trace->rect,kCGWindowListOptionIncludingWindow,trace->window,kCGWindowImageBoundsIgnoreFraming);
        if (frame) {
            CGContextDrawImage(context,CGRectMake(0,0,8,8),frame);
            unsigned red=0,green=0,blue=0;
            for (int i=0;i<64;i++) { red+=pixels[i*4]; green+=pixels[i*4+1]; blue+=pixels[i*4+2]; }
            red/=64; green/=64; blue/=64; trace->samples++;
            fprintf(trace->log,"%.6f,%u,%u,%u\n",CFAbsoluteTimeGetCurrent(),red,green,blue);
            if (red>100 && green>100 && blue>100) trace->bright++;
            if (abs((int)red-trace->expected.r)>3 || abs((int)green-trace->expected.g)>3 || abs((int)blue-trace->expected.b)>3) {
                trace->unexpected++; if (!trace->flash) trace->flash=CGImageRetain(frame);
            }
            CGImageRelease(frame);
        }
        usleep(2000);
    }
    if (context) CGContextRelease(context); return NULL;
}

static BOOL switchingProbe(AppDelegate *delegate, NSTabView *tabs, TerminalView *first, NSString *prefix)
{
    int master=-1,slave=-1; if (openpty(&master,&slave,NULL,NULL,NULL)<0) return NO;
    fcntl(master,F_SETFL,O_NONBLOCK);
    TerminalView *second=[delegate addTabWithFD:master child:0 retainOutput:NO];
    for (TerminalView *terminal in [NSArray arrayWithObjects:first,second,nil]) {
        const char *fixture="\033[2J\033[HTab switching capture fixture";
        ghostty_terminal_vt_write(terminal->terminal,(const uint8_t *)fixture,strlen(fixture));
        [tabs selectTabViewItem:terminal->tab_item]; pump(); [terminal display];
    }
    NSWindow *window=[tabs window];
    NSArray *windows=(NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,(CGWindowID)[window windowNumber]);
    CGRect bounds=CGRectZero;
    for (NSDictionary *info in windows) if ([[info objectForKey:(id)kCGWindowNumber] intValue]==[window windowNumber])
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)[info objectForKey:(id)kCGWindowBounds],&bounds);
    [windows release];
    SwitchTrace trace={0}; trace.window=(CGWindowID)[window windowNumber]; trace.expected=imac_config.background;
    trace.rect=CGRectMake(CGRectGetMidX(bounds)-32,CGRectGetMidY(bounds)-32,64,64);
    trace.log=fopen([[prefix stringByAppendingString:@".csv"] fileSystemRepresentation],"w");
    if (!trace.log || CGRectIsEmpty(bounds)) return NO;
    pthread_mutex_init(&trace.lock,NULL); pthread_t thread;
    if (pthread_create(&thread,NULL,sampleSwitches,&trace)!=0) return NO;
    for (int i=0;i<32;i++) {
        [tabs selectTabViewItem:(i%2 ? first : second)->tab_item];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:0.06];
        while ([deadline timeIntervalSinceNow]>0) {
            NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:deadline inMode:NSDefaultRunLoopMode dequeue:YES];
            if (event) [NSApp sendEvent:event]; [NSApp updateWindows];
        }
    }
    pthread_mutex_lock(&trace.lock); trace.stop=YES; pthread_mutex_unlock(&trace.lock);
    pthread_join(thread,NULL); pthread_mutex_destroy(&trace.lock); fclose(trace.log);
    if (trace.flash) {
        NSBitmapImageRep *bitmap=[[[NSBitmapImageRep alloc] initWithCGImage:trace.flash] autorelease];
        [[bitmap representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]] writeToFile:[prefix stringByAppendingString:@"-flash.png"] atomically:YES];
        CGImageRelease(trace.flash);
    }
    fprintf(stderr,"Tab-switch sampling: %u samples; %u bright / %u unexpected frames across 32 switches\n",trace.samples,trace.bright,trace.unexpected);
    BOOL ok=trace.samples>=20 && trace.unexpected==0;
    for (NSTabViewItem *item in [tabs tabViewItems]) [(TerminalView *)[item view] closeSession];
    close(slave);
    if ([first isTerminalFullscreen]) [first toggleFullscreen:nil];
    [[tabs window] orderOut:nil]; return ok;
}

static TerminalView *confirmationShell(MenuProbeDelegate *delegate)
{
    int master=-1; pid_t child=0;
    if (!snow_session_spawn("exec /bin/sh -i","/tmp",NULL,NULL,&master,&child)) return nil;
    TerminalView *terminal=[delegate addTabWithFD:master child:child retainOutput:NO]; pump(); return terminal;
}

static BOOL waitForJob(TerminalView *terminal, NSString *name)
{
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4];
    while (![snow_session_running_jobs(terminal->child,terminal->retain_output) containsObject:name] && [deadline timeIntervalSinceNow]>0) pump();
    return [snow_session_running_jobs(terminal->child,terminal->retain_output) containsObject:name];
}

static BOOL confirmationProbe(MenuProbeDelegate *delegate, NSTabView *tabs, TerminalView *first, NSString *prefix, BOOL quit)
{
    NSWindow *window=[tabs window];
    TerminalView *idle=confirmationShell(delegate);
    verify_menu(idle && ![snow_session_running_jobs(idle->child,NO) count],"Idle shell has no running work");
    unsigned before=delegate->confirmations;
    [delegate closeTabItem:idle->tab_item]; pump();
    verify_menu(delegate->confirmations==before && [tabs numberOfTabViewItems]==1,"Idle tab closes without confirmation");
    [delegate newTab:nil]; pump();
    TerminalView *login=(TerminalView *)[[tabs selectedTabViewItem] view];
    NSDate *settled=[NSDate dateWithTimeIntervalSinceNow:5];
    while ([snow_session_running_jobs(login->child,NO) count] && [settled timeIntervalSinceNow]>0) pump();
    verify_menu(![snow_session_running_jobs(login->child,NO) count],"Configured login shell is idle after startup");
    before=delegate->confirmations; [delegate closeTabItem:login->tab_item]; pump();
    verify_menu(delegate->confirmations==before && [tabs numberOfTabViewItems]==1,"Idle login prompt closes without confirmation");

    TerminalView *busy=confirmationShell(delegate); pid_t shell=busy->child;
    [busy typeCommand:@"/bin/sleep 60\n"]; verify_menu(waitForJob(busy,@"sleep"),"Foreground job detected");
    pid_t job=tcgetpgrp(busy->master);
    delegate->cancel_next=YES; delegate->confirmation_capture=[prefix stringByAppendingString:@"-tab.png"];
    before=delegate->confirmations; [delegate closeTab:nil]; pump();
    verify_menu(delegate->confirmations==before+1 && [delegate->last_message isEqualToString:@"Close Tab?"],"Command-W asks once for busy tab");
    verify_menu([tabs numberOfTabViewItems]==2 && kill(shell,0)==0 && kill(job,0)==0,"Cancel preserves foreground job and shell");
    kill(job,SIGSTOP); pump();
    verify_menu([snow_session_running_jobs(shell,NO) containsObject:@"sleep"],"Stopped job also requires confirmation");
    [delegate closeTabItem:busy->tab_item]; pump();
    verify_menu([tabs numberOfTabViewItems]==1 && busy->master==-1,"Accept closes selected busy tab");
    settled=[NSDate dateWithTimeIntervalSinceNow:4];
    while ((kill(shell,0)==0 || kill(job,0)==0) && [settled timeIntervalSinceNow]>0) pump();
    verify_menu(kill(shell,0)<0 && errno==ESRCH && kill(job,0)<0 && errno==ESRCH,"Accepted close terminates stopped job and shell");

    TerminalView *background=confirmationShell(delegate);
    [background typeCommand:@"/bin/sleep 60 &\n"]; verify_menu(waitForJob(background,@"sleep"),"Background job detected behind idle shell");
    delegate->cancel_next=YES; before=delegate->confirmations;
    [delegate closeTabItem:background->tab_item]; pump();
    verify_menu(delegate->confirmations==before+1 && background->master>=0,"Tab close button protects background work");
    [delegate closeTabItem:background->tab_item]; pump();

    TerminalView *hidden=confirmationShell(delegate); shell=hidden->child;
    [hidden typeCommand:@"/bin/sleep 60\n"]; verify_menu(waitForJob(hidden,@"sleep"),"Hidden-tab job fixture ready"); job=tcgetpgrp(hidden->master);
    [tabs selectTabViewItem:first->tab_item]; pump();
    delegate->cancel_next=YES; delegate->confirmation_capture=[prefix stringByAppendingString:@"-window.png"];
    before=delegate->confirmations; [window performClose:nil]; pump();
    verify_menu(delegate->confirmations==before+1 && [delegate->last_message isEqualToString:@"Close Window?"],"Red close button checks inactive tabs once");
    verify_menu([window isVisible] && [tabs numberOfTabViewItems]==2 && kill(job,0)==0,"Cancel preserves whole window and hidden job");

    delegate->cancel_next=YES; before=delegate->confirmations; [NSApp terminate:nil]; pump();
    verify_menu(delegate->confirmations==before+1 && [delegate->last_message isEqualToString:@"Quit Snow Ghostty?"],"Quit checks all tabs once");
    verify_menu([window isVisible] && kill(job,0)==0,"Cancel Quit preserves running work");

    [first toggleFullscreen:nil]; pump();
    delegate->cancel_next=YES; delegate->confirmation_capture=[prefix stringByAppendingString:@"-fullscreen.png"];
    before=delegate->confirmations; [delegate closeWindow:nil]; pump();
    verify_menu(delegate->confirmations==before+1 && [first isTerminalFullscreen] && kill(job,0)==0,
        "Cancel Close Window preserves fullscreen and hidden job");
    [first toggleFullscreen:nil]; pump(); delegate->confirmation_capture=nil;
    if (!passed) { for (NSTabViewItem *item in [tabs tabViewItems]) [(TerminalView *)[item view] closeSession]; return NO; }
    [[NSString stringWithFormat:@"%d %d\n",shell,job] writeToFile:[prefix stringByAppendingString:@".pids"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    fprintf(stderr,"Accepting final %s confirmation\n",quit ? "Quit" : "Close Window");
    if (quit) [NSApp terminate:nil];
    else {
        [window performClose:nil]; pump();
        verify_menu(![[delegate terminalWindows] count] && ![window isVisible],"Last window closes while application remains resident");
        if (passed) [NSApp terminate:nil];
    }
    fputs("Accepted final close did not terminate: FAIL\n",stderr); return NO;
}

static BOOL windowsProbe(MenuProbeDelegate *delegate, NSWindow *firstWindow, TerminalView *first, NSString *prefix)
{
    pid_t application=getpid();
    verify_menu(shortcut(@"n",45),"Command-N creates another native window"); pump();
    NSArray *windows=[delegate terminalWindows];
    verify_menu([windows count]==2 && [[NSApp delegate] isEqual:delegate],"New Window stays in the same application");
    NSWindow *secondWindow=[windows lastObject];
    TerminalWindowController *second=(TerminalWindowController *)[secondWindow delegate];
    TerminalView *secondView=(TerminalView *)[[[second terminalTabs] selectedTabViewItem] view];
    verify_menu(secondWindow!=firstWindow && secondView->master!=first->master && secondView->child>0,"Windows own independent PTYs / shells");

    NSMenu *dock=[delegate applicationDockMenu:NSApp]; NSMenuItem *newWindow=[dock itemWithTitle:@"New Window"];
    verify_menu(newWindow && [newWindow target]==delegate && [newWindow action]==@selector(newWindow:),"Dock menu exposes New Window on application delegate");
    [dock performActionForItemAtIndex:[dock indexOfItem:newWindow]]; pump();
    verify_menu([[delegate terminalWindows] count]==3,"Dock New Window creates a third native window");
    NSWindow *thirdWindow=[[delegate terminalWindows] lastObject];
    TerminalWindowController *third=(TerminalWindowController *)[thirdWindow delegate];
    NSArray *server=(NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
    unsigned owned=0;
    for (NSWindow *window in [delegate terminalWindows]) for (NSDictionary *info in server)
        if ([[info objectForKey:(id)kCGWindowNumber] intValue]==[window windowNumber] &&
            [[info objectForKey:(id)kCGWindowOwnerPID] intValue]==application) owned++;
    [server release]; verify_menu(owned==3,"WindowServer confirms all three windows have one application PID");

    verify_menu(modifiedShortcut(@"`",50,NSCommandKeyMask),"Command-backtick cycles native windows"); pump();
    verify_menu([NSApp keyWindow]==firstWindow,"Forward window cycle selects first window");
    verify_menu(modifiedShortcut(@"~",50,NSCommandKeyMask|NSShiftKeyMask),"Command-Shift-backtick cycles backwards"); pump();
    verify_menu([NSApp keyWindow]==thirdWindow,"Backward cycle selects third window");
    shortcut(@"t",17); pump();
    verify_menu([[third terminalTabs] numberOfTabViewItems]==2 && [[second terminalTabs] numberOfTabViewItems]==1,
        "New Tab affects only the key window");

    [secondView typeCommand:@"/bin/sleep 60\n"]; verify_menu(waitForJob(secondView,@"sleep"),"Background-window running-job fixture ready");
    pid_t job=tcgetpgrp(secondView->master);
    [thirdWindow makeKeyAndOrderFront:nil]; pump(); delegate->cancel_next=YES;
    delegate->confirmation_capture=[prefix stringByAppendingString:@"-quit.png"];
    unsigned before=delegate->confirmations; [NSApp terminate:nil]; pump();
    verify_menu(delegate->confirmations==before+1 && [[delegate terminalWindows] count]==3 && kill(job,0)==0,
        "Cancel Quit protects jobs in other windows with one confirmation");

    [delegate closeWindow:nil]; pump();
    verify_menu([[delegate terminalWindows] count]==2 && kill(job,0)==0 && [firstWindow isVisible],
        "Closing key window preserves sibling windows and their jobs");
    [secondWindow makeKeyAndOrderFront:nil]; pump(); delegate->cancel_next=YES;
    before=delegate->confirmations; [secondWindow performClose:nil]; pump();
    verify_menu(delegate->confirmations==before+1 && [secondWindow isVisible] && kill(job,0)==0,
        "Cancel window close preserves that window's work");
    [secondWindow performClose:nil]; pump();
    verify_menu([[delegate terminalWindows] count]==1 && [firstWindow isVisible] && first->master>=0,
        "Accepted busy-window close leaves first window intact");
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4];
    while (kill(job,0)==0 && [deadline timeIntervalSinceNow]>0) pump();
    verify_menu(kill(job,0)<0 && errno==ESRCH,"Closing one window terminates its foreground job");

    [firstWindow performClose:nil]; pump();
    verify_menu(![[delegate terminalWindows] count],"Closing final window leaves application available in Dock");
    [dock performActionForItemAtIndex:[dock indexOfItem:newWindow]]; pump();
    verify_menu([[delegate terminalWindows] count]==1 && getpid()==application,"Dock New Window reopens resident application");
    TerminalWindowController *last=[delegate activeController];
    TerminalView *lastView=(TerminalView *)[[[last terminalTabs] selectedTabViewItem] view];
    [lastView typeCommand:@"exit\n"];
    deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while ([[delegate terminalWindows] count] && [deadline timeIntervalSinceNow]>0) pump();
    verify_menu(![[delegate terminalWindows] count],"Final shell exit closes its window without quitting application");
    [delegate applicationShouldHandleReopen:NSApp hasVisibleWindows:NO]; pump();
    verify_menu([[delegate terminalWindows] count]==1,"Dock reopen creates a window after all sessions have closed");
    NSString *script=[prefix stringByAppendingString:@".command"];
    [@"#!/bin/sh\nprintf 'NATIVE_WINDOW_SCRIPT_FIXTURE\\n'\nexit 7\n" writeToFile:script atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    chmod([script fileSystemRepresentation],0700);
    verify_menu([delegate application:NSApp openFile:script],"Desktop script opening routes into running application"); pump();
    TerminalWindowController *scriptController=[delegate activeController];
    TerminalView *scriptView=(TerminalView *)[[[scriptController terminalTabs] selectedTabViewItem] view];
    deadline=[NSDate dateWithTimeIntervalSinceNow:4];
    while (scriptView->child && [deadline timeIntervalSinceNow]>0) pump();
    verify_menu([[delegate terminalWindows] count]==2 && scriptView->retain_output &&
        [[scriptView screenText] rangeOfString:@"NATIVE_WINDOW_SCRIPT_FIXTURE"].location!=NSNotFound &&
        [[scriptView screenText] rangeOfString:@"[Process exited: 7]"].location!=NSNotFound,
        "Script gets native window and retains exit output independently");
    [delegate closeWindow:nil]; pump(); unlink([script fileSystemRepresentation]);
    verify_menu([[delegate terminalWindows] count]==1,"Closing script window preserves login window");
    delegate->confirmation_capture=nil;
    if (!passed) return NO;
    [NSApp terminate:nil]; return NO;
}

static NSEvent *navigationEvent(unichar character, unsigned short code, NSUInteger flags)
{
    NSString *text=[NSString stringWithCharacters:&character length:1];
    return [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0
        windowNumber:[[NSApp keyWindow] windowNumber] context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
}
static size_t historyRows(TerminalView *view)
{
    size_t rows=0; core_check(ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS,&rows),"probe history"); return rows;
}
static GhosttyTerminalScrollbar scrollbar(TerminalView *view)
{
    GhosttyTerminalScrollbar bar={0}; core_check(ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&bar),"probe scrollbar"); return bar;
}
static void fixture(TerminalView *view, NSString *text)
{
    NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding]; ghostty_terminal_vt_write(view->terminal,[data bytes],[data length]);
}
static NSString *activeText(TerminalView *view)
{
    GhosttyPoint start={GHOSTTY_POINT_TAG_ACTIVE,{.coordinate={0,0}}};
    GhosttyPoint end={GHOSTTY_POINT_TAG_ACTIVE,{.coordinate={view->columns-1,view->lines-1}}};
    GhosttySelection range={0};
    core_check(ghostty_terminal_grid_ref(view->terminal,start,&range.start),"active text start");
    core_check(ghostty_terminal_grid_ref(view->terminal,end,&range.end),"active text end");
    GhosttyFormatter formatter=NULL; uint8_t *bytes=NULL; size_t length=0;
    core_check(ghostty_formatter_terminal_new(NULL,&formatter,view->terminal),"active formatter");
    core_check(ghostty_formatter_set(formatter,GHOSTTY_FORMATTER_OPT_SELECTION,&range),"active range");
    core_check(ghostty_formatter_format_alloc(formatter,NULL,&bytes,&length),"active format");
    NSString *text=[[[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding] autorelease];
    ghostty_free(NULL,bytes,length); ghostty_formatter_free(formatter); return text;
}
static BOOL controlsProbe(MenuProbeDelegate *delegate, NSWindow *window, NSTabView *tabs, TerminalView *view, int slave, NSString *prefix)
{
    [NSApp activateIgnoringOtherApps:YES]; [window makeKeyAndOrderFront:nil]; [window makeFirstResponder:view]; pump();
    CGFloat initial=imac_config.font_size;
    verify_menu(shortcut(@"+",24) && view->font_size==initial+1,"Command-plus increases active font");
    NSEvent *equal=navigationEvent('=',24,NSCommandKeyMask);
    verify_menu([view performKeyEquivalent:equal] && view->font_size==initial+2,"Command-equals font alias");
    verify_menu(shortcut(@"-",27) && view->font_size==initial+1,"Command-minus decreases active font");
    struct winsize size={0}; ioctl(slave,TIOCGWINSZ,&size);
    verify_menu(size.ws_col==view->columns && size.ws_row==view->lines,"Font change updates PTY geometry");
    verify_menu(shortcut(@"0",29) && view->font_size==initial,"Command-zero resets configured size");
    const unichar characters[]={NSPageUpFunctionKey,NSPageDownFunctionKey,NSHomeFunctionKey,NSEndFunctionKey,NSPageUpFunctionKey};
    const unsigned short codes[]={116,121,115,119,126};
    const char *expected[]={"\033[5~","\033[6~","\033[H","\033[F","\033[5~"};
    for (int i=0;i<5;i++) {
        [view->pending setLength:0]; [view keyDown:navigationEvent(characters[i],codes[i],0)];
        verify_menu([view->pending isEqualToData:[NSData dataWithBytes:expected[i] length:strlen(expected[i])]],"Navigation reaches program through core encoder");
    }
    [view->pending setLength:0];
    NSMutableString *history=[NSMutableString string]; for(int i=0;i<800;i++)[history appendFormat:@"FIXTURE_%d\r\n",i];
    fixture(view,history); verify_menu(historyRows(view)>700,"History fixture retained");
    uint64_t bottom=scrollbar(view).offset;
    [view keyDown:navigationEvent(NSPageUpFunctionKey,116,NSShiftKeyMask)];
    uint64_t up=scrollbar(view).offset;
    [view keyDown:navigationEvent(NSPageDownFunctionKey,121,NSShiftKeyMask)];
    verify_menu(up<bottom && scrollbar(view).offset==bottom,"Shift Page Up/Down scroll history");
    [view keyDown:navigationEvent(NSHomeFunctionKey,115,NSShiftKeyMask)];
    verify_menu(scrollbar(view).offset==0,"Shift Home reaches oldest history");
    [view keyDown:navigationEvent(NSEndFunctionKey,119,NSShiftKeyMask)];
    verify_menu(scrollbar(view).offset==bottom && ![view->pending length],"Shift End returns live screen without PTY input");
    NSString *visible=[activeText(view) copy]; size_t limit=0,after=0;
    ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES,&limit);
    verify_menu(shortcut(@"k",40),"Command-K handles clear scrollback");
    ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES,&after);
    fprintf(stderr,"Clear details: history=%lu limit=%lu/%lu visible=%d\n",(unsigned long)historyRows(view),(unsigned long)after,(unsigned long)limit,[activeText(view) isEqual:visible]);
    verify_menu(historyRows(view)==0 && after==limit && [activeText(view) isEqual:visible],"Clear Scrollback preserves visible grid and history limit"); [visible release];
    fixture(view,history); verify_menu(historyRows(view)>700,"Scrollback resumes after clear");
    int fd=view->master; fixture(view,@"\033[?1049h\033[?2004h\033[?1000hBROKEN");
    verify_menu(shortcut(@"r",15),"Command-R handles terminal reset");
    GhosttyTerminalScreen active; ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,&active);
    GhosttyTerminalModeConfig bracket={GHOSTTY_MODE_BRACKETED_PASTE,true}; ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_MODE,&bracket);
    verify_menu(active==GHOSTTY_TERMINAL_SCREEN_PRIMARY && !bracket.value && historyRows(view)==0 && view->master==fd && view->font_size==initial &&
        [[[view screenText] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length]==0,"Reset clears modes/screens/history while preserving session and font");
    NSString *config=[prefix stringByAppendingString:@".config"];
    [@"font-family = Menlo\nfont-size = 18\ntheme = Catppuccin Mocha\n" writeToFile:config atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    verify_menu(imac_config_load(config),"Load explicit configuration fixture");
    verify_menu(shortcut(@",",43) && [delegate->opened_config isEqual:config],"Settings opens actual explicit configuration path");
    fixture(view,@"CONFIG_PRESERVED");
    int otherMaster=-1,otherSlave=-1; openpty(&otherMaster,&otherSlave,NULL,NULL,NULL); fcntl(otherMaster,F_SETFL,O_NONBLOCK);
    TerminalView *other=[delegate addTabWithFD:otherMaster child:0 retainOutput:NO]; pump();
    [@"font-family = FiraCode Nerd Font Mono\nfont-size = 16\n" writeToFile:config atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    verify_menu(modifiedShortcut(@"<",43,NSCommandKeyMask|NSShiftKeyMask),"Shift-Command-comma reloads configuration");
    verify_menu(view->font_size==16 && other->font_size==16 && [other->configured_font_family isEqual:imac_config.font_family] && view->master==fd &&
        [[view screenText] rangeOfString:@"CONFIG_PRESERVED"].location!=NSNotFound,"Reload updates inactive tabs without losing session/output");
    [@"font-size = 24\ninvalid = yes\n" writeToFile:config atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [delegate reloadConfiguration:nil];
    verify_menu(delegate->reload_errors==1 && imac_config.font_size==16 && other->font_size==16 && view->font_size==16 && [imac_config_path() isEqual:config],"Invalid reload preserves all live configuration");
    [tabs selectFirstTabViewItem:nil]; [window makeFirstResponder:view]; pump();
    [view setFontSize:20]; verify_menu(shortcut(@"0",29) && view->font_size==16,"Font reset follows reloaded configured size");
    fixture(view,@"\033[2J\033[H\033[?25l\033[38;2;240;200;100m\033[48;2;10;20;30m");
    fixture(view,@"████████\r\n████████\r\n████████\r\n\r\n▀▄▌▐░▒▓\r\n▖▗▘▙▚▛▜▝▞▟\r\n\033[0mLarger fonts: Καλημέρα こんにちは\r\n");
    view->capture_path=[[prefix stringByAppendingString:@"-font.png"] copy];
    [view setNeedsDisplay:YES]; [view display];
    fprintf(stderr,"Font capture metrics: %d x %d\n",view->cell_width,view->cell_height);
    Boolean baseline=IsSecureEventInputEnabled();
    [delegate toggleSecureKeyboardEntry:nil];
    NSMenuItem *secure=[menu(@"Snow Ghostty") itemWithTitle:@"Secure Keyboard Entry"]; [menu(@"Snow Ghostty") update];
    verify_menu([delegate secureKeyboardEntryEnabled] && [delegate secureKeyboardEntryActive] && IsSecureEventInputEnabled() && [secure state]==NSOnState,"Native secure input enabled and menu checked");
    NSPanel *panel=[[[NSPanel alloc] initWithContentRect:NSMakeRect(200,200,300,150) styleMask:NSTitledWindowMask|NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];
    [panel makeKeyAndOrderFront:nil]; pump();
    verify_menu(![delegate secureKeyboardEntryActive] && [delegate secureKeyboardEntryEnabled],"Nonterminal focus releases secure input");
    [panel orderOut:nil]; [window makeKeyAndOrderFront:nil]; pump();
    verify_menu([delegate secureKeyboardEntryActive] && IsSecureEventInputEnabled(),"Terminal focus restores secure input");
    [delegate applicationWillResignActive:nil]; verify_menu(![delegate secureKeyboardEntryActive],"App deactivation releases own secure input");
    [delegate applicationDidBecomeActive:nil]; verify_menu([delegate secureKeyboardEntryActive],"App activation restores selected secure input");
    [delegate toggleSecureKeyboardEntry:nil]; [menu(@"Snow Ghostty") update];
    verify_menu(![delegate secureKeyboardEntryActive] && ![delegate secureKeyboardEntryEnabled] && [secure state]==NSOffState && IsSecureEventInputEnabled()==baseline,"Disable balances native secure input ownership");
    close(otherSlave); close(slave); unlink([config fileSystemRepresentation]);
    [delegate toggleSecureKeyboardEntry:nil];
    [[delegate activeController] closeWithoutConfirmation]; pump();
    verify_menu(![delegate secureKeyboardEntryActive] && IsSecureEventInputEnabled()==baseline,"Last window close releases secure input");
    [delegate toggleSecureKeyboardEntry:nil];
    return passed;
}

static BOOL mouseDragMode, axisResizeMode, continuousMouseMode, tabPromptMode;
static unsigned liveResizeStarts;
@interface LiveResizeObserver : NSObject
- (void)started:(NSNotification *)note;
@end
@implementation LiveResizeObserver
- (void)started:(NSNotification *)note { (void)note; liveResizeStarts++; }
@end
typedef struct { CGWindowID window; BOOL continuous; volatile int done; } NativeDrag;
static void postMouse(CGEventType type, CGPoint point)
{
    CGWarpMouseCursorPosition(point);
    CGEventRef event=CGEventCreateMouseEvent(NULL,type,point,kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event,kCGMouseEventClickState,1);
    CGEventPost(kCGSessionEventTap,event); CFRelease(event);
}
static CGRect dragWindowBounds(CGWindowID number)
{
    CFArrayRef windows=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,number);CGRect rect=CGRectZero;
    for(CFIndex i=0;i<CFArrayGetCount(windows);i++) {
        CFDictionaryRef info=CFArrayGetValueAtIndex(windows,i);int candidate=0;
        CFNumberGetValue(CFDictionaryGetValue(info,kCGWindowNumber),kCFNumberIntType,&candidate);
        if(candidate==(int)number)CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(info,kCGWindowBounds),&rect);
    }
    CFRelease(windows);return rect;
}
static void *dragNativeWindow(void *context)
{
    NativeDrag *drag=context;usleep(200000);
    // Separate drags match the reported sequence: height first, then width.
    const CGPoint offsets[]={{0,-340},{-460,0},{0,280},{460,0},{0,60}};
    for(int stage=0;stage<5;stage++) {
        CGRect frame=dragWindowBounds(drag->window);
        if(CGRectIsEmpty(frame))break;
        CGPoint corner=CGPointMake(CGRectGetMaxX(frame)-4,CGRectGetMaxY(frame)-4),point=corner;
        if(!drag->continuous || stage==0)postMouse(kCGEventLeftMouseDown,corner);
        for(int step=1;step<=20;step++) {
            point=CGPointMake(corner.x+offsets[stage].x*step/20,corner.y+offsets[stage].y*step/20);
            postMouse(kCGEventLeftMouseDragged,point);usleep(20000);
        }
        if(!drag->continuous || stage==4)postMouse(kCGEventLeftMouseUp,point);usleep(300000);
    }
    drag->done=1;return NULL;
}

static unsigned promptStarts, promptInputs;
static void promptMarker(GhosttyTerminal terminal, void *userdata, const GhosttyTerminalSemanticPrompt *event)
{
    (void)terminal; (void)userdata;
    if (event->kind==GHOSTTY_SEMANTIC_PROMPT_PROMPT_START) promptStarts++;
    if (event->kind==GHOSTTY_SEMANTIC_PROMPT_INPUT_START) promptInputs++;
}
static BOOL realPromptProbe(MenuProbeDelegate *delegate, NSWindow *window, TerminalView *initial, NSString *prefix, BOOL bothAxes, BOOL cleanStart)
{
    TerminalView *view=initial;
    if (!initial->child) {
        int master=-1; pid_t child=0;
        if (!snow_session_spawn(NULL,getenv("HOME"),NULL,NULL,&master,&child)) return NO;
        view=[delegate addTabWithFD:master child:child retainOutput:NO];
        [delegate removeTerminal:initial];
    }
    core_check(ghostty_terminal_set(view->terminal,GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,(const void *)promptMarker),"observe native prompt");
    if (cleanStart) [view keyDown:navigationEvent('l',37,NSControlKeyMask)];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    bool atPrompt=false;
    do { pump(); ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT,&atPrompt); } while (!atPrompt && [deadline timeIntervalSinceNow]>0);
    verify_menu(atPrompt,"Actual login shell emits OSC 133 prompt/input markers");
    if (!atPrompt) {
        view->capture_path=[[prefix stringByAppendingString:@"-missing-marks.png"] copy]; [view setNeedsDisplay:YES]; [view display];
        fprintf(stderr,"Prompt setup output: %s\n",[[view screenText] UTF8String]);
        [[delegate activeController] closeWithoutConfirmation]; return NO;
    }
    if (cleanStart) {
        [view keyDown:navigationEvent('l',37,NSControlKeyMask)];
        for(int i=0;i<7;i++) pump();
        [view clearScrollback:nil];
    } else for(int i=0;i<10;i++) pump();
    if (tabPromptMode) {
        NSRect frame=[window frame];frame.size=NSMakeSize(529,572);[window setFrame:frame display:YES];
        for(int n=0;n<5;n++)pump();
        [delegate newTab:nil];
        view=(TerminalView *)[[[[delegate activeController] terminalTabs] selectedTabViewItem] view];
        core_check(ghostty_terminal_set(view->terminal,GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,(const void *)promptMarker),"observe new tab prompt");
        for(int n=0;n<12;n++)pump();
        uint16_t y=0;ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y);
        NSUInteger rulers=[[[view screenText] componentsSeparatedByString:@"╭"] count]-1;
        fprintf(stderr,"Narrow new tab startup: cursor=%u history=%lu rulers=%lu\n",y,(unsigned long)historyRows(view),(unsigned long)rulers);
        verify_menu(y==1 && historyRows(view)==0 && rulers==1,"Narrow new tab starts with exactly one prompt at the top");
        captureWindow(window,[prefix stringByAppendingString:@"-native-start.png"]);
    }
    view->capture_path=[[prefix stringByAppendingString:@"-before.png"] copy]; [view setNeedsDisplay:YES]; [view display];
    uint16_t initialY=0; ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&initialY);
    size_t initialHistory=historyRows(view); BOOL all=YES;
    fprintf(stderr,"Prompt baseline: cursor=%u history=%lu clean=%d\n",initialY,(unsigned long)initialHistory,cleanStart);
    if (mouseDragMode) {
        LiveResizeObserver *observer=[[[LiveResizeObserver alloc] init] autorelease];
        [[NSNotificationCenter defaultCenter] addObserver:observer selector:@selector(started:) name:NSWindowWillStartLiveResizeNotification object:window];
        [NSApp activateIgnoringOtherApps:YES]; [window makeKeyAndOrderFront:nil]; pump();
        NativeDrag drag={0}; drag.window=(CGWindowID)[window windowNumber];drag.continuous=continuousMouseMode;
        CGEventRef mouse=CGEventCreate(NULL);CGPoint original=CGEventGetLocation(mouse);CFRelease(mouse);
        pthread_t thread;pthread_create(&thread,NULL,dragNativeWindow,&drag);
        deadline=[NSDate dateWithTimeIntervalSinceNow:5];
        while(!drag.done && [deadline timeIntervalSinceNow]>0) pump();
        pthread_join(thread,NULL);for(int n=0;n<5;n++)pump();
        CGWarpMouseCursorPosition(original);
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        uint16_t y=0;ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y);
        fprintf(stderr,"Native mouse drag: live-starts=%u cursor=%u/%u history=%lu/%lu\n",liveResizeStarts,y,initialY,(unsigned long)historyRows(view),(unsigned long)initialHistory);
        verify_menu(liveResizeStarts>0 && y==initialY && historyRows(view)==initialHistory,"Mouse-driven shrink/grow/reversal preserves prompt position");
    }
    if (mouseDragMode) {
        view->capture_path=[[prefix stringByAppendingString:@".png"] copy]; [view setNeedsDisplay:YES]; [view display];
        [[delegate activeController] closeWithoutConfirmation]; pump(); return passed;
    }
    if (axisResizeMode) {
        const NSSize sizes[]={{916,200},{320,200},{320,650},{916,650},{916,350},{500,350},{500,800},{1200,800},{1200,200},{320,200},{320,650},{916,638}};
        for(int round=0;round<2;round++) for(int n=0;n<12;n++) {
            NSRect frame=[window frame];frame.size=sizes[n];[window setFrame:frame display:YES];
            for(int wait=0;wait<4;wait++)pump();
            uint16_t y=0;ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y);
            fprintf(stderr,"Axis step %d/%d size=%.0fx%.0f cursor=%u/%u history=%lu/%lu marks=%u\n",round,n,sizes[n].width,sizes[n].height,y,initialY,(unsigned long)historyRows(view),(unsigned long)initialHistory,promptInputs);
            if (y!=initialY || historyRows(view)!=initialHistory) all=NO;
        }
        verify_menu(all,"Vertical shrink then horizontal shrink, and inverse growth, preserve prompt position");
        view->capture_path=[[prefix stringByAppendingString:@".png"] copy];[view setNeedsDisplay:YES];[view display];
        [[delegate activeController] closeWithoutConfirmation];pump();return passed;
    }
    const CGFloat widths[]={560,1100,660,916};
    for (int round=0;round<5;round++) for(int n=0;n<4;n++) {
        unsigned previous=promptInputs;
        NSRect frame=[window frame]; frame.size.width=widths[n]; if (bothAxes) frame.size.height=(CGFloat[]){400,800,550,650}[n]; [window setFrame:frame display:YES];
        deadline=[NSDate dateWithTimeIntervalSinceNow:3];
        while (promptInputs==previous && [deadline timeIntervalSinceNow]>0) pump();
        pump();
        uint16_t y=0; bool atPrompt=false;
        ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y);
        ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT,&atPrompt);
        if (promptInputs==previous || !atPrompt || y!=initialY || historyRows(view)!=initialHistory) {
            fprintf(stderr,"Actual prompt resize %d/%d: cursor=%u/%u history=%lu/%lu marks=%u/%u at-prompt=%d\n",
                round,n,y,initialY,(unsigned long)historyRows(view),(unsigned long)initialHistory,promptInputs,previous,atPrompt); all=NO;
        }
    }
    verify_menu(all,"Actual configured prompt survives 20 native resizes without accumulating rows");
    if (bothAxes) {
        BOOL burstOK=YES;
        for (int round=0;round<5;round++) {
            unsigned previous=promptInputs;
            for (int n=0;n<24;n++) {
                NSRect frame=[window frame];
                frame.size.width=600+((n*37)%650); frame.size.height=400+((n*19)%440);
                [window setFrame:frame display:YES];
            }
            NSRect frame=[window frame]; frame.size.width=916; frame.size.height=650; [window setFrame:frame display:YES];
            deadline=[NSDate dateWithTimeIntervalSinceNow:3];
            while (promptInputs==previous && [deadline timeIntervalSinceNow]>0) pump();
            for(int n=0;n<4;n++) pump();
            uint16_t y=0; ghostty_terminal_get(view->terminal,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y);
            if (y!=initialY || historyRows(view)!=initialHistory) {
                fprintf(stderr,"Rapid resize burst %d: cursor=%u/%u history=%lu/%lu\n",round,y,initialY,(unsigned long)historyRows(view),(unsigned long)initialHistory);burstOK=NO;
            }
        }
        verify_menu(burstOK,"Rapid width/height resize bursts preserve actual prompt position");
    }

    view->capture_path=[[prefix stringByAppendingString:@".png"] copy]; [view setNeedsDisplay:YES]; [view display];
    [[delegate activeController] closeWithoutConfirmation]; pump(); return passed;
}

static BOOL startupSizeProbe(MenuProbeDelegate *delegate, NSWindow *window, NSString *prefix)
{
    NSRect frame=[window frame];frame.size=NSMakeSize(529,572);[window setFrame:frame display:YES];pump();
    int master=-1;pid_t child=0;
    if(!snow_session_spawn("printf 'START_SIZE:'; stty size; exec /bin/sh -i",getenv("HOME"),NULL,NULL,&master,&child))return NO;
    // A shell must not read the placeholder size while AppKit builds its tab.
    usleep(100000);
    TerminalView *view=[delegate addTabWithFD:master child:child retainOutput:NO];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4];
    while([[view screenText] rangeOfString:@"START_SIZE:"].location==NSNotFound && [deadline timeIntervalSinceNow]>0)pump();
    NSString *expected=[NSString stringWithFormat:@"START_SIZE:%u %u",view->lines,view->columns];
    fprintf(stderr,"First-command size expected %s; fixture: %s\n",[expected UTF8String],[[view screenText] UTF8String]);
    verify_menu([[view screenText] rangeOfString:expected].location!=NSNotFound,"First command sees final tab PTY geometry");
    int cancelled=-1;pid_t cancelledChild=0;
    verify_menu(snow_session_spawn("exec /bin/sleep 30",getenv("HOME"),NULL,NULL,&cancelled,&cancelledChild),"Create pending session cancellation fixture");
    usleep(100000);
    char currentName[256]={0},pendingName[256]={0};snow_session_process_name(getpid(),currentName,sizeof(currentName));snow_session_process_name(cancelledChild,pendingName,sizeof(pendingName));
    verify_menu(currentName[0] && !strcmp(currentName,pendingName),"Unattached session has not executed its command");
    snow_session_close(cancelled,cancelledChild);
    deadline=[NSDate dateWithTimeIntervalSinceNow:3];while(kill(cancelledChild,0)==0 && [deadline timeIntervalSinceNow]>0)pump();
    verify_menu(kill(cancelledChild,0)<0 && errno==ESRCH,"Pending session cancellation exits and reaps the child");
    captureWindow(window,[prefix stringByAppendingString:@".png"]);
    [[delegate activeController] closeWithoutConfirmation];pump();return passed;
}

int main(int argc, char **argv)
{
    if (argc!=3) { fputs("Usage: menus-probe CAPTURE prompt|prompt-resize|prompt-live|prompt-mouse|prompt-axes|controls|windows|close-terminal|shell-exit|tabs|switch|switch-fullscreen|confirm-window|confirm-quit\n",stderr); return 2; }
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    if (!imac_config_load(nil)) return 1;
    imac_core_init();
    int master=-1,slave=-1; pid_t initialChild=0;
    BOOL liveShell=!strcmp(argv[2],"prompt-live") || !strncmp(argv[2],"prompt-mouse",12) || !strcmp(argv[2],"prompt-axes") || !strcmp(argv[2],"prompt-tab");
    // Match production: spawn before font registration and AppKit startup.
    if (liveShell && !snow_session_spawn(NULL,getenv("HOME"),NULL,NULL,&master,&initialChild)) return 1;
    if (!imac_register_fonts()) return 1;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; [NSApp finishLaunching];
    if (!liveShell && openpty(&master,&slave,NULL,NULL,NULL)<0) return 1;
    fcntl(master,F_SETFL,O_NONBLOCK);
    MenuProbeDelegate *delegate=[[MenuProbeDelegate alloc] initWithFD:master child:initialChild];
    [NSApp setDelegate:delegate]; [delegate createWindow:nil]; pump();
    NSWindow *terminal=[[delegate activeController] terminalWindow];
    [NSApp activateIgnoringOtherApps:YES]; [terminal makeKeyAndOrderFront:nil]; pump();
    NSTabView *tabs=(NSTabView *)[terminal contentView];
    TerminalView *view=(TerminalView *)[[tabs selectedTabViewItem] view];
    mouseDragMode=!strncmp(argv[2],"prompt-mouse",12);continuousMouseMode=!strcmp(argv[2],"prompt-mouse-continuous");axisResizeMode=!strcmp(argv[2],"prompt-axes") || !strcmp(argv[2],"prompt-tab");tabPromptMode=!strcmp(argv[2],"prompt-tab");
    if (!strcmp(argv[2],"prompt") || !strcmp(argv[2],"prompt-resize") || !strcmp(argv[2],"prompt-live") || mouseDragMode || axisResizeMode) return realPromptProbe(delegate,terminal,view,[NSString stringWithUTF8String:argv[1]],strcmp(argv[2],"prompt")!=0,strcmp(argv[2],"prompt-live")!=0 && !mouseDragMode && !axisResizeMode && !tabPromptMode) ? 0 : 1;
    if (!strcmp(argv[2],"startup-size")) return startupSizeProbe(delegate,terminal,[NSString stringWithUTF8String:argv[1]]) ? 0 : 1;
    if (!strcmp(argv[2],"controls")) return controlsProbe(delegate,terminal,tabs,view,slave,[NSString stringWithUTF8String:argv[1]]) ? 0 : 1;
    if (!strcmp(argv[2],"windows")) return windowsProbe(delegate,terminal,view,[NSString stringWithUTF8String:argv[1]]) ? 0 : 1;
    if (!strcmp(argv[2],"confirm-window") || !strcmp(argv[2],"confirm-quit"))
        return confirmationProbe(delegate,tabs,view,[NSString stringWithUTF8String:argv[1]],!strcmp(argv[2],"confirm-quit")) ? 0 : 1;
    if (!strcmp(argv[2],"switch") || !strcmp(argv[2],"switch-fullscreen")) {
        if (!strcmp(argv[2],"switch-fullscreen")) [view toggleFullscreen:nil];
        BOOL ok=switchingProbe(delegate,tabs,view,[NSString stringWithUTF8String:argv[1]]);
        return ok ? 0 : 1;
    }
    NSString *names=[[[[NSApp mainMenu] itemArray] valueForKey:@"title"] componentsJoinedByString:@","];
    verify_menu([names isEqualToString:@"Snow Ghostty,File,Edit,View,Window,Help"],"Native menu bar structure");
    verify_menu([NSApp servicesMenu]==[[menu(@"Snow Ghostty") itemWithTitle:@"Services"] submenu],"Registered Services menu");
    verify_menu([NSApp windowsMenu]==menu(@"Window") && [NSApp helpMenu]==menu(@"Help"),"Registered Window / Help menus");
    NSMenuItem *newWindow=[menu(@"File") itemWithTitle:@"New Window"];
    verify_menu([newWindow target]==delegate && [[newWindow keyEquivalent] isEqualToString:@"n"],"Command-N routes to session delegate");
    [menu(@"Edit") update];
    verify_menu(![[menu(@"Edit") itemWithTitle:@"Copy"] isEnabled],"Copy disabled without selection");
    const char *fixture="\033[2J\033[HMenu selection fixture\r\nSecond row";
    ghostty_terminal_vt_write(view->terminal,(const uint8_t *)fixture,strlen(fixture));
    verify_menu(shortcut(@"a",0) && view->selection_active,"Command-A selects terminal content");
    GhosttyFormatter formatter=NULL; uint8_t *bytes=NULL; size_t length=0;
    ghostty_formatter_terminal_new(NULL,&formatter,view->terminal);
    ghostty_formatter_set(formatter,GHOSTTY_FORMATTER_OPT_SELECTION,&view->selection);
    GhosttyResult result=ghostty_formatter_format_alloc(formatter,NULL,&bytes,&length);
    NSString *selected=result==GHOSTTY_SUCCESS ? [[[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding] autorelease] : @"";
    verify_menu([selected rangeOfString:@"Menu selection fixture"].location!=NSNotFound &&
        [selected rangeOfString:@"Second row"].location!=NSNotFound,"Select All includes both fixture rows");
    if (bytes) ghostty_free(NULL,bytes,length); ghostty_formatter_free(formatter);
    [menu(@"Edit") update]; verify_menu([[menu(@"Edit") itemWithTitle:@"Copy"] isEnabled],"Copy enabled with selection");
    if (!strcmp(argv[2],"tabs")) {
        verify_menu(shortcut(@"t",17),"Command-T opens a native tab"); pump();
        TerminalView *second=(TerminalView *)[[tabs selectedTabViewItem] view];
        verify_menu([tabs numberOfTabViewItems]==2 && [tabs contentRect].size.height==[tabs bounds].size.height-23 &&
            second!=view && second->master!=view->master && second->child>0,"Tabs have separate PTYs / shells");
        verify_menu(![tabs isFlipped] || [tabs contentRect].origin.y==23,"Tab strip occupies the top of the flipped container");
        [second typeCommand:@"printf '\\nTAB_TWO_MARKER\\n'\n"];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
        while ([[second screenText] rangeOfString:@"TAB_TWO_MARKER"].location==NSNotFound && [deadline timeIntervalSinceNow]>0) pump();
        verify_menu([[second screenText] rangeOfString:@"TAB_TWO_MARKER"].location!=NSNotFound &&
            [[view screenText] rangeOfString:@"TAB_TWO_MARKER"].location==NSNotFound,"Tab input / output isolated");
        const char *title="\033]0;Second tab\007";
        ghostty_terminal_vt_write(second->terminal,(const uint8_t *)title,strlen(title));
        verify_menu([[second->tab_item label] isEqualToString:@"Second tab"] && [[terminal title] isEqualToString:@"Second tab"],"OSC title updates selected tab / window");
        [menu(@"Window") update];
        verify_menu(modifiedShortcut(@"{",33,NSCommandKeyMask|NSShiftKeyMask),"Command-Shift-[ selects previous tab"); pump();
        verify_menu([[tabs selectedTabViewItem] view]==view && [[terminal firstResponder] isEqual:view],"Tab switching restores correct responder");
        verify_menu(modifiedShortcut(@"}",30,NSCommandKeyMask|NSShiftKeyMask) && [[tabs selectedTabViewItem] view]==second,
            "Command-Shift-] selects next tab");
        [delegate previousTab:nil]; pump();
        [second->timer setFireDate:[NSDate dateWithTimeIntervalSinceNow:10]];
        const char *tabFixture="\033[2J\033[HNative Cocoa tabs\r\nIndependent shell, scrollback and GPU rendering.";
        ghostty_terminal_vt_write(second->terminal,(const uint8_t *)tabFixture,strlen(tabFixture));
        [delegate nextTab:nil]; pump(); [tabs display]; [second display]; [NSApp updateWindows];
        verify_menu(captureWindow(terminal,[[NSString stringWithUTF8String:argv[1]] stringByAppendingString:@"-tabs.png"]),"Captured native tab bar");
        [second->timer setFireDate:[NSDate date]];
        [delegate previousTab:nil]; pump();
        kill(second->child,SIGHUP); waitForTabs(tabs,1);
        verify_menu([tabs numberOfTabViewItems]==1 && [[tabs selectedTabViewItem] view]==view &&
            [tabs tabViewType]==NSNoTabsNoBorder,"Background shell exit preserves sibling tab");
        verify_menu([[view screenText] rangeOfString:@"Menu selection fixture"].location!=NSNotFound,"Sibling scrollback preserved");
        verify_menu(shortcut(@"t",17),"New tab after background exit"); pump();
        TerminalView *closing=(TerminalView *)[[tabs selectedTabViewItem] view];
        pid_t closing_pid=closing->child;
        verify_menu(shortcut(@"\r",36),"Fullscreen with native tab bar"); pump();
        verify_menu([closing isTerminalFullscreen] && [tabs numberOfTabViewItems]==2,"Tabs share fullscreen container");
        [menu(@"File") update]; verify_menu(shortcut(@"w",13),"Command-W closes fullscreen tab"); pump();
        verify_menu([tabs numberOfTabViewItems]==1 && [view isTerminalFullscreen],"Closing tab retains fullscreen sibling");
        verify_menu(closing->master==-1 && closing->child==0,"Closed tab releases PTY / child ownership");
        deadline=[NSDate dateWithTimeIntervalSinceNow:4];
        while (kill(closing_pid,0)==0 && [deadline timeIntervalSinceNow]>0) pump();
        verify_menu(kill(closing_pid,0)<0 && errno==ESRCH,"Closed tab child exits and is reaped");
        shortcut(@"\r",36); pump();
        shortcut(@"t",17); pump();
        TerminalView *mouseClosed=(TerminalView *)[[tabs selectedTabViewItem] view];
        [delegate previousTab:nil]; pump();
        NSButton *backgroundButton=nil;
        for (NSView *strip in [tabs subviews]) for (NSView *button in [strip subviews])
            if ([button isKindOfClass:[NSButton class]] && [(NSButton *)button tag]==1) backgroundButton=(NSButton *)button;
        verify_menu(backgroundButton!=nil,"Native tab button exposed in Cocoa view hierarchy");
        [backgroundButton performClick:nil]; pump();
        verify_menu([[tabs selectedTabViewItem] view]==mouseClosed,"Native tab button selects its session");
        [delegate previousTab:nil];
        NSButton *closeButton=[[backgroundButton subviews] count] ? [[backgroundButton subviews] objectAtIndex:0] : nil;
        [closeButton performClick:nil]; pump();
        verify_menu([tabs numberOfTabViewItems]==1 && [[tabs selectedTabViewItem] view]==view && mouseClosed->master==-1,
            "Native close button closes background tab only");
        int title_master=-1; pid_t title_pid=0;
        verify_menu(snow_session_spawn("cd /tmp && exec /bin/sleep 30",getenv("HOME"),NULL,NULL,&title_master,&title_pid),"Spawn automatic-title fixture");
        TerminalView *automatic=[delegate addTabWithFD:title_master child:title_pid retainOutput:NO];
        deadline=[NSDate dateWithTimeIntervalSinceNow:4];
        while (![[automatic->tab_item label] isEqualToString:@"tmp — sleep"] && [deadline timeIntervalSinceNow]>0) pump();
        verify_menu([[automatic->tab_item label] isEqualToString:@"tmp — sleep"] && [[terminal title] isEqualToString:[automatic->tab_item label]],
            "Foreground process / directory automatically name tab and window");
        const char *explicitTitle="\033]0;Explicit application title\007";
        ghostty_terminal_vt_write(automatic->terminal,(const uint8_t *)explicitTitle,strlen(explicitTitle));
        verify_menu([[automatic->tab_item label] isEqualToString:@"Explicit application title"] &&
            [[terminal title] isEqualToString:@"Explicit application title"],"Application-provided title overrides automatic title");
        shortcut(@"w",13); pump();
        int top_master=-1; pid_t shell_pid=0;
        verify_menu(snow_session_spawn("exec /bin/sh -i","/tmp",NULL,NULL,&top_master,&shell_pid),"Spawn foreground-title shell fixture");
        TerminalView *topView=[delegate addTabWithFD:top_master child:shell_pid retainOutput:NO];
        [topView typeCommand:@"printf '\\033]0;Idle shell\\007'\n"];
        deadline=[NSDate dateWithTimeIntervalSinceNow:4];
        while (![[topView->tab_item label] isEqualToString:@"Idle shell"] && [deadline timeIntervalSinceNow]>0) pump();
        verify_menu([[topView->tab_item label] isEqualToString:@"Idle shell"],"Shell OSC title established before foreground job");
        [topView typeCommand:@"/usr/bin/top\n"];
        deadline=[NSDate dateWithTimeIntervalSinceNow:5];
        while (![[topView->tab_item label] hasSuffix:@" — top"] && [deadline timeIntervalSinceNow]>0) pump();
        char observed_process[256]={0}; snow_session_process_name(tcgetpgrp(topView->master),observed_process,sizeof(observed_process));
        fprintf(stderr,"Foreground top title: tab=%s; window=%s; process=%s\n",[[topView->tab_item label] UTF8String],[[terminal title] UTF8String],observed_process);
        verify_menu([[topView->tab_item label] isEqualToString:@"tmp — top"] && [[terminal title] isEqualToString:@"tmp — top"],
            "top replaces stale shell title in tab and window");
        const uint8_t interrupt=3; [topView queueBytes:&interrupt length:1];
        deadline=[NSDate dateWithTimeIntervalSinceNow:4];
        while (![[topView->tab_item label] isEqualToString:@"Idle shell"] && [deadline timeIntervalSinceNow]>0) pump();
        verify_menu([[topView->tab_item label] isEqualToString:@"Idle shell"],"Shell title restored after top exits");
        [topView typeCommand:@"/usr/bin/top\n"];
        deadline=[NSDate dateWithTimeIntervalSinceNow:5];
        while (![[topView->tab_item label] hasSuffix:@" — top"] && [deadline timeIntervalSinceNow]>0) pump();
        pid_t top_pid=tcgetpgrp(topView->master);
        verify_menu(top_pid>0 && top_pid!=shell_pid,"top owns the foreground process group");
        shortcut(@"w",13); pump();
        deadline=[NSDate dateWithTimeIntervalSinceNow:5];
        while ((kill(shell_pid,0)==0 || (top_pid>0 && kill(top_pid,0)==0)) && [deadline timeIntervalSinceNow]>0) pump();
        verify_menu(kill(shell_pid,0)<0 && errno==ESRCH && top_pid>0 && kill(top_pid,0)<0 && errno==ESRCH,
            "Closing tab terminates both shell and foreground top");
        int held_master=-1; pid_t held_pid=0;
        verify_menu(snow_session_spawn("exit 7",getenv("HOME"),NULL,NULL,&held_master,&held_pid),"Spawn retained-output fixture");
        TerminalView *held=[delegate addTabWithFD:held_master child:held_pid retainOutput:YES];
        deadline=[NSDate dateWithTimeIntervalSinceNow:4];
        while (held->child && [deadline timeIntervalSinceNow]>0) pump();
        verify_menu([tabs numberOfTabViewItems]==2 && [[held screenText] rangeOfString:@"[Process exited: 7]"].location!=NSNotFound,
            "Retained-output tab survives its shell exit");
        shortcut(@"w",13); pump();
        verify_menu([tabs numberOfTabViewItems]==1,"Retained-output tab closes independently");
    }
    [menu(@"View") update];
    verify_menu([[menu(@"View") itemWithTitle:@"Enter Fullscreen"] isEnabled],"Fullscreen menu reflects windowed state");
    verify_menu(shortcut(@"\r",36),"Command-Enter enters fullscreen"); pump();
    verify_menu([view isTerminalFullscreen],"Native fullscreen active");
    [menu(@"View") update];
    verify_menu([[menu(@"View") itemWithTitle:@"Exit Fullscreen"] isEnabled],"Fullscreen menu reflects fullscreen state");
    NSMenu *app=menu(@"Snow Ghostty");
    [app performActionForItemAtIndex:[app indexOfItemWithTitle:@"About Snow Ghostty"]]; pump();
    NSWindow *about=[NSApp keyWindow];
    verify_menu(![view isTerminalFullscreen] && about!=terminal && [about isVisible],"About opens above restored terminal");
    NSMutableString *text=[NSMutableString string]; collectText([about contentView],text);
    fprintf(stderr,"About text:\n%s\n",[text UTF8String]);
    verify_menu([text rangeOfString:@"Snow Ghostty"].location!=NSNotFound &&
        [text rangeOfString:@"0.3.0"].location!=NSNotFound &&
        [text rangeOfString:@"libghostty-vt 1.0.0"].location!=NSNotFound,"About displays app and linked-core versions");
    verify_menu(captureWindow(about,[NSString stringWithUTF8String:argv[1]]),"Captured native About panel");
    [delegate showAbout:nil]; pump(); verify_menu([NSApp keyWindow]==about,"Repeated About reuses native panel");
    [menu(@"File") update]; verify_menu(shortcut(@"w",13),"Command-W closes About"); pump();
    verify_menu(![about isVisible] && [terminal isVisible],"Closing About preserves terminal");
    [terminal makeKeyAndOrderFront:nil]; [terminal makeFirstResponder:view];
    verify_menu([NSApp targetForAction:@selector(selectAll:)]==view,"Terminal responder restored after About");
    [delegate showAbout:nil]; pump();
    if (!passed) return 1;
    if (!strcmp(argv[2],"close-terminal")) {
        fputs("Closing terminal while About remains open\n",stderr);
        [terminal performClose:nil];
    } else if (!strcmp(argv[2],"shell-exit") || !strcmp(argv[2],"tabs")) {
        // Tick must terminate through the same delegate even with About open.
        pid_t child=fork(); if (child==0) _exit(0);
        if (child<0) return 1;
        view->child=child;
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
        while ([deadline timeIntervalSinceNow]>0) pump();
    } else return 2;
    verify_menu(![[delegate terminalWindows] count] && ![terminal isVisible],"Terminal closes while application remains resident");
    if (passed) [NSApp terminate:nil];
    fputs("Terminal termination with About open: FAIL\n",stderr);
    [pool drain]; return 1;
}
