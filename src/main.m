#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <ghostty/vt.h>
#include "platform.h"
#include "config.h"
#include "desktop.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pwd.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

enum { ATLAS_SIZE = 2048, PAD = 8, READ_BUDGET = 256 * 1024 };
typedef struct { GLfloat x, y, u, v, r, g, b, a; } Vertex;
typedef struct { Vertex *data; size_t count, capacity; } Mesh;
typedef struct { int x, y, width, height; } Glyph;
static int test_result = 0;
static BOOL self_test = NO;
static BOOL integration_test = NO;
static BOOL keep_on_exit = NO;
static BOOL explicit_cli = NO;
static NSString *capture_path = nil;
static NSString *requested_capture = nil;
static NSString *startup_config_path = nil;

static void core_check(GhosttyResult result, const char *operation)
{
    if (result != GHOSTTY_SUCCESS) {
        fprintf(stderr, "%s failed: %d\n", operation, result);
        exit(1);
    }
}

static void quad(Mesh *mesh, float x, float y, float w, float h,
                 float u0, float v0, float u1, float v1,
                 GhosttyColorRgb color, float alpha)
{
    if (mesh->count + 6 > mesh->capacity) {
        size_t capacity = mesh->capacity ? mesh->capacity * 2 : 4096;
        Vertex *memory = realloc(mesh->data, capacity * sizeof(Vertex));
        if (!memory) { fputs("Out of vertex memory\n", stderr); exit(1); }
        mesh->data = memory; mesh->capacity = capacity;
    }
    float r = color.r / 255.0f, g = color.g / 255.0f, b = color.b / 255.0f;
    Vertex vertices[] = {
        {x,y,u0,v0,r,g,b,alpha}, {x+w,y,u1,v0,r,g,b,alpha}, {x+w,y+h,u1,v1,r,g,b,alpha},
        {x,y,u0,v0,r,g,b,alpha}, {x+w,y+h,u1,v1,r,g,b,alpha}, {x,y+h,u0,v1,r,g,b,alpha}
    };
    memcpy(mesh->data + mesh->count, vertices, sizeof(vertices));
    mesh->count += 6;
}

static GLuint shader(GLenum kind, const char *source)
{
    GLuint object = glCreateShader(kind);
    glShaderSource(object, 1, &source, NULL); glCompileShader(object);
    GLint ok = 0; glGetShaderiv(object, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[4096]; glGetShaderInfoLog(object, sizeof(log), NULL, log);
        fprintf(stderr, "GL shader: %s\n", log); exit(1);
    }
    return object;
}

static BOOL rasterize_block(UniChar character, uint8_t *bitmap, int width, int height)
{
    if (character < 0x2580 || character > 0x259f) return NO;
    const unsigned char quadrants[] = {4,8,1,13,9,7,11,2,6,14};
    int split_x=(width+1)/2, split_y=height/2;
    for (int y=0; y<height; y++) for (int x=0; x<width; x++) {
        BOOL ink=NO;
        if (character==0x2580) ink=y<split_y;
        else if (character<=0x2588) ink=y>=height-(height*(character-0x2580)+4)/8;
        else if (character<=0x258f) ink=x<(width*(0x2590-character)+4)/8;
        else if (character==0x2590) ink=x>=split_x;
        else if (character<=0x2593) {
            BOOL dot=((x+2*(y&1))&3)==0;
            ink=character==0x2591 ? dot : character==0x2592 ? ((x+y)&1)==0 : !dot;
        } else if (character==0x2594) ink=y<(height+4)/8;
        else if (character==0x2595) ink=x>=width-(width+4)/8;
        else {
            unsigned int quadrant=(y<split_y ? 1 : 4) << (x>=split_x);
            ink=(quadrants[character-0x2596]&quadrant)!=0;
        }
        bitmap[y*width+x]=ink ? 255 : 0;
    }
    return YES;
}

