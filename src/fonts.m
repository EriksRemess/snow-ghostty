#import "terminal.h"
#import "config.h"
#include <math.h>

@implementation TerminalView (Fonts)
- (void)setFontSize:(CGFloat)size
{
    size=MAX(6,MIN(72,size));
    if (!isfinite(size) || (fonts[0] && size==font_size && [configured_font_family isEqualToString:imac_config.font_family])) return;
    [configured_font_family release]; configured_font_family=[imac_config.font_family copy];
    for (int i=0;i<4;i++) { if(fonts[i])CFRelease(fonts[i]); fonts[i]=NULL; }
    font_size=size;
    fonts[0] = CTFontCreateWithName((CFStringRef)imac_config.font_family, size, NULL);
    CFStringRef resolved_family=CTFontCopyFamilyName(fonts[0]);
    fprintf(stderr,"Resolved font: %s\n",[(NSString *)resolved_family UTF8String]);
    if (CFStringCompare(resolved_family,(CFStringRef)imac_config.font_family,kCFCompareCaseInsensitive)!=kCFCompareEqualTo) {
        fprintf(stderr,"Requested font is unavailable; using bundled FiraCode Nerd Font Mono\n");
        CFRelease(fonts[0]); fonts[0]=CTFontCreateWithName(CFSTR("FiraCode Nerd Font Mono"),size,NULL);
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
    [glyphs removeAllObjects]; atlas_x=2; atlas_y=2; atlas_row_height=0;
    if (terminal) { [self reshape]; [self setNeedsDisplay:YES]; }
}
- (void)increaseFontSize:(id)sender { (void)sender; [self setFontSize:font_size+1]; }
- (void)decreaseFontSize:(id)sender { (void)sender; [self setFontSize:font_size-1]; }
- (void)resetFontSize:(id)sender { (void)sender; [self setFontSize:imac_config.font_size]; }
@end
