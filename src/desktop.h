#import <Cocoa/Cocoa.h>
NSArray *snow_file_arguments(NSString *path, BOOL directory_only, NSString **error);
NSArray *snow_ssh_arguments(NSString *url, NSString **error);
BOOL snow_make_default(NSString **error);
