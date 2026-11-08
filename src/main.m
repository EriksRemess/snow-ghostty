#import "application.h"
#import <ApplicationServices/ApplicationServices.h>
#include "config.h"
#include "desktop.h"
#include "platform.h"
#include "session.h"
#include <ghostty/vt.h>
#include <signal.h>
#include <unistd.h>

int main(int argc,char **argv)
{
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    const char *command=NULL; NSString *config_path=nil, *directory=nil, *file=nil, *ssh_url=nil;
    BOOL make_default=NO;
    for (int i=1;i<argc;i++) {
        if (!strncmp(argv[i],"--",2)) snow_app.explicit_cli=YES;
        if (!strcmp(argv[i],"--self-test")) snow_app.self_test=YES;
        else if (!strncmp(argv[i],"-psn_",5)) continue; // Snow Leopard Launch Services argument.
        else if (!strcmp(argv[i],"--integration-test")) { snow_app.integration_test=YES; command="exec /bin/sh -i"; }
        else if (!strcmp(argv[i],"--capture") && i+1<argc) snow_app.requested_capture=[[NSString alloc] initWithUTF8String:argv[++i]];
        else if (!strcmp(argv[i],"--command") && i+1<argc) command=argv[++i];
        else if (!strcmp(argv[i],"--config") && i+1<argc) config_path=[NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(argv[i],"--working-directory") && i+1<argc) directory=[NSString stringWithUTF8String:argv[++i]];
        else if (!strcmp(argv[i],"--execute-file") && i+1<argc) { file=[NSString stringWithUTF8String:argv[++i]]; snow_app.keep_on_exit=YES; }
        else if (!strcmp(argv[i],"--ssh") && i+1<argc) { ssh_url=[NSString stringWithUTF8String:argv[++i]]; snow_app.keep_on_exit=YES; }
        else if (!strcmp(argv[i],"--make-default")) make_default=YES;
        else if (!strcmp(argv[i],"--version")) {
            printf("Snow Ghostty 0.3.0 (libghostty-vt %s)\n",ghostty_version());
            [pool drain]; return 0;
        }
        else if (!strcmp(argv[i],"--help")) {
            puts("Snow Ghostty: native Snow Leopard terminal\nUsage: snow-ghostty [--config PATH] [--working-directory DIR] [--capture PNG]\n       snow-ghostty --command COMMAND|--execute-file FILE|--ssh URL\n       snow-ghostty --make-default\n       snow-ghostty --self-test|--integration-test [--config PATH] [--capture PNG]");
            [pool drain]; return 0;
        } else { fputs("Unknown option; use --help\n",stderr); [pool drain]; return 2; }
    }
    if (snow_app.self_test && snow_app.integration_test) { fputs("Choose one test mode\n",stderr); [pool drain]; return 2; }
    NSString *error=nil;
    if (make_default) { [NSApplication sharedApplication]; BOOL ok=snow_make_default(&error); if(!ok) fprintf(stderr,"%s\n",[error UTF8String]); [pool drain]; return ok ? 0 : 1; }
    if ((file && ssh_url) || ((file || ssh_url) && (command || snow_app.self_test))) { fputs("Choose one session command\n",stderr); [pool drain]; return 2; }
    NSArray *ssh_arguments=ssh_url ? snow_ssh_arguments(ssh_url,&error) : nil;
    if (ssh_url && !ssh_arguments) { fprintf(stderr,"%s\n",[error UTF8String]); [pool drain]; return 2; }
    if (file) {
        NSArray *args=snow_file_arguments(file,NO,&error);
        if (!args || ![[args objectAtIndex:0] isEqualToString:@"--execute-file"]) { fprintf(stderr,"%s\n",[error ? error : @"Expected an executable .command file." UTF8String]); [pool drain]; return 2; }
        file=[args objectAtIndex:1]; if(!directory) directory=[file stringByDeletingLastPathComponent];
    }
    if (directory) {
        NSArray *args=snow_file_arguments(directory,YES,&error); BOOL is_directory=NO;
        [[NSFileManager defaultManager] fileExistsAtPath:[directory stringByExpandingTildeInPath] isDirectory:&is_directory];
        if (!args || !is_directory) { fputs("Working directory must be an existing folder\n",stderr); [pool drain]; return 2; }
        directory=[args objectAtIndex:1];
    }
    if (!imac_config_load(config_path)) { [pool drain]; return 2; }
    signal(SIGPIPE,SIG_IGN); imac_core_init();
    int master=-1; pid_t child=0;
    const char *cwd=directory ? [directory fileSystemRepresentation] : getenv("HOME");
    const char *script=file ? [file fileSystemRepresentation] : NULL;
    char **ssh_argv=NULL;
    if (ssh_arguments) {
        ssh_argv=calloc([ssh_arguments count]+1,sizeof(char *)); if(!ssh_argv) return 1;
        for(NSUInteger i=0;i<[ssh_arguments count];i++) ssh_argv[i]=strdup([[ssh_arguments objectAtIndex:i] UTF8String]);
    }
    if (!snow_app.self_test && !snow_session_spawn(command,cwd,script,ssh_argv,&master,&child)) { [pool drain]; return 1; }
    if (ssh_argv) { for (char **arg=ssh_argv; *arg; arg++) free(*arg); free(ssh_argv); }
    if (!imac_register_fonts()) { if(master>=0) close(master); if(child>0) kill(child,SIGHUP); [pool drain]; return 1; }
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    AppDelegate *delegate=[[AppDelegate alloc] initWithFD:master child:child];
    [[NSAppleEventManager sharedAppleEventManager] setEventHandler:delegate andSelector:@selector(handleURL:reply:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
    [NSApp setDelegate:delegate]; [NSApp run];
    [delegate release]; [pool drain]; return snow_app.test_result;
}
