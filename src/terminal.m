#import "terminal.h"
#import "config.h"
#import "session.h"
#import "tabs.h"
#include <OpenGL/OpenGL.h>
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <libproc.h>

static void write_pty(GhosttyTerminal terminal, void *userdata, const uint8_t *data, size_t length)
{
    (void)terminal;
    [(TerminalView *)userdata queueBytes:data length:length];
}

static void title_changed(GhosttyTerminal terminal, void *userdata)
{
    (void)terminal; TerminalView *view=(TerminalView *)userdata;
    view->title_owner=view->master>=0 ? tcgetpgrp(view->master) : view->child;
    char command[256]={0};
    snow_session_process_name(view->title_owner,command,sizeof(command));
    [view->title_process release]; view->title_process=[[NSString alloc] initWithUTF8String:command];
    [view updateTitle];
}

static void render_hold_changed(GhosttyTerminal terminal, void *userdata, bool held)
{
    (void)terminal;
    TerminalView *view = userdata;
    // Freeze a snapshot before accepting the held updates.
    if (held && !view->render_hold) core_check(ghostty_render_state_update(view->render, view->terminal), "render hold");
    view->render_hold = held;
    view->hold_deadline = [NSDate timeIntervalSinceReferenceDate] + 1.0;
    if (!held) [view setNeedsDisplay:YES];
}

@implementation TerminalView
- (id)initWithFrame:(NSRect)frame fd:(int)fd child:(pid_t)pid
{
    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAAccelerated, NSOpenGLPFANoRecovery, NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8, 0
    };
    NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    if (!format) { fputs("No hardware OpenGL pixel format\n", stderr); exit(1); }
    self = [super initWithFrame:frame pixelFormat:format]; [format release];
    if (!self) return nil;
    master = fd; child = pid; columns = 100; lines = 30;
    [self setFontSize:imac_config.font_size];
    glyphs = [[NSMutableDictionary alloc] init];
    pending = [[NSMutableData alloc] init];
    marked = [[NSMutableAttributedString alloc] initWithString:@""];
    core_check(ghostty_terminal_new(NULL, &terminal, columns, lines), "terminal creation");
    core_check(ghostty_render_state_new(NULL, &render), "render creation");
    core_check(ghostty_render_state_row_iterator_new(NULL, &rows), "row iterator");
    core_check(ghostty_render_state_row_cells_new(NULL, &cells), "cell iterator");
    core_check(ghostty_key_encoder_new(NULL, &keys), "keyboard encoder");
    core_check(ghostty_key_event_new(NULL, &key), "keyboard event");
    core_check(ghostty_mouse_encoder_new(NULL, &mouse), "mouse encoder");
    core_check(ghostty_mouse_event_new(NULL, &mouse_event), "mouse event");
    core_check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, self), "terminal userdata");
    core_check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)write_pty), "PTY callback");
    core_check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, (const void *)title_changed), "title callback");
    core_check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, (const void *)render_hold_changed), "render hold callback");
    [self applyTerminalColors];
    size_t scrollback_bytes = 16 * 1024 * 1024, scrollback_lines = 10000;
    core_check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback_bytes), "scrollback bytes");
    core_check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback_lines), "scrollback lines");
    blink_on = YES; next_blink = [NSDate timeIntervalSinceReferenceDate] + 0.5;
    timer = [[NSTimer timerWithTimeInterval:1.0 / 60 target:self selector:@selector(tick:)
                                 userInfo:nil repeats:YES] retain];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    fprintf(stderr, "Terminal cells: %d x %d px; bounded atlas: %d x %d A8\n", cell_width, cell_height, ATLAS_SIZE, ATLAS_SIZE);
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (void)updateTitle
{
    GhosttyString title={0}; NSString *name=nil;
    pid_t fg_pid=master>=0 ? tcgetpgrp(master) : child;
    if (fg_pid<=0) fg_pid=child;
    char command[256]={0};
    snow_session_process_name(fg_pid,command,sizeof(command));
    if (!command[0] && child>0) snow_session_process_name(child,command,sizeof(command));
    NSString *process=[NSString stringWithUTF8String:command];
    // A shell's prompt title must not hide a foreground job that does not emit
    // OSC titles. Process names also catch exec() without a PID change.
    BOOL current_title=child<=0 || title_owner<=0 ||
        (title_owner==fg_pid && [title_process isEqualToString:process]);
    if (current_title && ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_TITLE,&title)==GHOSTTY_SUCCESS && title.len)
        name=[[[NSString alloc] initWithBytes:title.ptr length:title.len encoding:NSUTF8StringEncoding] autorelease];
    if (![name length] && child>0) {
        struct proc_vnodepathinfo info={0}; NSString *directory=nil;
        int size=proc_pidinfo(fg_pid,PROC_PIDVNODEPATHINFO,0,&info,sizeof(info));
        if (size!=sizeof(info) && fg_pid!=child) size=proc_pidinfo(child,PROC_PIDVNODEPATHINFO,0,&info,sizeof(info));
        if (size==sizeof(info))
            directory=[NSString stringWithUTF8String:info.pvi_cdir.vip_path];
        NSString *base=[directory isEqualToString:NSHomeDirectory()] ? @"~" : [directory lastPathComponent];
        if ([process length]) name=[base length] ? [NSString stringWithFormat:@"%@ — %@",base,process] : process;
    }
    if (![name length]) name=[tab_item label];
    if (![name length]) name=@"Snow Ghostty";
    if (![[tab_item label] isEqualToString:name]) {
        [tab_item setLabel:name]; [(SnowTabView *)tab_host refreshTabLabels];
    }
    if ([tab_host selectedTabViewItem]==tab_item) [[tab_host window] setTitle:name];
}
- (BOOL)isOpaque { return YES; }
- (void)queueBytes:(const uint8_t *)data length:(size_t)length
{
    if (master < 0) return;
    if ([pending length]+length > 1024*1024) { NSBeep(); return; }
    [pending appendBytes:data length:length];
}