static GhosttyKey physical_key(unsigned short code)
{
    switch (code) {
        case 0: return GHOSTTY_KEY_A; case 1: return GHOSTTY_KEY_S;
        case 2: return GHOSTTY_KEY_D; case 3: return GHOSTTY_KEY_F;
        case 4: return GHOSTTY_KEY_H; case 5: return GHOSTTY_KEY_G;
        case 6: return GHOSTTY_KEY_Z; case 7: return GHOSTTY_KEY_X;
        case 8: return GHOSTTY_KEY_C; case 9: return GHOSTTY_KEY_V;
        case 11: return GHOSTTY_KEY_B; case 12: return GHOSTTY_KEY_Q;
        case 13: return GHOSTTY_KEY_W; case 14: return GHOSTTY_KEY_E;
        case 15: return GHOSTTY_KEY_R; case 16: return GHOSTTY_KEY_Y;
        case 17: return GHOSTTY_KEY_T; case 18: return GHOSTTY_KEY_DIGIT_1;
        case 19: return GHOSTTY_KEY_DIGIT_2; case 20: return GHOSTTY_KEY_DIGIT_3;
        case 21: return GHOSTTY_KEY_DIGIT_4; case 22: return GHOSTTY_KEY_DIGIT_6;
        case 23: return GHOSTTY_KEY_DIGIT_5; case 24: return GHOSTTY_KEY_EQUAL;
        case 25: return GHOSTTY_KEY_DIGIT_9; case 26: return GHOSTTY_KEY_DIGIT_7;
        case 27: return GHOSTTY_KEY_MINUS; case 28: return GHOSTTY_KEY_DIGIT_8;
        case 29: return GHOSTTY_KEY_DIGIT_0; case 30: return GHOSTTY_KEY_BRACKET_RIGHT;
        case 31: return GHOSTTY_KEY_O; case 32: return GHOSTTY_KEY_U;
        case 33: return GHOSTTY_KEY_BRACKET_LEFT; case 34: return GHOSTTY_KEY_I;
        case 35: return GHOSTTY_KEY_P; case 36: case 76: return GHOSTTY_KEY_ENTER;
        case 37: return GHOSTTY_KEY_L; case 38: return GHOSTTY_KEY_J;
        case 39: return GHOSTTY_KEY_QUOTE; case 40: return GHOSTTY_KEY_K;
        case 41: return GHOSTTY_KEY_SEMICOLON; case 42: return GHOSTTY_KEY_BACKSLASH;
        case 43: return GHOSTTY_KEY_COMMA; case 44: return GHOSTTY_KEY_SLASH;
        case 45: return GHOSTTY_KEY_N; case 46: return GHOSTTY_KEY_M;
        case 47: return GHOSTTY_KEY_PERIOD; case 48: return GHOSTTY_KEY_TAB;
        case 49: return GHOSTTY_KEY_SPACE; case 50: return GHOSTTY_KEY_BACKQUOTE;
        case 51: return GHOSTTY_KEY_BACKSPACE; case 53: return GHOSTTY_KEY_ESCAPE;
        case 115: return GHOSTTY_KEY_HOME; case 116: return GHOSTTY_KEY_PAGE_UP;
        case 117: return GHOSTTY_KEY_DELETE; case 119: return GHOSTTY_KEY_END;
        case 121: return GHOSTTY_KEY_PAGE_DOWN; case 123: return GHOSTTY_KEY_ARROW_LEFT;
        case 124: return GHOSTTY_KEY_ARROW_RIGHT; case 125: return GHOSTTY_KEY_ARROW_DOWN;
        case 126: return GHOSTTY_KEY_ARROW_UP;
        case 122: return GHOSTTY_KEY_F1; case 120: return GHOSTTY_KEY_F2;
        case 99: return GHOSTTY_KEY_F3; case 118: return GHOSTTY_KEY_F4;
        case 96: return GHOSTTY_KEY_F5; case 97: return GHOSTTY_KEY_F6;
        case 98: return GHOSTTY_KEY_F7; case 100: return GHOSTTY_KEY_F8;
        case 101: return GHOSTTY_KEY_F9; case 109: return GHOSTTY_KEY_F10;
        case 103: return GHOSTTY_KEY_F11; case 111: return GHOSTTY_KEY_F12;
        default: return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

@interface TerminalView : NSOpenGLView <NSTextInputClient> {
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
    CTFontRef fonts[4];
    GLfloat baseline;
    NSMutableDictionary *glyphs;
    NSMutableData *pending;
    NSMutableAttributedString *marked;
    NSEvent *input_event;
    NSTimer *timer;
    GLuint atlas, program, vbo;
    int atlas_x, atlas_y, atlas_row_height;
    Mesh background, foreground;
    BOOL gl_ready, blink_on, render_hold;
    NSTimeInterval next_blink, hold_deadline;
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
- (void)sendKey:(NSEvent *)event text:(NSString *)text;
- (void)capture:(NSString *)path;
- (void)finishTest:(id)sender;
- (void)requestCapture:(id)sender;
- (void)runIntegration:(id)sender;
- (void)testSelection:(id)sender;
- (void)toggleFullscreen:(id)sender;
- (void)pressFullscreenKey;
- (NSString *)screenText;
- (void)typeCommand:(NSString *)command;
- (BOOL)reportMouse:(NSEvent *)event action:(GhosttyMouseAction)action button:(GhosttyMouseButton)button;
@end

static void write_pty(GhosttyTerminal terminal, void *userdata, const uint8_t *data, size_t length)
{
    (void)terminal;
    [(TerminalView *)userdata queueBytes:data length:length];
}

static void title_changed(GhosttyTerminal terminal, void *userdata)
{
    GhosttyString title = {0};
    if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) == GHOSTTY_SUCCESS) {
        NSString *name = [[[NSString alloc] initWithBytes:title.ptr length:title.len
                                                encoding:NSUTF8StringEncoding] autorelease];
        [[(TerminalView *)userdata window] setTitle:name ? name : @"Snow Ghostty"];
    }
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
    fonts[0] = CTFontCreateWithName((CFStringRef)imac_config.font_family, imac_config.font_size, NULL);
    CFStringRef resolved_family=CTFontCopyFamilyName(fonts[0]);
    fprintf(stderr,"Resolved font: %s\n",[(NSString *)resolved_family UTF8String]);
    if (CFStringCompare(resolved_family,(CFStringRef)imac_config.font_family,kCFCompareCaseInsensitive)!=kCFCompareEqualTo) {
        fprintf(stderr,"Requested font is unavailable; using bundled FiraCode Nerd Font Mono\n");
        CFRelease(fonts[0]); fonts[0]=CTFontCreateWithName(CFSTR("FiraCode Nerd Font Mono"),imac_config.font_size,NULL);
    }
    CFRelease(resolved_family);
    for (int i = 1; i < 4; i++) {
        CTFontSymbolicTraits traits = (i & 1 ? kCTFontBoldTrait : 0) | (i & 2 ? kCTFontItalicTrait : 0);
        fonts[i] = CTFontCreateCopyWithSymbolicTraits(fonts[0], 0, NULL, traits, traits);
        if (!fonts[i]) fonts[i] = CFRetain(fonts[i==3 ? 1 : 0]);
        if ((i&2) && !(CTFontGetSymbolicTraits(fonts[i])&kCTFontItalicTrait)) {
            CGAffineTransform slant=CGAffineTransformMake(1,0,0.2,1,0,0);
            CTFontRef italic=CTFontCreateCopyWithAttributes(fonts[i],0,&slant,NULL);
            if (italic) { CFRelease(fonts[i]); fonts[i]=italic; }
        }
    }
    UniChar character = 'M'; CGGlyph glyph = 0; CGSize advance;
    CTFontGetGlyphsForCharacters(fonts[0], &character, &glyph, 1);
    CTFontGetAdvancesForGlyphs(fonts[0], kCTFontHorizontalOrientation, &glyph, &advance, 1);
    cell_width = (int)lrint(advance.width);
    cell_height = (int)ceil(CTFontGetAscent(fonts[0]) + CTFontGetDescent(fonts[0]) + CTFontGetLeading(fonts[0])) + 2;
    baseline = ceil(CTFontGetDescent(fonts[0])) + 1;
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
    core_check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &imac_config.background), "background");
    core_check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &imac_config.foreground), "foreground");
    core_check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &imac_config.cursor), "cursor color");
    GhosttyColorRgb palette[256];
    core_check(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT,palette),"default palette");
    memcpy(palette,imac_config.palette,sizeof(imac_config.palette));
    core_check(ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,palette),"Mocha palette");
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
- (BOOL)isOpaque { return YES; }
- (void)prepareOpenGL
{
    [super prepareOpenGL]; [[self openGLContext] makeCurrentContext];
    GLint accelerated = 0;
    CGLDescribePixelFormat([[self pixelFormat] CGLPixelFormatObj], 0, kCGLPFAAccelerated, &accelerated);
    fprintf(stderr, "GPU: %s; OpenGL %s; GLSL %s; accelerated=%d\n",
            glGetString(GL_RENDERER), glGetString(GL_VERSION), glGetString(GL_SHADING_LANGUAGE_VERSION), accelerated);
    if (!accelerated) { fputs("Hardware rendering unavailable\n", stderr); exit(1); }
    GLint interval = 1; [[self openGLContext] setValues:&interval forParameter:NSOpenGLCPSwapInterval];
    GLuint vs = shader(GL_VERTEX_SHADER,
        "#version 120\nattribute vec2 position; attribute vec2 texcoord; attribute vec4 color;\n"
        "uniform vec2 viewport; varying vec2 uv; varying vec4 ink;\n"
        "void main(){gl_Position=vec4(position/viewport*2.0-1.0,0.0,1.0); uv=texcoord; ink=color;}\n");
    GLuint fs = shader(GL_FRAGMENT_SHADER,
        "#version 120\nuniform sampler2D atlas; varying vec2 uv; varying vec4 ink;\n"
        "void main(){gl_FragColor=vec4(ink.rgb,ink.a*texture2D(atlas,uv).a);}\n");
    program = glCreateProgram(); glAttachShader(program, vs); glAttachShader(program, fs);
    glBindAttribLocation(program, 0, "position"); glBindAttribLocation(program, 1, "texcoord");
    glBindAttribLocation(program, 2, "color"); glLinkProgram(program);
    GLint ok = 0; glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) { char log[4096]; glGetProgramInfoLog(program, sizeof(log), NULL, log); fprintf(stderr, "GL link: %s\n", log); exit(1); }
    glDeleteShader(vs); glDeleteShader(fs);
    glGenTextures(1, &atlas); glBindTexture(GL_TEXTURE_2D, atlas);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    uint8_t *empty = calloc(ATLAS_SIZE * ATLAS_SIZE, 1);
    if (!empty) exit(1); empty[0] = 255;
    glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA8, ATLAS_SIZE, ATLAS_SIZE, 0, GL_ALPHA, GL_UNSIGNED_BYTE, empty); free(empty);
    atlas_x = 2; atlas_y = 2; atlas_row_height = 0;
    glGenBuffers(1, &vbo); gl_ready = YES;
}

