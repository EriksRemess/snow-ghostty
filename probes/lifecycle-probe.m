#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

// Run a separate app process and address key events and captures only to it.
static void key(pid_t pid, CGKeyCode code, CGEventFlags flags, UniChar character)
{
    ProcessSerialNumber process;
    if (GetProcessForPID(pid,&process)!=noErr) return;
    for (int down=1; down>=0; down--) {
        CGEventRef event=CGEventCreateKeyboardEvent(NULL,code,down);
        CGEventSetFlags(event,flags);
        if (character) CGEventKeyboardSetUnicodeString(event,1,&character);
        CGEventPostToPSN(&process,event); CFRelease(event);
    }
    usleep(50000);
}

static NSDictionary *visibleWindow(pid_t pid)
{
    NSArray *windows=(NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
    NSDictionary *largest=nil; double area=0;
    for (NSDictionary *window in windows) {
        if ([[window objectForKey:(id)kCGWindowOwnerPID] intValue]!=pid ||
            [[window objectForKey:(id)kCGWindowLayer] intValue]!=0) continue;
        CGRect bounds;
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)[window objectForKey:(id)kCGWindowBounds],&bounds);
        double candidate=bounds.size.width*bounds.size.height;
        if (candidate>area) { area=candidate; largest=window; }
    }
    [[largest retain] autorelease]; [windows release]; return largest;
}

static BOOL fullscreen(NSDictionary *window)
{
    if (!window) return NO;
    CGRect bounds;
    CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)[window objectForKey:(id)kCGWindowBounds],&bounds);
    CGSize screen=CGDisplayBounds(CGMainDisplayID()).size;
    return CGSizeEqualToSize(bounds.size,screen);
}

static BOOL capture(NSDictionary *window, NSString *path)
{
    if (!window) return NO;
    CGWindowID number=[[window objectForKey:(id)kCGWindowNumber] unsignedIntValue];
    CGImageRef image=CGWindowListCreateImage(CGRectNull,kCGWindowListOptionIncludingWindow,number,kCGWindowImageBoundsIgnoreFraming);
    if (!image) return NO;
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithCGImage:image];
    NSData *png=[bitmap representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
    BOOL ok=[png writeToFile:path atomically:YES];
    [bitmap release]; CGImageRelease(image); return ok;
}

int main(int argc,char **argv)
{
    if (argc!=4) { fputs("Usage: lifecycle-probe APP windowed|fullscreen|restored|held|login CAPTURE_PREFIX\n",stderr); return 2; }
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    NSString *mode=[NSString stringWithUTF8String:argv[2]], *prefix=[NSString stringWithUTF8String:argv[3]];
    BOOL held=[mode isEqualToString:@"held"];
    if (![mode isEqualToString:@"windowed"] && ![mode isEqualToString:@"fullscreen"] &&
        ![mode isEqualToString:@"restored"] && ![mode isEqualToString:@"login"] && !held) return 2;
    NSString *fixture=[prefix stringByAppendingString:@".command"];
    NSTask *task=[[NSTask alloc] init]; [task setLaunchPath:[NSString stringWithUTF8String:argv[1]]];
    if (held) {
        [@"#!/bin/sh\nsleep 3\nexit 7\n" writeToFile:fixture atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        chmod([fixture fileSystemRepresentation],0700);
        [task setArguments:[NSArray arrayWithObjects:@"--execute-file",fixture,nil]];
    } else if (![mode isEqualToString:@"login"])
        [task setArguments:[NSArray arrayWithObjects:@"--command",@"exec /bin/sh -i",nil]];
    [task launch]; pid_t pid=[task processIdentifier];
    NSDictionary *window=nil;
    for (int i=0;i<100 && [task isRunning];i++) {
        window=visibleWindow(pid); if (window) break; usleep(100000);
    }
    BOOL ok=window!=nil;
    usleep(500000);
    if (![mode isEqualToString:@"windowed"] && ok) {
        key(pid,36,kCGEventFlagMaskCommand,0); usleep(700000);
        window=visibleWindow(pid); ok=fullscreen(window);
        fprintf(stderr,"Targeted Command-Enter fullscreen: %s\n",ok ? "PASS" : "FAIL");
        if ([mode isEqualToString:@"restored"] && ok) {
            key(pid,36,kCGEventFlagMaskCommand,0); usleep(700000);
            window=visibleWindow(pid); ok=window && !fullscreen(window);
        }
    }
    if (ok) ok=capture(window,[prefix stringByAppendingString:@"-before.png"]);
    if (!held && ok) {
        const UniChar command[]={'e','x','i','t',' ','7'};
        for (unsigned int i=0;i<sizeof(command)/sizeof(command[0]);i++) key(pid,0,0,command[i]);
        key(pid,36,0,'\r');
    }
    usleep(3500000);
    BOOL running=[task isRunning]; window=visibleWindow(pid);
    if (window) capture(window,[prefix stringByAppendingString:@"-after.png"]);
    if (held) ok=ok && running && fullscreen(window);
    else ok=ok && running && !window;
    fprintf(stderr,"%s shell exit: %s (process=%s, visible window=%s)\n",argv[2],ok ? "PASS" : "FAIL",
        running ? "running" : "exited",window ? "present" : "none");
    if (running) {
        key(pid,12,kCGEventFlagMaskCommand,0);
        for (int i=0;i<30 && [task isRunning];i++) usleep(100000);
        if ([task isRunning]) { [task terminate]; [task waitUntilExit]; }
    }
    if (held) unlink([fixture fileSystemRepresentation]);
    [task release]; [pool drain]; return ok ? 0 : 1;
}
