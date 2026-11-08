#import "desktop.h"
#import <ApplicationServices/ApplicationServices.h>

NSArray *snow_file_arguments(NSString *path, BOOL directory_only, NSString **error)
{
    path=[[path stringByExpandingTildeInPath] stringByStandardizingPath];
    BOOL directory=NO;
    NSFileManager *manager=[NSFileManager defaultManager];
    if (![path isAbsolutePath]) path=[[[manager currentDirectoryPath] stringByAppendingPathComponent:path] stringByStandardizingPath];
    if (![manager fileExistsAtPath:path isDirectory:&directory]) { if(error)*error=@"The selected path does not exist."; return nil; }
    if (directory || directory_only) {
        if (!directory) path=[path stringByDeletingLastPathComponent];
        return [NSArray arrayWithObjects:@"--working-directory",path,nil];
    }
    if (![[path pathExtension] isEqualToString:@"command"] || ![manager isExecutableFileAtPath:path]) {
        if(error)*error=@"Select an executable .command file or a folder."; return nil;
    }
    return [NSArray arrayWithObjects:@"--execute-file",path,nil];
}

NSArray *snow_ssh_arguments(NSString *text, NSString **error)
{
    NSURL *url=[NSURL URLWithString:text];
    NSString *host=[url host], *user=[url user];
    if ([host hasPrefix:@"["] && [host hasSuffix:@"]"]) host=[host substringWithRange:NSMakeRange(1,[host length]-2)];
    NSCharacterSet *host_chars=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-"];
    NSCharacterSet *user_chars=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSNumber *port=[url port];
    if (![[[url scheme] lowercaseString] isEqualToString:@"ssh"] || ![host length] || [host hasPrefix:@"-"] ||
        [host rangeOfCharacterFromSet:[host_chars invertedSet]].location!=NSNotFound ||
        (user && (![user length] || [user rangeOfCharacterFromSet:[user_chars invertedSet]].location!=NSNotFound)) ||
        [url password] || [url query] || [url fragment] ||
        ([[url path] length] && ![[url path] isEqualToString:@"/"]) ||
        (port && ([port intValue]<1 || [port intValue]>65535))) {
        if(error)*error=@"Use ssh://[user@]host[:port], without passwords, paths, or commands."; return nil;
    }
    NSMutableArray *arguments=[NSMutableArray arrayWithObject:@"/usr/bin/ssh"];
    if (port) [arguments addObjectsFromArray:[NSArray arrayWithObjects:@"-p",[port stringValue],nil]];
    [arguments addObject:@"--"];
    [arguments addObject:user ? [NSString stringWithFormat:@"%@@%@",user,host] : host];
    return arguments;
}

BOOL snow_make_default(NSString **error)
{
    CFStringRef identifier=(CFStringRef)[[NSBundle mainBundle] bundleIdentifier];
    CFStringRef previous=LSCopyDefaultRoleHandlerForContentType(CFSTR("com.apple.terminal.shell-script"),kLSRolesShell);
    OSStatus file=LSSetDefaultRoleHandlerForContentType(CFSTR("com.apple.terminal.shell-script"),kLSRolesShell,identifier);
    OSStatus url=file==noErr ? LSSetDefaultHandlerForURLScheme(CFSTR("ssh"),identifier) : file;
    if (file==noErr && url!=noErr && previous) LSSetDefaultRoleHandlerForContentType(CFSTR("com.apple.terminal.shell-script"),kLSRolesShell,previous);
    if(previous) CFRelease(previous);
    if (file!=noErr || url!=noErr) { if(error)*error=[NSString stringWithFormat:@"Could not set default handlers (%d / %d).",(int)file,(int)url]; return NO; }
    return YES;
}
