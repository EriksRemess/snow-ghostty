#import "config.h"
#import <ApplicationServices/ApplicationServices.h>
#include <math.h>

ImacConfig imac_config;

static NSString *trim(NSString *text)
{
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL rgb(NSString *text, GhosttyColorRgb *color)
{
    if ([text hasPrefix:@"#"]) text=[text substringFromIndex:1];
    if ([text length]!=6 || [text rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location!=NSNotFound) return NO;
    unsigned value=0;
    if (![[NSScanner scannerWithString:text] scanHexInt:&value]) return NO;
    *color=(GhosttyColorRgb){value>>16,(value>>8)&255,value&255}; return YES;
}

static BOOL load_file(NSString *path, BOOL theme)
{
    NSError *error=nil;
    NSString *contents=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (!contents) { fprintf(stderr,"Config: %s: %s\n",[path fileSystemRepresentation],[[error localizedDescription] UTF8String]); return NO; }
    NSUInteger line_number=0;
    for (NSString *line in [contents componentsSeparatedByString:@"\n"]) {
        line_number++;
        line=trim(line); if (![line length] || [line hasPrefix:@"#"]) continue;
        NSRange separator=[line rangeOfString:@"="];
        if (separator.location==NSNotFound) goto invalid;
        NSString *key=trim([line substringToIndex:separator.location]);
        NSString *value=trim([line substringFromIndex:separator.location+1]);
        if ([value length]>=2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""])
            value=[value substringWithRange:NSMakeRange(1,[value length]-2)];
        if (!theme) {
            if ([key isEqualToString:@"font-family"] && [value length]) {
                [imac_config.font_family release]; imac_config.font_family=[value copy];
            } else if ([key isEqualToString:@"font-size"]) {
                double size=0; NSScanner *scanner=[NSScanner scannerWithString:value];
                if (![scanner scanDouble:&size] || ![scanner isAtEnd] || !isfinite(size) || size<6 || size>72) goto invalid;
                imac_config.font_size=size;
            } else if ([key isEqualToString:@"theme"] && [value isEqualToString:@"Catppuccin Mocha"]) {
                // The single bundled scheme is applied before user font settings.
            } else goto invalid;
        } else {
            GhosttyColorRgb *color=NULL;
            if ([key isEqualToString:@"background"]) color=&imac_config.background;
            else if ([key isEqualToString:@"foreground"]) color=&imac_config.foreground;
            else if ([key isEqualToString:@"cursor-color"]) color=&imac_config.cursor;
            else if ([key isEqualToString:@"cursor-text"]) color=&imac_config.cursor_text;
            else if ([key isEqualToString:@"selection-background"]) color=&imac_config.selection_background;
            else if ([key isEqualToString:@"selection-foreground"]) color=&imac_config.selection_foreground;
            else if ([key isEqualToString:@"palette"]) {
                NSRange equals=[value rangeOfString:@"="]; int index=0;
                if (equals.location==NSNotFound) goto invalid;
                NSScanner *scanner=[NSScanner scannerWithString:[value substringToIndex:equals.location]];
                if (![scanner scanInt:&index] || ![scanner isAtEnd] || index<0 || index>15) goto invalid;
                color=&imac_config.palette[index]; value=trim([value substringFromIndex:equals.location+1]);
            } else goto invalid;
            if (!rgb(value,color)) goto invalid;
        }
        continue;
invalid:
        fprintf(stderr,"Config: invalid setting at %s:%lu: %s\n",[path fileSystemRepresentation],(unsigned long)line_number,[line UTF8String]);
        return NO;
    }
    return YES;
}

BOOL imac_config_load(NSString *explicit_path)
{
    NSString *resources=[[NSBundle mainBundle] resourcePath];
    if (!load_file([resources stringByAppendingPathComponent:@"themes/catppuccin-mocha.theme"],YES) ||
        !load_file([resources stringByAppendingPathComponent:@"default.config"],NO)) return NO;
    NSString *path=explicit_path;
    NSFileManager *manager=[NSFileManager defaultManager];
    if (!path) {
        const char *xdg=getenv("XDG_CONFIG_HOME");
        NSString *base=xdg && xdg[0]=='/' ? [NSString stringWithUTF8String:xdg] : [NSHomeDirectory() stringByAppendingPathComponent:@".config"];
        path=[base stringByAppendingPathComponent:@"snow-ghostty/config"];
        if (![manager fileExistsAtPath:path]) {
            NSError *error=nil;
            NSString *directory=[path stringByDeletingLastPathComponent];
            NSString *legacy=[base stringByAppendingPathComponent:@"ghostty-imac/config"];
            NSString *source=[manager fileExistsAtPath:legacy] ? legacy : [resources stringByAppendingPathComponent:@"default.config"];
            if (![manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error] ||
                ![manager copyItemAtPath:source toPath:path error:&error]) {
                fprintf(stderr,"Could not create config %s: %s; using bundled defaults\n",[path fileSystemRepresentation],[[error localizedDescription] UTF8String]);
                return YES;
            }
        }
    }
    if (!load_file([path stringByExpandingTildeInPath],NO)) return NO;
    fprintf(stderr,"Config: %s; font %s %.2f; theme Catppuccin Mocha\n",[path fileSystemRepresentation],[imac_config.font_family UTF8String],(double)imac_config.font_size);
    return YES;
}

BOOL imac_register_fonts(void)
{
    NSString *directory=[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"fonts"];
    for (NSString *name in [NSArray arrayWithObjects:@"FiraCodeNerdFontMono-Regular.ttf",@"FiraCodeNerdFontMono-Bold.ttf",nil]) {
        NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]];
        CFErrorRef error=NULL;
        if (!CTFontManagerRegisterFontsForURL((CFURLRef)url,kCTFontManagerScopeProcess,&error)) {
            fprintf(stderr,"Bundled font registration failed: %s\n",[name UTF8String]);
            if (error) { CFShow(error); CFRelease(error); }
            return NO;
        }
        fprintf(stderr,"Registered bundled font: %s\n",[name UTF8String]);
    }
    return YES;
}
