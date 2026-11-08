#import "menus.h"

// Session actions belong to the application delegate. Editing and window
// actions use Cocoa's responder chain, including while About has focus.
@protocol SnowMenuActions
- (void)showAbout:(id)sender;
- (void)newWindow:(id)sender;
- (void)makeDefaultTerminal:(id)sender;
- (void)showHelp:(id)sender;
- (void)showSettings:(id)sender;
- (void)reloadConfiguration:(id)sender;
- (void)toggleSecureKeyboardEntry:(id)sender;
- (void)newTab:(id)sender;
- (void)closeTab:(id)sender;
- (void)closeWindow:(id)sender;
- (void)nextTab:(id)sender;
- (void)previousTab:(id)sender;
- (void)nextWindow:(id)sender;
- (void)previousWindow:(id)sender;
@end

@interface SnowMainMenu : NSMenu {
    NSMenuItem *reload_item; // owned by this menu's application submenu
}
- (void)setReloadItem:(NSMenuItem *)item;
@end
@implementation SnowMainMenu
- (void)setReloadItem:(NSMenuItem *)item { reload_item=item; }
- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    NSUInteger modifiers=[event modifierFlags]&(NSCommandKeyMask|NSShiftKeyMask|NSControlKeyMask|NSAlternateKeyMask);
    if (modifiers==(NSCommandKeyMask|NSShiftKeyMask) &&
        ([event keyCode]==43 || [[event charactersIgnoringModifiers] isEqualToString:@","])) {
        // Snow Leopard matches shifted punctuation literally. Route this chord
        // explicitly so the menu can display ⇧⌘, without colliding with Settings.
        [[reload_item menu] update];
        return [reload_item isEnabled] && [NSApp sendAction:[reload_item action] to:[reload_item target] from:reload_item];
    }
    return [super performKeyEquivalent:event];
}
@end

