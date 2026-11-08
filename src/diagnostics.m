#import "terminal.h"
#import "application.h"
#include <math.h>

@implementation TerminalView (Diagnostics)
- (void)startDiagnostics
{
    testing=snow_app.self_test || snow_app.integration_test;
    if (snow_app.self_test) {
        const char *fixture="\033[2J\033[H\033[1mSnow Ghostty — Radeon X1600\033[0m\r\n"
            "Ghostty terminal engine + native Cocoa + OpenGL 2.0 / GLSL 1.20\r\n\r\n"
            "\033[31mRed \033[32mGreen \033[33mYellow \033[34mBlue \033[35mMagenta \033[36mCyan\033[0m\r\n"
            "\033[38;2;255;140;80mTruecolor orange\033[0m   \033[48;2;45;65;90mColored background\033[0m\r\n"
            "Normal  \033[1mBold\033[0m  \033[3mItalic\033[0m  \033[1;3mBold italic\033[0m\r\n"
            "\033[4mUnderline\033[0m  \033[9mStrikethrough\033[0m  \033[7mInverse\033[0m  \033[2mFaint\033[0m\r\n\r\n"
            "Latvian: ā č ē ģ ī ķ ļ ņ š ū ž Ā Č Ē Ģ Ī Ķ Ļ Ņ Š Ū Ž\r\n"
            "Combining: a\xcc\x84 e\xcc\x81 o\xcc\x88   Wide: 中文 日本語\r\n"
            "┌────────────────────────────────┐\r\n"
            "│ Crisp glyphs at native pixels  │\r\n"
            "├────────────────────────────────┤\r\n"
            "│ One window. Use tmux for panes.│\r\n"
            "└────────────────────────────────┘\r\n\r\n"
            "GPU rendering fixture: ready.\r\n";
        ghostty_terminal_vt_write(terminal,(const uint8_t *)fixture,strlen(fixture));
        [self setNeedsDisplay:YES];
        [self performSelector:@selector(testSelection:) withObject:nil afterDelay:0.25];
        if (snow_app.requested_capture) [self performSelector:@selector(requestCapture:) withObject:nil afterDelay:0.5];
        [self performSelector:@selector(finishTest:) withObject:nil afterDelay:2.0];
    } else if (snow_app.integration_test) {
        test_deadline=[NSDate timeIntervalSinceReferenceDate]+8;
        [self performSelector:@selector(runIntegration:) withObject:nil afterDelay:0.5];
    } else if (snow_app.requested_capture) [self performSelector:@selector(requestCapture:) withObject:nil afterDelay:2];
}
- (void)pressFullscreenKey
{
    NSEvent *event=[NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:NSCommandKeyMask
        timestamp:0 windowNumber:[[self window] windowNumber] context:nil characters:@"\r"
        charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
    if (![[self window] performKeyEquivalent:event]) [self keyDown:event];
}
- (void)finishTest:(id)sender
{
    (void)sender;
    fprintf(stderr,"Rendered frames: %lu; rasterized glyphs: %lu; cached glyphs: %lu\n",frames,uploaded,(unsigned long)[glyphs count]);
    fprintf(stderr,"Frame wall time including swap (excluding PNG frames): mean %.2f ms; maximum %.2f ms\n",timed_frames ? draw_milliseconds/timed_frames : 0,max_draw_milliseconds);
    fprintf(stderr,"After first three frames (%lu samples): mean %.2f ms; maximum %.2f ms\n",warm_frames,warm_frames ? warm_draw_milliseconds/warm_frames : 0,max_warm_draw_milliseconds);
    if (!frames || !uploaded) snow_app.test_result=1;
    [NSApp terminate:nil];
}
- (void)requestCapture:(id)sender
{
    (void)sender;
    capture_path = [snow_app.requested_capture copy];
    [self setNeedsDisplay:YES];
}
- (NSString *)screenText
{
    GhosttyFormatter formatter = NULL;
    core_check(ghostty_formatter_terminal_new(NULL,&formatter,terminal),"test formatter");
    uint8_t *data=NULL; size_t length=0;
    core_check(ghostty_formatter_format_alloc(formatter,NULL,&data,&length),"test snapshot");
    NSString *text=[[[NSString alloc] initWithBytes:data length:length encoding:NSUTF8StringEncoding] autorelease];
    ghostty_free(NULL,data,length); ghostty_formatter_free(formatter);
    return text ? text : @"";
}
- (void)testSelection:(id)sender
{
    (void)sender;
    NSPoint point=[self convertPoint:NSMakePoint(PAD+cell_width*0.5,[self bounds].size.height-PAD-cell_height*0.5) toView:nil];
    NSEvent *event=[NSEvent mouseEventWithType:NSLeftMouseDown location:point modifierFlags:0 timestamp:0
        windowNumber:[[self window] windowNumber] context:nil eventNumber:1 clickCount:2 pressure:1];
    [self mouseDown:event];
    GhosttyFormatter formatter=NULL;
    core_check(ghostty_formatter_terminal_new(NULL,&formatter,terminal),"selection formatter");
    core_check(ghostty_formatter_set(formatter,GHOSTTY_FORMATTER_OPT_SELECTION,&selection),"selection range");
    uint8_t *bytes=NULL; size_t length=0;
    GhosttyResult result=ghostty_formatter_format_alloc(formatter,NULL,&bytes,&length);
    ghostty_formatter_free(formatter);
    if (result!=GHOSTTY_SUCCESS || length!=4 || memcmp(bytes,"Snow",4)) {
        fprintf(stderr,"Cocoa double-click / word selection formatting: FAIL\n"); snow_app.test_result=1;
    } else fprintf(stderr,"Cocoa double-click / word selection formatting: PASS\n");
    if(bytes) ghostty_free(NULL,bytes,length);
    ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_SELECTION,NULL);
    selection_active=selecting=NO; [self setNeedsDisplay:YES];
}
- (void)typeCommand:(NSString *)command
{
    // Feed normal Cocoa keyDown/interpretKeyEvents events, including Return.
    for (NSUInteger i=0;i<[command length];i++) {
        NSString *character=[command substringWithRange:NSMakeRange(i,1)];
        unsigned short code=[character isEqualToString:@"\n"] ? 36 : 0;
        if (code==36) character=@"\r";
        NSEvent *event=[NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:0
            timestamp:0 windowNumber:[[self window] windowNumber] context:nil characters:character
            charactersIgnoringModifiers:character isARepeat:NO keyCode:code];
        [self keyDown:event];
    }
}
- (void)runIntegration:(id)sender
{
    (void)sender;
    int previous_stage=test_stage;
    NSString *text=[self screenText];
    BOOL ready=NO;
    switch (test_stage) {
        case 0:
            [self typeCommand:@"printf '\\033[2J\\033[H'; printf 'PTY_INPUT_OK\\n'; stty size\n"];
            test_stage=1; break;
        case 1:
            ready=[text rangeOfString:@"\nPTY_INPUT_OK\n"].location!=NSNotFound || [text hasPrefix:@"PTY_INPUT_OK\n"];
            if (ready) {
                fprintf(stderr,"Cocoa keyboard → PTY → Ghostty output: PASS\n");
                test_window_frame=[[self window] frame];
                [self pressFullscreenKey];
                test_stage=10;
            }
            break;
        case 10:
            if (![self isTerminalFullscreen] || !NSEqualSizes([self bounds].size,[[[self window] screen] frame].size)) {
                fprintf(stderr,"Command-Enter fullscreen geometry: FAIL\n"); snow_app.test_result=1; [self finishTest:nil]; return;
            }
            [self typeCommand:@"printf 'FULLSCREEN:'; stty size\n"]; test_stage=11;
            break;
        case 11: {
            NSString *expected=[NSString stringWithFormat:@"\nFULLSCREEN:%u %u\n",lines,columns];
            ready=[text rangeOfString:expected].location!=NSNotFound;
            if (ready) {
                fprintf(stderr,"Command-Enter fullscreen / PTY size: PASS (%u x %u)\n",columns,lines);
                if (snow_app.requested_capture) {
                    capture_path=[[[snow_app.requested_capture stringByDeletingPathExtension] stringByAppendingString:@"-fullscreen.png"] copy];
                    [self display];
                }
                [self pressFullscreenKey]; test_stage=12;
            }
            break;
        }
        case 12:
            if ([self isTerminalFullscreen] || !NSEqualRects([[self window] frame],test_window_frame)) {
                fprintf(stderr,"Command-Enter restored window: FAIL\n"); snow_app.test_result=1; [self finishTest:nil]; return;
            }
            [self typeCommand:@"printf 'RESTORED:'; stty size\n"]; test_stage=13;
            break;
        case 13: {
            NSString *expected=[NSString stringWithFormat:@"\nRESTORED:%u %u\n",lines,columns];
            ready=[text rangeOfString:expected].location!=NSNotFound;
            if (ready) {
                fprintf(stderr,"Command-Enter restored window / PTY size: PASS (%u x %u)\n",columns,lines);
                [[self window] setContentSize:NSMakeSize(1050,700)];
                [self typeCommand:@"printf 'RESIZE:'; stty size\n"];
                test_stage=2;
            }
            break;
        }
        case 2: {
            NSString *expected=[NSString stringWithFormat:@"\nRESIZE:%u %u\n",lines,columns];
            ready=[text rangeOfString:expected].location!=NSNotFound;
            if (ready) {
                fprintf(stderr,"Cocoa resize → PTY TIOCSWINSZ: PASS (%u x %u)\n",columns,lines);
                [self typeCommand:@"sleep 20\n"];
                test_stage=3;
            }
            break;
        }
        case 3: {
            NSEvent *event=[NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:NSControlKeyMask
                timestamp:0 windowNumber:[[self window] windowNumber] context:nil characters:@"\003"
                charactersIgnoringModifiers:@"c" isARepeat:NO keyCode:8];
            [self keyDown:event];
            [self typeCommand:@"printf 'CTRL_C_OK\\n'\n"];
            test_stage=4; break;
        }
        case 4:
            ready=[text rangeOfString:@"\nCTRL_C_OK\n"].location!=NSNotFound;
            if (ready) {
                fprintf(stderr,"Ctrl-C interrupt and continued shell input: PASS\n");
                [self typeCommand:@"i=0; while [ $i -lt 2000 ]; do printf 'SCROLL_TEST %04d 0123456789 abcdefghijklmnopqrstuvwxyz\\n' $i; i=$((i+1)); done; printf 'SCROLL_DONE\\n'\n"];
                test_stage=9;
            }
            break;
        case 9:
            ready=[text rangeOfString:@"\nSCROLL_DONE\n"].location!=NSNotFound;
            if (ready) {
                size_t history=0;
                ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS,&history);
                if(history<1000) { fprintf(stderr,"Scrollback retention: FAIL (%lu)\n",(unsigned long)history); snow_app.test_result=1; }
                else fprintf(stderr,"2000-line PTY output and scrollback: PASS (%lu history rows)\n",(unsigned long)history);
                [self typeCommand:[NSString stringWithFormat:
                    @"/opt/local/bin/tmux -L ghostty-imac-test-%d -f /dev/null new-session 'exec /bin/sh -i'\n",getpid()]];
                test_stage=5;
            }
            break;
        case 5:
            [self typeCommand:@"printf '\\033[2J\\033[H'; printf 'TMUX_INPUT_OK\\n'; printf 'TMUX_SIZE:'; stty size\n"];
            test_stage=6; break;
        case 6: {
            NSString *expected=[NSString stringWithFormat:@"\nTMUX_SIZE:%u %u\n",lines-1,columns];
            ready=([text rangeOfString:@"\nTMUX_INPUT_OK\n"].location!=NSNotFound || [text hasPrefix:@"TMUX_INPUT_OK\n"]) &&
                  [text rangeOfString:expected].location!=NSNotFound;
            if (ready) {
                fprintf(stderr,"tmux interactive pane / alternate screen / size: PASS\n");
                if (snow_app.requested_capture) { [self requestCapture:nil]; [self display]; }
                [self typeCommand:@"exit\n"];
                test_stage=7;
            }
            break;
        }
        case 7:
            [self typeCommand:@"exit\n"];
            test_stage=8; break;
        case 8:
            ready=child==0;
            if (ready) { fprintf(stderr,"Shell lifecycle and tmux cleanup: PASS\n"); [self finishTest:nil]; return; }
            break;
    }
    NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
    if (test_stage!=previous_stage) test_deadline=now+8;
    if (test_stage && now>test_deadline) {
        fprintf(stderr,"Integration stage %d timed out; screen:\n%s\n",test_stage,[text UTF8String]);
        snow_app.test_result=1;
        if (snow_app.requested_capture) { [self requestCapture:nil]; [self display]; }
        [self finishTest:nil]; return;
    }
    [self performSelector:@selector(runIntegration:) withObject:nil afterDelay:0.4];
}
@end
