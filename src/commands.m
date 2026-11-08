#import "terminal.h"
#import "config.h"
#include <signal.h>
#include <unistd.h>

@implementation TerminalView (Commands)
- (void)applyTerminalColors
{
    core_check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &imac_config.background), "background");
    core_check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &imac_config.foreground), "foreground");
    core_check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &imac_config.cursor), "cursor color");
    GhosttyColorRgb palette[256];
    core_check(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT,palette),"default palette");
    memcpy(palette,imac_config.palette,sizeof(imac_config.palette));
    core_check(ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,palette),"Mocha palette");
}
- (void)applyConfiguration
{
    [self applyTerminalColors]; [self setFontSize:imac_config.font_size]; [self setNeedsDisplay:YES];
}
- (void)clearScrollback:(id)sender
{
    (void)sender; size_t limit=0,zero=0;
    core_check(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES,&limit),"scrollback limit");
    core_check(ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_SELECTION,NULL),"clear scrollback selection");
    selection_active=selecting=NO;
    core_check(ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,&zero),"clear scrollback");
    core_check(ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,&limit),"restore scrollback limit");
    [self setNeedsDisplay:YES];
}
- (void)resetTerminal:(id)sender
{
    (void)sender; ghostty_terminal_reset(terminal);
    selection_active=selecting=NO;
    [self applyTerminalColors]; [self updateTitle]; [self setNeedsDisplay:YES];
    pid_t fg_group=master>=0 ? tcgetpgrp(master) : 0;
    if (fg_group>0) kill(-fg_group,SIGWINCH);
}
- (void)scrollHistoryForKey:(GhosttyKey)navigation
{
    GhosttyTerminalScrollViewport scroll={GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA,{0}};
    if (navigation==GHOSTTY_KEY_HOME) scroll.tag=GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP;
    else if (navigation==GHOSTTY_KEY_END) scroll.tag=GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM;
    else scroll.value.delta=(navigation==GHOSTTY_KEY_PAGE_UP ? -1 : 1)*MAX(1,lines-1);
    core_check(ghostty_terminal_scroll_viewport(terminal,scroll),"keyboard scrollback"); [self setNeedsDisplay:YES];
}
@end