- (Glyph)glyphForText:(NSString *)text style:(int)style width:(int)width
{
    NSString *cache_key = [NSString stringWithFormat:@"%d:%d:%@", style, width, text];
    NSValue *cached = [glyphs objectForKey:cache_key];
    Glyph result;
    if (cached) { [cached getValue:&result]; return result; }
    int w = width * cell_width, h = cell_height;
    if (atlas_x + w + 1 >= ATLAS_SIZE) { atlas_x = 2; atlas_y += atlas_row_height + 1; atlas_row_height = 0; }
    if (atlas_y + h + 1 >= ATLAS_SIZE) return (Glyph){0,0,0,0};
    uint8_t *bitmap = calloc((size_t)w * h, 1);
    if (!bitmap) { fputs("Out of glyph memory\n",stderr); exit(1); }
    // Block art must tile to the cell edges, including font line spacing.
    // Rasterize into the same cached GPU atlas instead of the font's ink box.
    if ([text length]!=1 || !rasterize_block([text characterAtIndex:0],bitmap,w,h)) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
        CGContextRef context = CGBitmapContextCreate(bitmap, w, h, 8, w, space, kCGImageAlphaNone);
        CGColorSpaceRelease(space);
        if (!context) { free(bitmap); return (Glyph){0,0,0,0}; }
        CGContextSetShouldAntialias(context, true);
        CGContextSetShouldSmoothFonts(context, false); // Atlas stores grayscale coverage, not LCD subpixels.
        CGContextSetGrayFillColor(context, 1, 1);
        CGContextSetTextMatrix(context, CGAffineTransformIdentity);
        CGContextSetTextPosition(context, 0, baseline);
        NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
            (id)fonts[style], (id)kCTFontAttributeName,
            [NSNumber numberWithBool:YES], (id)kCTForegroundColorFromContextAttributeName,
            [NSNumber numberWithInt:0], (id)kCTLigatureAttributeName, nil];
        NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:attributes];
        CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)string);
        CTLineDraw(line, context); CFRelease(line); [string release];
        CGContextRelease(context);
    }
    glTexSubImage2D(GL_TEXTURE_2D, 0, atlas_x, atlas_y, w, h, GL_ALPHA, GL_UNSIGNED_BYTE, bitmap);
    free(bitmap);
    result = (Glyph){atlas_x, atlas_y, w, h};
    atlas_x += w + 1; if (h > atlas_row_height) atlas_row_height = h;
    [glyphs setObject:[NSValue valueWithBytes:&result objCType:@encode(Glyph)] forKey:cache_key]; uploaded++;
    return result;
}

- (void)reshape
{
    [super reshape];
    NSRect bounds = [self bounds];
    uint16_t cols = (uint16_t)MAX(2, MIN(500, floor((bounds.size.width - PAD * 2) / cell_width)));
    uint16_t count = (uint16_t)MAX(2, MIN(250, floor((bounds.size.height - PAD * 2) / cell_height)));
    if (cols != columns || count != lines) {
        ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_SELECTION,NULL);
        selection_active=selecting=NO;
        core_check(ghostty_terminal_resize(terminal, cols, count, cell_width, cell_height), "terminal resize");
        columns = cols; lines = count;
        if (master >= 0) {
            struct winsize size = { count, cols, cols * cell_width, count * cell_height };
            if (ioctl(master, TIOCSWINSZ, &size) < 0) perror("PTY resize");
        }
        fprintf(stderr, "Resize: %u columns x %u rows\n", columns, lines);
    }
    [self setNeedsDisplay:YES];
}

- (void)drawMesh:(Mesh *)mesh
{
    if (!mesh->count) return;
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, mesh->count * sizeof(Vertex), mesh->data, GL_STREAM_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)offsetof(Vertex,x));
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)offsetof(Vertex,u));
    glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)offsetof(Vertex,r));
    glDrawArrays(GL_TRIANGLES, 0, (GLsizei)mesh->count);
}

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    NSTimeInterval draw_start=[NSDate timeIntervalSinceReferenceDate];
    if (!gl_ready) [self prepareOpenGL];
    [[self openGLContext] makeCurrentContext];
    if (!render_hold) core_check(ghostty_render_state_update(render, terminal), "render update");
    NSRect bounds = [self bounds];
    glViewport(0, 0, bounds.size.width, bounds.size.height);
    GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    GhosttyRenderStateCursor cursor = GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
    core_check(ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors), "render colors");
    core_check(ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor), "render cursor");
    glClearColor(colors.background.r / 255.0f, colors.background.g / 255.0f, colors.background.b / 255.0f, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, atlas);
    // Eviction occurs before frame construction, so all cached UVs stay valid for this draw.
    if (atlas_y + cell_height * 2 >= ATLAS_SIZE) {
        [glyphs removeAllObjects]; atlas_x = 2; atlas_y = 2; atlas_row_height = 0;
    }
    background.count = foreground.count = 0;
    core_check(ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rows), "render rows");
    int row = 0;
    float solid = 0.5f / ATLAS_SIZE;
    BOOL show_cursor = cursor.visible && cursor.viewport_has_value && (!cursor.blinking || blink_on);
    while (ghostty_render_state_row_iterator_next(rows)) {
        core_check(ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells), "render cells");
        int column = 0;
        float y = bounds.size.height - PAD - (row + 1) * cell_height;
        while (ghostty_render_state_row_cells_next(cells)) {
            GhosttyColorRgb bg = colors.background, fg = colors.foreground;
            GhosttyStyle style = {0};
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg);
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg);
            if ((style.flags & GHOSTTY_STYLE_FLAG_INVERSE)) { GhosttyColorRgb tmp = bg; bg = fg; fg = tmp; }
            bool selected=false;
            ghostty_render_state_row_cells_get(cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED,&selected);
            if (selected) { bg=imac_config.selection_background; fg=imac_config.selection_foreground; }
            BOOL block = show_cursor && cursor.visual_style == GHOSTTY_CURSOR_STYLE_BLOCK &&
                         cursor.viewport_x == column && cursor.viewport_y == row;
            if (block) { fg = imac_config.cursor_text; bg = colors.cursor_has_value ? colors.cursor : colors.foreground; }
            float x = PAD + column * cell_width;
            quad(&background, x,y,cell_width,cell_height,solid,solid,solid,solid,bg,1);
            GhosttyCell raw = 0; GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw);
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
            uint8_t bytes[128]; GhosttyBuffer buffer = {bytes,sizeof(bytes),0};
            GhosttyResult text_result = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer);
            uint8_t *large = NULL;
            if (text_result == GHOSTTY_OUT_OF_SPACE) {
                large = malloc(buffer.len); if (!large) exit(1);
                buffer.ptr = large; buffer.cap = buffer.len;
                text_result = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer);
            }
            if (text_result == GHOSTTY_SUCCESS && buffer.len && !(style.flags & GHOSTTY_STYLE_FLAG_INVISIBLE) &&
                (!(style.flags & GHOSTTY_STYLE_FLAG_BLINK) || blink_on) && wide != GHOSTTY_CELL_WIDE_SPACER_TAIL && wide != GHOSTTY_CELL_WIDE_SPACER_HEAD) {
                NSString *text = [[[NSString alloc] initWithBytes:buffer.ptr length:buffer.len encoding:NSUTF8StringEncoding] autorelease];
                Glyph glyph = [self glyphForText:text ? text : @"\ufffd" style:((style.flags & GHOSTTY_STYLE_FLAG_BOLD) ? 1 : 0) | ((style.flags & GHOSTTY_STYLE_FLAG_ITALIC) ? 2 : 0)
                                           width:wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1];
                quad(&foreground,x,y,glyph.width,glyph.height,
                     glyph.x/(float)ATLAS_SIZE,(glyph.y+glyph.height)/(float)ATLAS_SIZE,
                     (glyph.x+glyph.width)/(float)ATLAS_SIZE,glyph.y/(float)ATLAS_SIZE,fg,(style.flags & GHOSTTY_STYLE_FLAG_FAINT) ? 0.5f : 1.0f);
            }
            free(large);
            if (GHOSTTY_STYLE_UNDERLINE(style)) quad(&foreground,x,y+baseline-2,cell_width,1,solid,solid,solid,solid,fg,1);
            if ((style.flags & GHOSTTY_STYLE_FLAG_STRIKETHROUGH)) quad(&foreground,x,y+cell_height*0.5f,cell_width,1,solid,solid,solid,solid,fg,1);
            column++;
        }
        row++;
    }
    if (show_cursor && cursor.visual_style != GHOSTTY_CURSOR_STYLE_BLOCK) {
        float x = PAD + cursor.viewport_x * cell_width, y = bounds.size.height - PAD - (cursor.viewport_y+1)*cell_height;
        GhosttyColorRgb color = colors.cursor_has_value ? colors.cursor : colors.foreground;
        if (cursor.visual_style == GHOSTTY_CURSOR_STYLE_BAR)
            quad(&foreground,x,y,2,cell_height,solid,solid,solid,solid,color,1);
        else if (cursor.visual_style == GHOSTTY_CURSOR_STYLE_UNDERLINE)
            quad(&foreground,x,y,cell_width,2,solid,solid,solid,solid,color,1);
        else {
            quad(&foreground,x,y,1,cell_height,solid,solid,solid,solid,color,1);
            quad(&foreground,x+cell_width-1,y,1,cell_height,solid,solid,solid,solid,color,1);
            quad(&foreground,x,y,cell_width,1,solid,solid,solid,solid,color,1);
            quad(&foreground,x,y+cell_height-1,cell_width,1,solid,solid,solid,solid,color,1);
        }
    }
    glUseProgram(program);
    glUniform2f(glGetUniformLocation(program,"viewport"), bounds.size.width, bounds.size.height);
    glUniform1i(glGetUniformLocation(program,"atlas"),0);
    glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    for (int i=0; i<3; i++) glEnableVertexAttribArray(i);
    [self drawMesh:&background]; [self drawMesh:&foreground];
    for (int i=0; i<3; i++) glDisableVertexAttribArray(i);
    glBindBuffer(GL_ARRAY_BUFFER,0); glUseProgram(0);
    GLenum error = glGetError();
    if (error != GL_NO_ERROR) { fprintf(stderr,"GL frame error: 0x%x\n",error); test_result = 1; }
    BOOL captured_frame = capture_path != nil;
    if (capture_path) { [self capture:capture_path]; [capture_path release]; capture_path=nil; }
    [[self openGLContext] flushBuffer];
    core_check(ghostty_render_state_clean(render), "render clean"); frames++;
    double elapsed=([NSDate timeIntervalSinceReferenceDate]-draw_start)*1000;
    // PNG encoding and disk writes are validation work, not terminal drawing.
    if (!captured_frame) {
        timed_frames++;
        draw_milliseconds+=elapsed; if(elapsed>max_draw_milliseconds) max_draw_milliseconds=elapsed;
        if(frames>3) { warm_frames++; warm_draw_milliseconds+=elapsed; if(elapsed>max_warm_draw_milliseconds) max_warm_draw_milliseconds=elapsed; }
    }
}