static NSMenu *submenu(NSMenu *parent, NSString *title)
{
    NSMenuItem *item=[[[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""] autorelease];
    NSMenu *menu=[[[NSMenu alloc] initWithTitle:title] autorelease];
    [item setSubmenu:menu]; [parent addItem:item]; return menu;
}

static NSMenuItem *item(NSMenu *menu, NSString *title, SEL action, NSString *key, id target)
{
    NSMenuItem *result=[menu addItemWithTitle:title action:action keyEquivalent:key];
    [result setTarget:target]; [result setKeyEquivalentModifierMask:NSCommandKeyMask];
    return result;
}

void snow_install_menus(id target)
{
    SnowMainMenu *main=[[[SnowMainMenu alloc] initWithTitle:@"Main"] autorelease];
    NSMenu *app=submenu(main,@"Snow Ghostty");
    item(app,@"About Snow Ghostty",@selector(showAbout:),@"",target);
    [app addItem:[NSMenuItem separatorItem]];
    item(app,@"Settings…",@selector(showSettings:),@",",target);
    NSMenuItem *reload=item(app,@"Reload Configuration",@selector(reloadConfiguration:),@",",target);
    [reload setKeyEquivalentModifierMask:NSCommandKeyMask|NSShiftKeyMask]; [main setReloadItem:reload];
    item(app,@"Secure Keyboard Entry",@selector(toggleSecureKeyboardEntry:),@"",target);
    [app addItem:[NSMenuItem separatorItem]];
    item(app,@"Set as Default Terminal",@selector(makeDefaultTerminal:),@"",target);
    [app addItem:[NSMenuItem separatorItem]];
    [NSApp setServicesMenu:submenu(app,@"Services")];
    [app addItem:[NSMenuItem separatorItem]];
    item(app,@"Hide Snow Ghostty",@selector(hide:),@"h",NSApp);
    [item(app,@"Hide Others",@selector(hideOtherApplications:),@"h",NSApp)
        setKeyEquivalentModifierMask:NSCommandKeyMask|NSAlternateKeyMask];
    item(app,@"Show All",@selector(unhideAllApplications:),@"",NSApp);
    [app addItem:[NSMenuItem separatorItem]];
    item(app,@"Quit Snow Ghostty",@selector(terminate:),@"q",NSApp);

    NSMenu *file=submenu(main,@"File");
    item(file,@"New Window",@selector(newWindow:),@"n",target);
    item(file,@"New Tab",@selector(newTab:),@"t",target);
    [file addItem:[NSMenuItem separatorItem]];
    item(file,@"Close Tab",@selector(closeTab:),@"w",target);
    [item(file,@"Close Window",@selector(closeWindow:),@"W",target)
        setKeyEquivalentModifierMask:NSCommandKeyMask|NSShiftKeyMask];

    NSMenu *edit=submenu(main,@"Edit");
    item(edit,@"Copy",@selector(copy:),@"c",nil);
    item(edit,@"Paste",@selector(paste:),@"v",nil);
    [edit addItem:[NSMenuItem separatorItem]];
    item(edit,@"Select All",@selector(selectAll:),@"a",nil);
    [edit addItem:[NSMenuItem separatorItem]];
    item(edit,@"Clear Scrollback",@selector(clearScrollback:),@"k",nil);
    item(edit,@"Reset Terminal",@selector(resetTerminal:),@"r",nil);

    NSMenu *view=submenu(main,@"View");
    item(view,@"Toggle Fullscreen",@selector(toggleFullscreen:),@"\r",nil);
    [view addItem:[NSMenuItem separatorItem]];
    item(view,@"Increase Font Size",@selector(increaseFontSize:),@"+",nil);
    item(view,@"Decrease Font Size",@selector(decreaseFontSize:),@"-",nil);
    item(view,@"Reset Font Size",@selector(resetFontSize:),@"0",nil);

    NSMenu *window=submenu(main,@"Window");
    item(window,@"Minimize",@selector(performMiniaturize:),@"m",nil);
    item(window,@"Zoom",@selector(performZoom:),@"",nil);
    [window addItem:[NSMenuItem separatorItem]];
    item(window,@"Cycle Through Windows",@selector(nextWindow:),@"`",target);
    [item(window,@"Select Previous Window",@selector(previousWindow:),@"~",target)
        setKeyEquivalentModifierMask:NSCommandKeyMask|NSShiftKeyMask];
    [window addItem:[NSMenuItem separatorItem]];
    [item(window,@"Select Next Tab",@selector(nextTab:),@"}",target)
        setKeyEquivalentModifierMask:NSCommandKeyMask|NSShiftKeyMask];
    [item(window,@"Select Previous Tab",@selector(previousTab:),@"{",target)
        setKeyEquivalentModifierMask:NSCommandKeyMask|NSShiftKeyMask];
    [window addItem:[NSMenuItem separatorItem]];
    item(window,@"Bring All to Front",@selector(arrangeInFront:),@"",NSApp);
    [NSApp setWindowsMenu:window];

    NSMenu *help=submenu(main,@"Help");
    item(help,@"Snow Ghostty Help",@selector(showHelp:),@"",target);
    [NSApp setHelpMenu:help];
    [NSApp setMainMenu:main];
}

void snow_show_about(const char *core_version)
{
    NSString *text=[NSString stringWithFormat:@"Powered by libghostty-vt %s\n\nSnow Ghostty on GitHub",core_version];
    NSMutableParagraphStyle *paragraph=[[[NSMutableParagraphStyle alloc] init] autorelease];
    [paragraph setAlignment:NSCenterTextAlignment];
    NSMutableAttributedString *credits=[[[NSMutableAttributedString alloc] initWithString:text attributes:
        [NSDictionary dictionaryWithObjectsAndKeys:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]],NSFontAttributeName,
            paragraph,NSParagraphStyleAttributeName,nil]] autorelease];
    [credits addAttribute:NSLinkAttributeName value:[NSURL URLWithString:@"https://github.com/EriksRemess/snow-ghostty"]
        range:[text rangeOfString:@"Snow Ghostty on GitHub"]];
    NSMutableDictionary *options=[NSMutableDictionary dictionaryWithObject:credits forKey:@"Credits"];
    NSDictionary *info=[[NSBundle mainBundle] infoDictionary];
    // Cocoa otherwise displays identical marketing/build versions twice.
    if ([[info objectForKey:@"CFBundleVersion"] isEqual:[info objectForKey:@"CFBundleShortVersionString"]])
        [options setObject:@"" forKey:@"Version"];
    [NSApp orderFrontStandardAboutPanelWithOptions:options];
}
