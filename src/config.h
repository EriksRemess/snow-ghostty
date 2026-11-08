#import <Cocoa/Cocoa.h>
#include <ghostty/vt.h>

typedef struct {
    NSString *font_family;
    CGFloat font_size;
    GhosttyColorRgb background, foreground, cursor, cursor_text;
    GhosttyColorRgb selection_background, selection_foreground;
    GhosttyColorRgb palette[16];
} ImacConfig;

extern ImacConfig imac_config;
BOOL imac_config_load(NSString *explicit_path);
NSString *imac_config_path(void);
NSString *imac_config_error(void);
BOOL imac_config_reload(void);
BOOL imac_register_fonts(void);
