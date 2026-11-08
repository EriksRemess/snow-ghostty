#pragma once
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <OpenGL/gl.h>
#include <ghostty/vt.h>
#include <stdio.h>
#include <stdlib.h>

enum { ATLAS_SIZE = 2048, PAD = 8, READ_BUDGET = 256 * 1024 };
typedef struct { GLfloat x, y, u, v, r, g, b, a; } Vertex;
typedef struct { Vertex *data; size_t count, capacity; } Mesh;
typedef struct { int x, y, width, height; } Glyph;
static inline void core_check(GhosttyResult result, const char *operation)
{
    if (result != GHOSTTY_SUCCESS) {
        fprintf(stderr, "%s failed: %d\n", operation, result);
        exit(1);
    }
}

@interface TerminalView : NSOpenGLView {
@public
    GhosttyTerminal terminal;
    GhosttyRenderState render;
    GhosttyRenderStateRowIterator rows;
    GhosttyRenderStateRowCells cells;
    GhosttyKeyEncoder keys;
    GhosttyKeyEvent key;
    GhosttyMouseEncoder mouse;
    GhosttyMouseEvent mouse_event;
    GhosttySelection selection;
    BOOL selection_active, selecting;
    int master;
    pid_t child;
    uint16_t columns, lines;
    int cell_width, cell_height;
    int terminal_cell_width, terminal_cell_height;
    CGFloat font_size;
    NSString *configured_font_family;
    CTFontRef fonts[4];
    GLfloat baseline;
    NSMutableDictionary *glyphs;
    NSMutableData *pending;
    NSMutableAttributedString *marked;
    NSEvent *input_event;
    NSTimer *timer;
    NSTabViewItem *tab_item; // owned by the tab view, not by this view
    NSTabView *tab_host;
    BOOL retain_output, testing;
    NSString *capture_path;
    GLuint atlas, program, vbo;
    int atlas_x, atlas_y, atlas_row_height;
    Mesh background, foreground;
    BOOL gl_ready, blink_on, render_hold;
    NSTimeInterval next_blink, hold_deadline;
    NSTimeInterval next_title;
    pid_t title_owner;
    NSString *title_process;
    unsigned long frames, uploaded, timed_frames, warm_frames;
    double draw_milliseconds, max_draw_milliseconds;
    double warm_draw_milliseconds, max_warm_draw_milliseconds;
    int test_stage;
    NSTimeInterval test_deadline;
    NSRect test_window_frame;
}
- (id)initWithFrame:(NSRect)frame fd:(int)fd child:(pid_t)pid;
- (void)queueBytes:(const uint8_t *)data length:(size_t)length;
- (void)tick:(NSTimer *)source;
- (void)closeSession;
- (void)updateTitle;
@end

@interface TerminalView (Rendering)
- (Glyph)glyphForText:(NSString *)text style:(int)style width:(int)width;
- (void)drawMesh:(Mesh *)mesh;
- (void)capture:(NSString *)path;
@end

@interface TerminalView (Input) <NSTextInputClient>
- (void)sendKey:(NSEvent *)event text:(NSString *)text;
- (void)toggleFullscreen:(id)sender;
- (BOOL)isTerminalFullscreen;
- (BOOL)reportMouse:(NSEvent *)event action:(GhosttyMouseAction)action button:(GhosttyMouseButton)button;
@end

@interface TerminalView (Commands)
- (void)applyConfiguration;
- (void)applyTerminalColors;
- (void)clearScrollback:(id)sender;
- (void)resetTerminal:(id)sender;
- (void)scrollHistoryForKey:(GhosttyKey)key;
@end

@interface TerminalView (Fonts)
- (void)setFontSize:(CGFloat)size;
- (void)increaseFontSize:(id)sender;
- (void)decreaseFontSize:(id)sender;
- (void)resetFontSize:(id)sender;
@end

@interface TerminalView (Diagnostics)
- (void)startDiagnostics;
- (void)finishTest:(id)sender;
- (void)requestCapture:(id)sender;
- (void)runIntegration:(id)sender;
- (void)testSelection:(id)sender;
- (void)pressFullscreenKey;
- (NSString *)screenText;
- (void)typeCommand:(NSString *)command;
@end
