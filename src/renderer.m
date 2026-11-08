#import "terminal.h"
#import "application.h"
#import "config.h"
#include <OpenGL/OpenGL.h>
#include <OpenGL/glext.h>
#include <math.h>
#include <sys/ioctl.h>

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

@implementation TerminalView (Rendering)
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
    if (cols != columns || count != lines || terminal_cell_width!=cell_width || terminal_cell_height!=cell_height) {
        ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_SELECTION,NULL);
        selection_active=selecting=NO;
        core_check(ghostty_terminal_resize(terminal, cols, count, cell_width, cell_height), "terminal resize");
        columns = cols; lines = count;
        terminal_cell_width=cell_width; terminal_cell_height=cell_height;
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
    if (error != GL_NO_ERROR) { fprintf(stderr,"GL frame error: 0x%x\n",error); snow_app.test_result = 1; }
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
    if (![png writeToFile:path atomically:YES]) { fprintf(stderr,"Capture failed\n"); snow_app.test_result=1; }
    else fprintf(stderr,"Captured frame: %s (%dx%d)\n",[path fileSystemRepresentation],width,height);
    free(pixels); [image release];
}

@end
