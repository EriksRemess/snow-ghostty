#import "tabs.h"

@protocol SnowTabActions <NSTabViewDelegate>
- (void)closeTabItem:(NSTabViewItem *)item;
@end

static NSColor *gray(CGFloat value)
{
    // Device RGB avoids the calibrated-gray gamma conversion on 10.6.
    return [NSColor colorWithDeviceRed:value/255 green:value/255 blue:value/255 alpha:1];
}

@interface SnowTabStrip : NSView
@end
@implementation SnowTabStrip
- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    NSRect rect=[self bounds];
    [gray(139) set]; NSRectFill(rect);
    [gray(180) set]; NSRectFill(NSMakeRect(0,rect.size.height-1,rect.size.width,1));
    [gray(81) set]; NSRectFill(NSMakeRect(0,rect.size.height-2,rect.size.width,1));
    NSRectFill(NSMakeRect(0,0,rect.size.width,1));
    [gray(156) set]; NSRectFill(NSMakeRect(0,1,rect.size.width,1));
}
@end

@interface SnowTabCloseButton : NSButton
@end
@implementation SnowTabCloseButton
- (BOOL)isOpaque { return NO; }
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    NSRect circle=NSInsetRect([self bounds],0.75,0.75);
    [gray(181) set]; [[NSBezierPath bezierPathWithOvalInRect:NSOffsetRect(circle,0,-0.5)] fill];
    [gray([[self cell] isHighlighted] ? 65 : 97) set]; [[NSBezierPath bezierPathWithOvalInRect:circle] fill];
    [gray(75) set]; [[NSBezierPath bezierPathWithOvalInRect:circle] stroke];
    NSBezierPath *cross=[NSBezierPath bezierPath]; [cross setLineWidth:1.5];
    [cross moveToPoint:NSMakePoint(4.25,4.25)]; [cross lineToPoint:NSMakePoint(8.75,8.75)];
    [cross moveToPoint:NSMakePoint(4.25,8.75)]; [cross lineToPoint:NSMakePoint(8.75,4.25)];
    [gray([[self cell] isHighlighted] ? 255 : 211) set]; [cross stroke];
}
@end

@interface SnowTabButton : NSButton {
    NSTabViewItem *tab;
}
- (id)initWithTab:(NSTabViewItem *)item;
@end
@implementation SnowTabButton
- (BOOL)isOpaque { return NO; }
- (BOOL)isFlipped { return NO; }
- (id)initWithTab:(NSTabViewItem *)item
{
    self=[super initWithFrame:NSZeroRect];
    if (self) { tab=[item retain]; [self setButtonType:NSMomentaryPushInButton]; [self setBordered:NO]; }
    return self;
}
- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    BOOL selected=[[tab tabView] selectedTabViewItem]==tab;
    CGFloat width=[self bounds].size.width, height=[self bounds].size.height;
    if (selected) {
        NSBezierPath *path=[NSBezierPath bezierPath];
        [path moveToPoint:NSMakePoint(0.5,height)]; [path lineToPoint:NSMakePoint(0.5,4.5)];
        [path curveToPoint:NSMakePoint(2.5,2.5) controlPoint1:NSMakePoint(0.5,2.5) controlPoint2:NSMakePoint(0.5,2.5)];
        [path lineToPoint:NSMakePoint(width-2.5,2.5)];
        [path curveToPoint:NSMakePoint(width-0.5,4.5) controlPoint1:NSMakePoint(width-0.5,2.5) controlPoint2:NSMakePoint(width-0.5,2.5)];
        [path lineToPoint:NSMakePoint(width-0.5,height)];
        [gray(167) set]; [path fill]; [gray(81) set]; [path stroke];
        [gray(180) set]; NSRectFill(NSMakeRect(2,3,width-4,1));
    }
    NSMutableParagraphStyle *paragraph=[[[NSMutableParagraphStyle alloc] init] autorelease];
    [paragraph setLineBreakMode:NSLineBreakByTruncatingTail];
    [[tab label] drawInRect:NSMakeRect(27,3,MAX(0,[self bounds].size.width-34),16) withAttributes:
        [NSDictionary dictionaryWithObjectsAndKeys:[NSFont systemFontOfSize:11],NSFontAttributeName,
            [NSColor controlTextColor],NSForegroundColorAttributeName,
            paragraph,NSParagraphStyleAttributeName,nil]];
}
- (void)dealloc { [tab release]; [super dealloc]; }
@end

