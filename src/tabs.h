#import <Cocoa/Cocoa.h>

enum { SnowTabStripHeight = 23 };

// Snow Leopard has no NSWindow tabbing API. Keep native NSTabView session
// management with a compact Terminal-style strip made of Cocoa controls.
@interface SnowTabView : NSTabView {
    NSView *strip;
    NSMutableArray *tab_buttons;
}
- (void)refreshTabLabels;
@end