- (void)tick:(NSTimer *)source
{
    (void)source;
    if (master >= 0) {
        if ([pending length]) {
            ssize_t n=write(master,[pending bytes],[pending length]);
            if (n>0) [pending replaceBytesInRange:NSMakeRange(0,n) withBytes:NULL length:0];
            else if (n<0 && errno!=EAGAIN && errno!=EINTR) { perror("PTY write"); [pending setLength:0]; }
        }
        uint8_t buffer[16384]; size_t received=0;
        while (received<READ_BUDGET) {
            ssize_t n=read(master,buffer,sizeof(buffer));
            if (n>0) {
                if (selection_active) {
                    ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_SELECTION,NULL);
                    selection_active=selecting=NO;
                }
                ghostty_terminal_vt_write(terminal,buffer,n); received+=n;
            }
            else if (n<0 && errno==EINTR) continue;
            else {
                if (n==0 || (n<0 && errno!=EAGAIN)) { close(master); master=-1; }
                break;
            }
        }
        if (received && !render_hold) [self setNeedsDisplay:YES];
    }
    if (child>0) {
        int status;
        if (waitpid(child,&status,WNOHANG)==child) {
            child=0;
            fprintf(stderr,"Shell exited: %d\n",WIFEXITED(status) ? WEXITSTATUS(status) : -1);
            if (!testing && !retain_output)
                [(id)[tab_host delegate] performSelector:@selector(terminalExited:) withObject:self afterDelay:0.15];
            else if (retain_output) {
                char message[96]; int length=snprintf(message,sizeof(message),"\r\n[Process exited: %d]\r\n",WIFEXITED(status) ? WEXITSTATUS(status) : -1);
                ghostty_terminal_vt_write(terminal,(const uint8_t *)message,length); [self setNeedsDisplay:YES];
            }
        }
    }
    NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
    if (now>=next_title) { [self updateTitle]; next_title=now+1; }
    if (render_hold && now>=hold_deadline) {
        GhosttyTerminalModeConfig mode={GHOSTTY_MODE_SYNCHRONIZED_OUTPUT,false};
        ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_MODE,&mode);
        render_hold=NO; [self setNeedsDisplay:YES];
    }
    if (now>=next_blink) { blink_on=!blink_on; next_blink=now+0.5; if (!render_hold) [self setNeedsDisplay:YES]; }
}

- (void)closeSession
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [timer invalidate];
    snow_session_close(master,child); master=-1; child=0;
}
- (void)dealloc
{
    [self closeSession]; [timer release];
    ghostty_key_event_free(key); ghostty_key_encoder_free(keys);
    ghostty_mouse_event_free(mouse_event); ghostty_mouse_encoder_free(mouse);
    ghostty_render_state_row_cells_free(cells); ghostty_render_state_row_iterator_free(rows);
    ghostty_render_state_free(render); ghostty_terminal_free(terminal);
    [[self openGLContext] makeCurrentContext];
    if (vbo) glDeleteBuffers(1,&vbo); if (atlas) glDeleteTextures(1,&atlas); if (program) glDeleteProgram(program);
    for (int i=0;i<4;i++) CFRelease(fonts[i]);
    free(background.data); free(foreground.data);
    [glyphs release]; [pending release]; [marked release]; [input_event release]; [title_process release]; [capture_path release]; [configured_font_family release];
    [super dealloc];
}
@end
