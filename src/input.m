#import "terminal.h"
#include <math.h>

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

static GhosttyKey navigation_key(NSEvent *event)
{
    NSString *text=[event charactersIgnoringModifiers];
    if ([text length]) switch ([text characterAtIndex:0]) {
        case NSHomeFunctionKey: return GHOSTTY_KEY_HOME;
        case NSEndFunctionKey: return GHOSTTY_KEY_END;
        case NSPageUpFunctionKey: return GHOSTTY_KEY_PAGE_UP;
        case NSPageDownFunctionKey: return GHOSTTY_KEY_PAGE_DOWN;
    }
    GhosttyKey key=physical_key([event keyCode]);
    return key==GHOSTTY_KEY_HOME || key==GHOSTTY_KEY_END || key==GHOSTTY_KEY_PAGE_UP || key==GHOSTTY_KEY_PAGE_DOWN ? key : GHOSTTY_KEY_UNIDENTIFIED;
}

@implementation TerminalView (Input)
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
    GhosttyKey navigation=event ? navigation_key(event) : GHOSTTY_KEY_UNIDENTIFIED;
    ghostty_key_event_set_key(key,navigation!=GHOSTTY_KEY_UNIDENTIFIED ? navigation : (event ? physical_key([event keyCode]) : GHOSTTY_KEY_UNIDENTIFIED));
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

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    NSUInteger modifiers=[event modifierFlags]&(NSCommandKeyMask|NSControlKeyMask|NSAlternateKeyMask|NSShiftKeyMask);
    NSString *text=[event charactersIgnoringModifiers];
    if ([[self window] firstResponder]==self && [NSApp keyWindow]==[self window] &&
        (modifiers==NSCommandKeyMask || modifiers==(NSCommandKeyMask|NSShiftKeyMask)) &&
        ([text isEqualToString:@"+"] || [text isEqualToString:@"="])) {
        [self increaseFontSize:nil]; return YES;
    }
    return [super performKeyEquivalent:event];
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
    GhosttyKey navigation=navigation_key(event);
    if (navigation!=GHOSTTY_KEY_UNIDENTIFIED) {
        if ((modifiers&(NSCommandKeyMask|NSControlKeyMask|NSAlternateKeyMask|NSShiftKeyMask))==NSShiftKeyMask) {
            [self scrollHistoryForKey:navigation]; return;
        }
        [self sendKey:event text:nil]; return;
    }
    unsigned short code=[event keyCode];
    if (([event modifierFlags]&NSControlKeyMask) || code==53 || code>=96) {
        [self sendKey:event text:([event modifierFlags]&NSControlKeyMask) ? [event charactersIgnoringModifiers] : nil];
    } else [self interpretKeyEvents:[NSArray arrayWithObject:event]];
}
- (void)toggleFullscreen:(id)sender
{
    (void)sender;
    if ([tab_host isInFullScreenMode]) [tab_host exitFullScreenModeWithOptions:nil];
    else {
        NSDictionary *options=[NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithBool:NO],NSFullScreenModeAllScreens,
            [NSNumber numberWithUnsignedInteger:NSApplicationPresentationHideDock|NSApplicationPresentationHideMenuBar],
                NSFullScreenModeApplicationPresentationOptions,nil];
        if (![tab_host enterFullScreenMode:[[self window] screen] withOptions:options]) { NSBeep(); return; }
    }
    [[self window] makeFirstResponder:self]; [[self openGLContext] update]; [self reshape];
    [[tab_host window] setTitle:[[tab_host selectedTabViewItem] label]];
    fprintf(stderr,"Fullscreen: %s\n",[self isTerminalFullscreen] ? "on" : "off");
}
- (BOOL)isTerminalFullscreen { return [tab_host isInFullScreenMode]; }
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
- (void)selectAll:(id)sender
{
    (void)sender;
    selection_active=ghostty_terminal_select_all(terminal,&selection)==GHOSTTY_SUCCESS &&
        ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_SELECTION,&selection)==GHOSTTY_SUCCESS;
    selecting=NO; [self setNeedsDisplay:YES];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if ([item action]==@selector(increaseFontSize:)) return font_size<72;
    if ([item action]==@selector(decreaseFontSize:)) return font_size>6;
    if ([item action]==@selector(copy:)) return selection_active;
    if ([item action]==@selector(paste:)) return master>=0 &&
        [[NSPasteboard generalPasteboard] availableTypeFromArray:[NSArray arrayWithObject:NSStringPboardType]]!=nil;
    if ([item action]==@selector(toggleFullscreen:)) {
        [item setTitle:[self isTerminalFullscreen] ? @"Exit Fullscreen" : @"Enter Fullscreen"];
    }
    return YES;
}
@end