@interface SnowTabView ()
- (void)layoutTabs;
- (void)rebuildButtons;
- (void)selectClicked:(id)sender;
- (void)closeClicked:(id)sender;
- (void)windowStateChanged:(NSNotification *)note;
@end
@implementation SnowTabView
- (id)initWithFrame:(NSRect)frame
{
    self=[super initWithFrame:frame];
    if (self) {
        [self setTabViewType:NSNoTabsNoBorder]; [self setDrawsBackground:NO];
        tab_buttons=[[NSMutableArray alloc] init];
        strip=[[SnowTabStrip alloc] initWithFrame:NSZeroRect]; [self addSubview:strip];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowStateChanged:)
            name:NSWindowDidBecomeKeyNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowStateChanged:)
            name:NSWindowDidResignKeyNotification object:nil];
    }
    return self;
}
- (NSRect)contentRect
{
    NSRect rect=[super contentRect];
    if ([self numberOfTabViewItems]>1) {
        rect.size.height=MAX(0,rect.size.height-SnowTabStripHeight);
        if ([self isFlipped]) rect.origin.y+=SnowTabStripHeight;
    }
    return rect;
}
- (void)layoutTabs
{
    NSInteger count=[self numberOfTabViewItems]; NSRect bounds=[self bounds];
    [strip setHidden:count<2];
    [strip setFrame:NSMakeRect(NSMinX(bounds),[self isFlipped] ? NSMinY(bounds) : NSMaxY(bounds)-SnowTabStripHeight,bounds.size.width,SnowTabStripHeight)];
    CGFloat width=count ? MIN(202,floor(bounds.size.width/count)) : 0;
    NSInteger index=0;
    for (SnowTabButton *button in tab_buttons) { [button setFrame:NSMakeRect(index++*width,0,width+1,SnowTabStripHeight)]; }
    for (NSTabViewItem *item in [self tabViewItems]) [[item view] setFrame:[self contentRect]];
    [self refreshTabLabels];
}
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize { [super resizeSubviewsWithOldSize:oldSize]; [self layoutTabs]; }
- (void)rebuildButtons
{
    for (NSButton *button in tab_buttons) [button removeFromSuperview];
    [tab_buttons removeAllObjects];
    NSInteger index=0;
    for (NSTabViewItem *item in [self tabViewItems]) {
        SnowTabButton *button=[[[SnowTabButton alloc] initWithTab:item] autorelease];
        [button setTarget:self]; [button setAction:@selector(selectClicked:)]; [button setTag:index];
        NSButton *close=[[[SnowTabCloseButton alloc] initWithFrame:NSMakeRect(9,4,13,13)] autorelease];
        [close setButtonType:NSMomentaryChangeButton]; [close setBordered:NO];
        [close setTitle:@"Close Tab"]; [close setToolTip:@"Close Tab"];
        [close setTarget:self]; [close setAction:@selector(closeClicked:)]; [close setTag:index++];
        [button addSubview:close]; [strip addSubview:button]; [tab_buttons addObject:button];
    }
    [self layoutTabs];
}
- (void)addTabViewItem:(NSTabViewItem *)item { [super addTabViewItem:item]; [self rebuildButtons]; }
- (void)removeTabViewItem:(NSTabViewItem *)item { [super removeTabViewItem:item]; [self rebuildButtons]; }
- (void)selectTabViewItem:(NSTabViewItem *)item
{
    NSWindow *window=[self window];
    BOOL switching=item && item!=[self selectedTabViewItem] && [window isVisible];
    if (switching) {
        // On 10.6, detaching an NSOpenGLView exposes the Cocoa backing store
        // before its replacement's hardware surface has drawn its first frame.
        [window disableScreenUpdatesUntilFlush]; [window disableFlushWindow];
    }
    @try {
        [super selectTabViewItem:item]; [self layoutTabs];
        if (switching) {
            NSView *page=[item view];
            [self displayIfNeeded];
            if ([page isKindOfClass:[NSOpenGLView class]]) [[(NSOpenGLView *)page openGLContext] update];
            [page display];
        }
    } @finally {
        if (switching) { [window enableFlushWindow]; [window flushWindow]; }
    }
}
- (void)refreshTabLabels
{
    for (NSButton *button in tab_buttons) {
        NSInteger index=[button tag];
        if (index<[self numberOfTabViewItems]) {
            NSString *label=[[self tabViewItemAtIndex:index] label];
            [button setTitle:label]; [button setToolTip:label]; [button setNeedsDisplay:YES];
        }
    }
}
- (void)windowStateChanged:(NSNotification *)note { (void)note; [self refreshTabLabels]; }
- (void)selectClicked:(id)sender { [self selectTabViewItemAtIndex:[sender tag]]; }
- (void)closeClicked:(id)sender
{
    NSInteger index=[sender tag];
    if (index<[self numberOfTabViewItems])
        [(id<SnowTabActions>)[self delegate] closeTabItem:[self tabViewItemAtIndex:index]];
}
- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [tab_buttons release]; [strip release]; [super dealloc];
}
@end