- (void)capture:(NSString *)path
{
    NSRect bounds = [self bounds]; int width=bounds.size.width,height=bounds.size.height;
    NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width*4 bitsPerPixel:32];
    uint8_t *pixels = malloc((size_t)width*height*4); if (!image || !pixels) exit(1);
    glReadBuffer(GL_BACK); glPixelStorei(GL_PACK_ALIGNMENT,1);
    glReadPixels(0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,pixels);
    for (int y=0;y<height;y++) memcpy([image bitmapData]+y*width*4,pixels+(height-y-1)*width*4,width*4);
    // The window is opaque. Coverage compositing leaves framebuffer alpha unrelated to opacity.
    for (int i=0;i<width*height;i++) [image bitmapData][i*4+3]=255;
    NSData *png=[image representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
    if (![png writeToFile:path atomically:YES]) { fprintf(stderr,"Capture failed\n"); test_result=1; }
    else fprintf(stderr,"Captured frame: %s (%dx%d)\n",[path fileSystemRepresentation],width,height);
    free(pixels); [image release];
}

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
            // Fullscreen moves this view into a temporary Cocoa window. Closing
            // [self window] there strands the original window with white content.
            // Each process owns one session; terminate through the delegate so
            // it exits fullscreen and cleans up the view and PTY together.
            if (!self_test && !integration_test && !keep_on_exit) [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0.15];
            else if (keep_on_exit) {
                char message[96]; int length=snprintf(message,sizeof(message),"\r\n[Process exited: %d]\r\n",WIFEXITED(status) ? WEXITSTATUS(status) : -1);
                ghostty_terminal_vt_write(terminal,(const uint8_t *)message,length); [self setNeedsDisplay:YES];
            }
        }
    }
    NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
    if (render_hold && now>=hold_deadline) {
        GhosttyTerminalModeConfig mode={GHOSTTY_MODE_SYNCHRONIZED_OUTPUT,false};
        ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_MODE,&mode);
        render_hold=NO; [self setNeedsDisplay:YES];
    }
    if (now>=next_blink) { blink_on=!blink_on; next_blink=now+0.5; if (!render_hold) [self setNeedsDisplay:YES]; }
}

- (void)sendKey:(NSEvent *)event text:(NSString *)text
{
    if (selection_active) {
        ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_SELECTION,NULL);
        selection_active=selecting=NO;
    }
    GhosttyMods mods=0; NSUInteger flags=[event modifierFlags];
    if (flags&NSShiftKeyMask) mods|=GHOSTTY_MODS_SHIFT;
    if (flags&NSControlKeyMask) mods|=GHOSTTY_MODS_CTRL;
    if (flags&NSAlternateKeyMask) mods|=GHOSTTY_MODS_ALT;
    ghostty_key_event_set_action(key,[event isARepeat] ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS);
    ghostty_key_event_set_key(key,event ? physical_key([event keyCode]) : GHOSTTY_KEY_UNIDENTIFIED);
    ghostty_key_event_set_mods(key,mods);
    ghostty_key_event_set_consumed_mods(key,text && !(mods&GHOSTTY_MODS_CTRL) ? mods&(GHOSTTY_MODS_SHIFT|GHOSTTY_MODS_ALT) : 0);
    ghostty_key_event_set_composing(key,false);
    NSData *utf8=[text dataUsingEncoding:NSUTF8StringEncoding];
    core_check(ghostty_key_event_set_utf8(key,(GhosttyString){[utf8 bytes],[utf8 length]}),"keyboard text");
    NSString *unshifted=[event charactersIgnoringModifiers];
    ghostty_key_event_set_unshifted_codepoint(key,[unshifted length] ? [unshifted characterAtIndex:0] : 0);
    ghostty_key_encoder_set_from_terminal(keys,terminal);
    uint8_t bytes[4096]; size_t length=0;
    GhosttyResult result=ghostty_key_encoder_encode(keys,key,bytes,sizeof(bytes),&length);
    if (result==GHOSTTY_SUCCESS) [self queueBytes:(uint8_t *)bytes length:length];
    else NSBeep();
    GhosttyTerminalScrollViewport bottom={GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM,{0}};
    ghostty_terminal_scroll_viewport(terminal,bottom);
    blink_on=YES; next_blink=[NSDate timeIntervalSinceReferenceDate]+0.5;
    [self setNeedsDisplay:YES];
}

- (void)keyDown:(NSEvent *)event
{
    [input_event release]; input_event=[event retain];
    NSUInteger modifiers=[event modifierFlags]&NSDeviceIndependentModifierFlagsMask;
    if (([event keyCode]==36 || [event keyCode]==76) &&
        (modifiers&(NSCommandKeyMask|NSShiftKeyMask|NSControlKeyMask|NSAlternateKeyMask))==NSCommandKeyMask) {
        [self toggleFullscreen:nil]; return;
    }
    if ([event modifierFlags]&NSCommandKeyMask) { [super keyDown:event]; return; }
    unsigned short code=[event keyCode];
    if (([event modifierFlags]&NSControlKeyMask) || code==53 || code>=96) {
        [self sendKey:event text:([event modifierFlags]&NSControlKeyMask) ? [event charactersIgnoringModifiers] : nil];
    } else [self interpretKeyEvents:[NSArray arrayWithObject:event]];
}
- (void)toggleFullscreen:(id)sender
{
    (void)sender;
    if ([self isInFullScreenMode]) [self exitFullScreenModeWithOptions:nil];
    else {
        NSDictionary *options=[NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithBool:NO],NSFullScreenModeAllScreens,
            [NSNumber numberWithUnsignedInteger:NSApplicationPresentationHideDock|NSApplicationPresentationHideMenuBar],
                NSFullScreenModeApplicationPresentationOptions,nil];
        if (![self enterFullScreenMode:[[self window] screen] withOptions:options]) { NSBeep(); return; }
    }
    [[self window] makeFirstResponder:self]; [[self openGLContext] update]; [self reshape];
    fprintf(stderr,"Fullscreen: %s\n",[self isInFullScreenMode] ? "on" : "off");
}
- (void)pressFullscreenKey
{
    NSEvent *event=[NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:NSCommandKeyMask
        timestamp:0 windowNumber:[[self window] windowNumber] context:nil characters:@"\r"
        charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
    if (![[self window] performKeyEquivalent:event]) [self keyDown:event];
}
- (void)insertText:(id)value { [self insertText:value replacementRange:NSMakeRange(NSNotFound,0)]; }
- (void)insertText:(id)value replacementRange:(NSRange)range
{
    (void)range;
    NSString *text=[value isKindOfClass:[NSAttributedString class]] ? [value string] : value;
    [self unmarkText]; [self sendKey:input_event text:text];
}
- (void)doCommandBySelector:(SEL)selector { (void)selector; [self sendKey:input_event text:nil]; }
- (BOOL)hasMarkedText { return [marked length]>0; }
- (NSRange)markedRange { return [marked length] ? NSMakeRange(0,[marked length]) : NSMakeRange(NSNotFound,0); }
- (NSRange)selectedRange { return NSMakeRange([marked length],0); }
- (void)setMarkedText:(id)value selectedRange:(NSRange)selected_range replacementRange:(NSRange)range
{
    (void)selected_range; (void)range;
    NSString *text=[value isKindOfClass:[NSAttributedString class]] ? [value string] : value;
    [marked replaceCharactersInRange:NSMakeRange(0,[marked length]) withString:text];
}
- (void)unmarkText { [marked replaceCharactersInRange:NSMakeRange(0,[marked length]) withString:@""]; }
- (NSArray *)validAttributesForMarkedText { return [NSArray array]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual
{
    if (range.location==NSNotFound || range.location>[marked length]) return nil;
    range.length=MIN(range.length,[marked length]-range.location); if (actual) *actual=range;
    return [marked attributedSubstringFromRange:range];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point { (void)point; return NSNotFound; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual
{
    if (actual) *actual=range;
    uint16_t x=0,y=0;
    ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_CURSOR_X,&x);
    ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y);
    NSRect rect=NSMakeRect(PAD+x*cell_width,[self bounds].size.height-PAD-(y+1)*cell_height,cell_width,cell_height);
    rect=[self convertRect:rect toView:nil]; rect.origin=[[self window] convertBaseToScreen:rect.origin]; return rect;
}
- (void)paste:(id)sender
{
    (void)sender;
    NSString *text=[[NSPasteboard generalPasteboard] stringForType:NSStringPboardType];
    NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding]; if (!data) return;
    GhosttyTerminalModeConfig mode={GHOSTTY_MODE_BRACKETED_PASTE,false};
    ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_MODE,&mode);
    if (!ghostty_paste_is_safe([data bytes],[data length]) && !mode.value) {
        NSAlert *alert=[[[NSAlert alloc] init] autorelease];
        [alert setMessageText:@"Paste multiple lines or control characters?"];
        [alert setInformativeText:@"This may execute commands in the shell."];
        [alert addButtonWithTitle:@"Cancel"]; [alert addButtonWithTitle:@"Paste"];
        if ([alert runModal]!=NSAlertSecondButtonReturn) return;
    }
    if ([data length]>512*1024) { NSBeep(); return; }
    size_t size=[data length]*2+32,length=0; uint8_t *bytes=malloc(size); if (!bytes) return;
    NSMutableData *source=[NSMutableData dataWithData:data];
    if (ghostty_paste_encode([source mutableBytes],[source length],mode.value,bytes,size,&length)==GHOSTTY_SUCCESS)
        [self queueBytes:(uint8_t *)bytes length:length];
    free(bytes);
}
- (void)scrollWheel:(NSEvent *)event
{
    if (![event deltaY]) return;
    if ([self reportMouse:event action:GHOSTTY_MOUSE_ACTION_PRESS
                    button:[event deltaY]>0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE]) return;
    GhosttyTerminalScrollViewport delta={GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA,{0}};
    delta.value.delta=(intptr_t)-round([event deltaY]*3);
    ghostty_terminal_scroll_viewport(terminal,delta); [self setNeedsDisplay:YES];
}
- (BOOL)reportMouse:(NSEvent *)event action:(GhosttyMouseAction)action button:(GhosttyMouseButton)button
{
    if ([event modifierFlags]&NSShiftKeyMask) return NO;
    NSPoint point=[self convertPoint:[event locationInWindow] fromView:nil];
    GhosttyMousePosition position={point.x,[self bounds].size.height-point.y};
    GhosttyMouseEncoderSize size=GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
    size.screen_width=[self bounds].size.width; size.screen_height=[self bounds].size.height;
    size.cell_width=cell_width; size.cell_height=cell_height;
    size.padding_left=size.padding_top=PAD;
    size.padding_right=size.screen_width-PAD-columns*cell_width;
    size.padding_bottom=size.screen_height-PAD-lines*cell_height;
    ghostty_mouse_encoder_set_from_terminal(mouse,terminal);
    ghostty_mouse_encoder_set(mouse,GHOSTTY_MOUSE_ENCODER_OPT_SIZE,&size);
    ghostty_mouse_event_set_action(mouse_event,action); ghostty_mouse_event_set_button(mouse_event,button);
    ghostty_mouse_event_set_position(mouse_event,position);
    GhosttyMods mods=0;
    if ([event modifierFlags]&NSControlKeyMask) mods|=GHOSTTY_MODS_CTRL;
    if ([event modifierFlags]&NSAlternateKeyMask) mods|=GHOSTTY_MODS_ALT;
    ghostty_mouse_event_set_mods(mouse_event,mods);
    uint8_t bytes[128]; size_t length=0;
    if (ghostty_mouse_encoder_encode(mouse,mouse_event,bytes,sizeof(bytes),&length)!=GHOSTTY_SUCCESS || !length) return NO;
    [self queueBytes:(uint8_t *)bytes length:length]; return YES;
}
- (BOOL)gridRefForEvent:(NSEvent *)event result:(GhosttyGridRef *)result
{
    NSPoint point=[self convertPoint:[event locationInWindow] fromView:nil];
    GhosttyPoint position={GHOSTTY_POINT_TAG_VIEWPORT,{0}};
    position.value.coordinate.x=MAX(0,MIN(columns-1,floor((point.x-PAD)/cell_width)));
    position.value.coordinate.y=MAX(0,MIN(lines-1,floor(([self bounds].size.height-point.y-PAD)/cell_height)));
    return ghostty_terminal_grid_ref(terminal,position,result)==GHOSTTY_SUCCESS;
}
- (void)mouseDown:(NSEvent *)event
{
    [[self window] makeFirstResponder:self];
    if ([self reportMouse:event action:GHOSTTY_MOUSE_ACTION_PRESS button:GHOSTTY_MOUSE_BUTTON_LEFT]) return;
    selection=(GhosttySelection){0};
    if (![self gridRefForEvent:event result:&selection.start]) return;
    selection.end=selection.start; selection.rectangle=([event modifierFlags]&NSAlternateKeyMask)!=0;
    if ([event clickCount]>=3) {
        GhosttyTerminalSelectLineOptions options=GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
        options.ref=selection.start;
        if (ghostty_terminal_select_line(terminal,&options,&selection)!=GHOSTTY_SUCCESS) return;
    } else if ([event clickCount]==2) {
        GhosttyTerminalSelectWordOptions options=GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions);
        options.ref=selection.start;
        if (ghostty_terminal_select_word(terminal,&options,&selection)!=GHOSTTY_SUCCESS) return;
    }
    selection_active=selecting=YES;
    ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_SELECTION,&selection); [self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)event
{
    if ([self reportMouse:event action:GHOSTTY_MOUSE_ACTION_MOTION button:GHOSTTY_MOUSE_BUTTON_LEFT]) return;
    if (!selecting || ![self gridRefForEvent:event result:&selection.end]) return;
    ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_SELECTION,&selection); [self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent *)event
{
    [self reportMouse:event action:GHOSTTY_MOUSE_ACTION_RELEASE button:GHOSTTY_MOUSE_BUTTON_LEFT]; selecting=NO;
}
- (void)rightMouseDown:(NSEvent *)event { [self reportMouse:event action:GHOSTTY_MOUSE_ACTION_PRESS button:GHOSTTY_MOUSE_BUTTON_RIGHT]; }
- (void)rightMouseUp:(NSEvent *)event { [self reportMouse:event action:GHOSTTY_MOUSE_ACTION_RELEASE button:GHOSTTY_MOUSE_BUTTON_RIGHT]; }
- (void)copy:(id)sender
{
    (void)sender; if (!selection_active) return;
    GhosttyFormatter formatter=NULL; bool unwrap=true;
    if (ghostty_formatter_terminal_new(NULL,&formatter,terminal)!=GHOSTTY_SUCCESS) return;
    if (ghostty_formatter_set(formatter,GHOSTTY_FORMATTER_OPT_SELECTION,&selection)!=GHOSTTY_SUCCESS ||
        ghostty_formatter_set(formatter,GHOSTTY_FORMATTER_OPT_UNWRAP,&unwrap)!=GHOSTTY_SUCCESS) {
        ghostty_formatter_free(formatter); return;
    }
    uint8_t *bytes=NULL; size_t length=0;
    GhosttyResult result=ghostty_formatter_format_alloc(formatter,NULL,&bytes,&length);
    ghostty_formatter_free(formatter);
    if (result!=GHOSTTY_SUCCESS) return;
    NSString *text=[[[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding] autorelease];
    if (text) {
        NSPasteboard *board=[NSPasteboard generalPasteboard];
        [board declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil]; [board setString:text forType:NSStringPboardType];
    }
    ghostty_free(NULL,bytes,length);
}
- (void)finishTest:(id)sender
{
    (void)sender;
    fprintf(stderr,"Rendered frames: %lu; rasterized glyphs: %lu; cached glyphs: %lu\n",frames,uploaded,(unsigned long)[glyphs count]);
    fprintf(stderr,"Frame wall time including swap (excluding PNG frames): mean %.2f ms; maximum %.2f ms\n",timed_frames ? draw_milliseconds/timed_frames : 0,max_draw_milliseconds);
    fprintf(stderr,"After first three frames (%lu samples): mean %.2f ms; maximum %.2f ms\n",warm_frames,warm_frames ? warm_draw_milliseconds/warm_frames : 0,max_warm_draw_milliseconds);
    if (!frames || !uploaded) test_result=1;
    [NSApp terminate:nil];
}
- (void)requestCapture:(id)sender
{
    (void)sender;
    capture_path = [requested_capture copy];
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
        fprintf(stderr,"Cocoa double-click / word selection formatting: FAIL\n"); test_result=1;
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
            if (![self isInFullScreenMode] || !NSEqualSizes([self bounds].size,[[[self window] screen] frame].size)) {
                fprintf(stderr,"Command-Enter fullscreen geometry: FAIL\n"); test_result=1; [self finishTest:nil]; return;
            }
            [self typeCommand:@"printf 'FULLSCREEN:'; stty size\n"]; test_stage=11;
            break;
        case 11: {
            NSString *expected=[NSString stringWithFormat:@"\nFULLSCREEN:%u %u\n",lines,columns];
            ready=[text rangeOfString:expected].location!=NSNotFound;
            if (ready) {
                fprintf(stderr,"Command-Enter fullscreen / PTY size: PASS (%u x %u)\n",columns,lines);
                if (requested_capture) {
                    capture_path=[[[requested_capture stringByDeletingPathExtension] stringByAppendingString:@"-fullscreen.png"] copy];
                    [self display];
                }
                [self pressFullscreenKey]; test_stage=12;
            }
            break;
        }
        case 12:
            if ([self isInFullScreenMode] || !NSEqualRects([[self window] frame],test_window_frame)) {
                fprintf(stderr,"Command-Enter restored window: FAIL\n"); test_result=1; [self finishTest:nil]; return;
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
                if(history<1000) { fprintf(stderr,"Scrollback retention: FAIL (%lu)\n",(unsigned long)history); test_result=1; }
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
                if (requested_capture) { [self requestCapture:nil]; [self display]; }
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
        test_result=1;
        if (requested_capture) { [self requestCapture:nil]; [self display]; }
        [self finishTest:nil]; return;
    }
    [self performSelector:@selector(runIntegration:) withObject:nil afterDelay:0.4];
}
- (void)dealloc
{
    [timer invalidate]; [timer release];
    if (master>=0) close(master);
    if (child>0) { kill(child,SIGHUP); waitpid(child,NULL,WNOHANG); }
    ghostty_key_event_free(key); ghostty_key_encoder_free(keys);
    ghostty_mouse_event_free(mouse_event); ghostty_mouse_encoder_free(mouse);
    ghostty_render_state_row_cells_free(cells); ghostty_render_state_row_iterator_free(rows);
    ghostty_render_state_free(render); ghostty_terminal_free(terminal);
    [[self openGLContext] makeCurrentContext];
    if (vbo) glDeleteBuffers(1,&vbo); if (atlas) glDeleteTextures(1,&atlas); if (program) glDeleteProgram(program);
    for (int i=0;i<4;i++) CFRelease(fonts[i]);
    free(background.data); free(foreground.data);
    [glyphs release]; [pending release]; [marked release]; [input_event release];
    [super dealloc];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate,NSWindowDelegate> {
    NSWindow *window;
    TerminalView *view;
    int fd; pid_t pid;
    BOOL routed_launch;
    BOOL finished_launch;
}
- (id)initWithFD:(int)master child:(pid_t)child;
- (void)createWindow:(id)sender;
- (BOOL)launchArguments:(NSArray *)arguments error:(NSString **)error;
- (void)handleURL:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply;
- (void)openTerminalHere:(NSPasteboard *)pasteboard userData:(NSString *)data error:(NSString **)error;
- (void)makeDefaultTerminal:(id)sender;
- (void)newWindow:(id)sender;
@end
@implementation AppDelegate
- (id)initWithFD:(int)master child:(pid_t)child { self=[super init]; if(self){fd=master;pid=child;} return self; }
- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    (void)note;
    finished_launch=YES;
    [NSApp setServicesProvider:self];
    [self performSelector:@selector(createWindow:) withObject:nil afterDelay:0.2];
}
- (BOOL)launchArguments:(NSArray *)arguments error:(NSString **)error
{
    if (!arguments) return NO;
    NSTask *task=[[[NSTask alloc] init] autorelease];
    [task setLaunchPath:[[NSBundle mainBundle] executablePath]]; [task setArguments:arguments];
    @try { [task launch]; }
    @catch(NSException *exception) { if(error)*error=[exception reason]; return NO; }
    if (!window) routed_launch=YES;
    return YES;
}
- (BOOL)application:(NSApplication *)app openFile:(NSString *)path
{
    (void)app; NSString *error=nil;
    // AppKit treats option values in argv as documents once a document type
    // is declared. Our CLI has already consumed those values before run.
    if (!finished_launch && explicit_cli) return YES;
    BOOL ok=[self launchArguments:snow_file_arguments(path,NO,&error) error:&error];
    if(!ok) { NSAlert *alert=[[[NSAlert alloc] init] autorelease]; [alert setMessageText:error ? error : @"Could not open this file."]; [alert runModal]; }
    return ok;
}
- (void)handleURL:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply
{
    (void)reply; NSString *text=[[event paramDescriptorForKeyword:keyDirectObject] stringValue], *error=nil;
    if (!snow_ssh_arguments(text,&error) || ![self launchArguments:[NSArray arrayWithObjects:@"--ssh",text,nil] error:&error]) {
        NSAlert *alert=[[[NSAlert alloc] init] autorelease]; [alert setMessageText:error ? error : @"Could not open SSH URL."]; [alert runModal];
    }
}
- (void)openTerminalHere:(NSPasteboard *)pasteboard userData:(NSString *)data error:(NSString **)error
{
    (void)data;
    NSArray *paths=[pasteboard propertyListForType:NSFilenamesPboardType];
    if (![paths count]) {
        NSString *path=[pasteboard stringForType:NSStringPboardType];
        if (path) paths=[NSArray arrayWithObject:path];
    }
    if (![paths count]) { if(error)*error=@"Select a folder or file in Finder."; return; }
    for (NSString *path in paths) if (![self launchArguments:snow_file_arguments(path,YES,error) error:error]) return;
}
- (void)makeDefaultTerminal:(id)sender
{
    (void)sender; NSString *error=nil;
    BOOL ok=snow_make_default(&error);
    NSAlert *alert=[[[NSAlert alloc] init] autorelease];
    [alert setMessageText:ok ? @"Snow Ghostty opens .command files and SSH links by default." : error]; [alert runModal];
}
- (void)newWindow:(id)sender
{
    (void)sender; NSString *error=nil;
    NSArray *arguments=startup_config_path ? [NSArray arrayWithObjects:@"--config",startup_config_path,nil] : [NSArray array];
    if (![self launchArguments:arguments error:&error]) {
        NSAlert *alert=[[[NSAlert alloc] init] autorelease];
        [alert setMessageText:error ? error : @"Could not open a new window."]; [alert runModal];
    }
}
- (void)createWindow:(id)sender
{
    (void)sender;
    if (routed_launch) { [NSApp terminate:nil]; return; }
    NSMenu *menu=[[[NSMenu alloc] initWithTitle:@"Main"] autorelease];
    NSMenuItem *app=[[[NSMenuItem alloc] initWithTitle:@"Snow Ghostty" action:NULL keyEquivalent:@""] autorelease];
    NSMenu *appmenu=[[[NSMenu alloc] initWithTitle:@"Snow Ghostty"] autorelease];
    [appmenu addItemWithTitle:@"Set as Default Terminal" action:@selector(makeDefaultTerminal:) keyEquivalent:@""];
    NSMenu *services=[[[NSMenu alloc] initWithTitle:@"Services"] autorelease];
    NSMenuItem *services_item=[[[NSMenuItem alloc] initWithTitle:@"Services" action:NULL keyEquivalent:@""] autorelease];
    [services_item setSubmenu:services]; [appmenu addItem:services_item]; [NSApp setServicesMenu:services];
    [appmenu addItemWithTitle:@"Quit Snow Ghostty" action:@selector(terminate:) keyEquivalent:@"q"];
    [app setSubmenu:appmenu]; [menu addItem:app];
    NSMenuItem *filemenuitem=[[[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""] autorelease];
    NSMenu *filemenu=[[[NSMenu alloc] initWithTitle:@"File"] autorelease];
    NSMenuItem *newwindow=[filemenu addItemWithTitle:@"New Window" action:@selector(newWindow:) keyEquivalent:@"n"];
    [newwindow setTarget:self]; [newwindow setKeyEquivalentModifierMask:NSCommandKeyMask];
    [filemenuitem setSubmenu:filemenu]; [menu addItem:filemenuitem];
    NSMenuItem *edit=[[[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""] autorelease];
    NSMenu *editmenu=[[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
    [editmenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editmenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit setSubmenu:editmenu]; [menu addItem:edit]; [NSApp setMainMenu:menu];
    NSMenuItem *display=[[[NSMenuItem alloc] initWithTitle:@"View" action:NULL keyEquivalent:@""] autorelease];
    NSMenu *displaymenu=[[[NSMenu alloc] initWithTitle:@"View"] autorelease];
    [displaymenu addItemWithTitle:@"Toggle Fullscreen" action:@selector(toggleFullscreen:) keyEquivalent:@"\r"];
    [display setSubmenu:displaymenu]; [menu addItem:display];
    window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,916,616)
        styleMask:NSTitledWindowMask|NSClosableWindowMask|NSMiniaturizableWindowMask|NSResizableWindowMask
        backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"Snow Ghostty"]; [window setReleasedWhenClosed:NO]; [window setDelegate:self];
    [window setMinSize:NSMakeSize(320,200)];
    view=[[TerminalView alloc] initWithFrame:[[window contentView] bounds] fd:fd child:pid];
    [view setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable]; [window setContentView:view];
    [window center]; [window makeKeyAndOrderFront:nil]; [window makeFirstResponder:view];
    [NSApp activateIgnoringOtherApps:YES];
    if (self_test) {
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
        ghostty_terminal_vt_write(view->terminal,(const uint8_t *)fixture,strlen(fixture));
        [view setNeedsDisplay:YES];
        [view performSelector:@selector(testSelection:) withObject:nil afterDelay:0.25];
        if (requested_capture) [view performSelector:@selector(requestCapture:) withObject:nil afterDelay:0.5];
        [view performSelector:@selector(finishTest:) withObject:nil afterDelay:2.0];
    } else if (integration_test) {
        view->test_deadline=[NSDate timeIntervalSinceReferenceDate]+8;
        [view performSelector:@selector(runIntegration:) withObject:nil afterDelay:0.5];
    } else if (requested_capture) [view performSelector:@selector(requestCapture:) withObject:nil afterDelay:2];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { (void)app; return YES; }
- (void)applicationWillTerminate:(NSNotification *)note
{
    (void)note;
    if ([view isInFullScreenMode]) [view exitFullScreenModeWithOptions:nil];
    // NSTimer retains its target, so break that ownership before releasing the view.
    if (view) { [view->timer invalidate]; [view release]; view=nil; }
    else { if(fd>=0) close(fd); if(pid>0) kill(pid,SIGHUP); }
    // Cocoa's terminate: exits without returning from run on Snow Leopard.
    if (self_test || integration_test) exit(test_result);
}
- (void)dealloc { [window release]; [super dealloc]; }
@end

int main(int argc,char **argv)
{
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    const char *command=NULL; NSString *config_path=nil, *directory=nil, *file=nil, *ssh_url=nil;
    BOOL make_default=NO;
    for (int i=1;i<argc;i++) {
        if (!strncmp(argv[i],"--",2)) explicit_cli=YES;
        if (!strcmp(argv[i],"--self-test")) self_test=YES;
        else if (!strncmp(argv[i],"-psn_",5)) continue; // Snow Leopard Launch Services argument.
        else if (!strcmp(argv[i],"--integration-test")) { integration_test=YES; command="exec /bin/sh -i"; }
        else if (!strcmp(argv[i],"--capture") && i+1<argc) requested_capture=[[NSString alloc] initWithUTF8String:argv[++i]];
        else if (!strcmp(argv[i],"--command") && i+1<argc) command=argv[++i];
        else if (!strcmp(argv[i],"--config") && i+1<argc) config_path=[NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(argv[i],"--working-directory") && i+1<argc) directory=[NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(argv[i],"--execute-file") && i+1<argc) { file=[NSString stringWithUTF8String:argv[++i]]; keep_on_exit=YES; }
        else if (!strcmp(argv[i],"--ssh") && i+1<argc) { ssh_url=[NSString stringWithUTF8String:argv[++i]]; keep_on_exit=YES; }
        else if (!strcmp(argv[i],"--make-default")) make_default=YES;
        else if (!strcmp(argv[i],"--version")) {
            printf("Snow Ghostty 0.2.0 (libghostty-vt %s)\n",ghostty_version());
            [pool drain]; return 0;
        }
        else if (!strcmp(argv[i],"--help")) {
            puts("Snow Ghostty: one-window Snow Leopard terminal\nUsage: snow-ghostty [--config PATH] [--working-directory DIR] [--capture PNG]\n       snow-ghostty --command COMMAND|--execute-file FILE|--ssh URL\n       snow-ghostty --make-default\n       snow-ghostty --self-test|--integration-test [--config PATH] [--capture PNG]");
            [pool drain]; return 0;
        } else { fputs("Unknown option; use --help\n",stderr); [pool drain]; return 2; }
    }
    if (self_test && integration_test) { fputs("Choose one test mode\n",stderr); [pool drain]; return 2; }
    NSString *error=nil;
    if (make_default) { [NSApplication sharedApplication]; BOOL ok=snow_make_default(&error); if(!ok) fprintf(stderr,"%s\n",[error UTF8String]); [pool drain]; return ok ? 0 : 1; }
    if ((file && ssh_url) || ((file || ssh_url) && (command || self_test))) { fputs("Choose one session command\n",stderr); [pool drain]; return 2; }
    NSArray *ssh_arguments=ssh_url ? snow_ssh_arguments(ssh_url,&error) : nil;
    if (ssh_url && !ssh_arguments) { fprintf(stderr,"%s\n",[error UTF8String]); [pool drain]; return 2; }
    if (file) {
        NSArray *args=snow_file_arguments(file,NO,&error);
        if (!args || ![[args objectAtIndex:0] isEqualToString:@"--execute-file"]) { fprintf(stderr,"%s\n",[error ? error : @"Expected an executable .command file." UTF8String]); [pool drain]; return 2; }
        file=[args objectAtIndex:1]; if(!directory) directory=[file stringByDeletingLastPathComponent];
    }
    if (directory) {
        NSArray *args=snow_file_arguments(directory,YES,&error); BOOL is_directory=NO;
        [[NSFileManager defaultManager] fileExistsAtPath:[directory stringByExpandingTildeInPath] isDirectory:&is_directory];
        if (!args || !is_directory) { fputs("Working directory must be an existing folder\n",stderr); [pool drain]; return 2; }
        directory=[args objectAtIndex:1];
    }
    if (!imac_config_load(config_path)) { [pool drain]; return 2; }
    startup_config_path=[config_path copy];
    signal(SIGPIPE,SIG_IGN); imac_core_init();
    int master=-1; pid_t child=0;
    const char *cwd=directory ? [directory fileSystemRepresentation] : getenv("HOME");
    const char *script=file ? [file fileSystemRepresentation] : NULL;
    char **ssh_argv=NULL;
    if (ssh_arguments) {
        ssh_argv=calloc([ssh_arguments count]+1,sizeof(char *)); if(!ssh_argv) return 1;
        for(NSUInteger i=0;i<[ssh_arguments count];i++) ssh_argv[i]=strdup([[ssh_arguments objectAtIndex:i] UTF8String]);
    }
    if (!self_test) {
        struct winsize size={30,100,900,600};
        child=forkpty(&master,NULL,NULL,&size);
        if (child<0) { perror("forkpty"); return 1; }
        if (!child) {
            setenv("TERM","xterm-256color",1); setenv("COLORTERM","truecolor",1);
            if(cwd && chdir(cwd)<0) { perror("working directory"); _exit(127); }
            if(script) execl(script,script,(char *)NULL);
            else if(ssh_argv) execv("/usr/bin/ssh",ssh_argv);
            else if (command) execl("/bin/sh","sh","-c",command,(char *)NULL);
            else {
                struct passwd *account=getpwuid(getuid());
                const char *shell=account ? account->pw_shell : NULL;
                if(!shell || shell[0]!='/') shell=getenv("SHELL");
                if(!shell || shell[0]!='/') shell="/bin/bash";
                setenv("SHELL",shell,1);
                execl(shell,shell,"-l",(char *)NULL);
            }
            perror("exec shell"); _exit(127);
        }
        int flags=fcntl(master,F_GETFL,0);
        if (flags<0 || fcntl(master,F_SETFL,flags|O_NONBLOCK)<0) { perror("PTY nonblocking"); return 1; }
        fcntl(master,F_SETFD,FD_CLOEXEC);
    }
    if (!imac_register_fonts()) { if(master>=0) close(master); if(child>0) kill(child,SIGHUP); [pool drain]; return 1; }
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    AppDelegate *delegate=[[AppDelegate alloc] initWithFD:master child:child];
    [[NSAppleEventManager sharedAppleEventManager] setEventHandler:delegate andSelector:@selector(handleURL:reply:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
    [NSApp setDelegate:delegate]; [NSApp run];
    [delegate release]; [pool drain]; return test_result;
}
