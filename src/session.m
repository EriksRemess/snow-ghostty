#import "session.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

typedef struct PendingSession {
    int master, gate;
    struct PendingSession *next;
} PendingSession;
// Session creation and release both run on the main thread.
static PendingSession *waiting_sessions;

static void release_session(int master, BOOL start)
{
    PendingSession **link=&waiting_sessions;
    while (*link) {
        PendingSession *session=*link;
        if (session->master!=master) { link=&session->next; continue; }
        *link=session->next;
        if (start) {
            ssize_t count;
            do { count=write(session->gate,"S",1); } while (count<0 && errno==EINTR);
            if (count!=1) perror("Starting terminal session");
        }
        close(session->gate); free(session); return;
    }
}

void snow_session_start(int master) { release_session(master,YES); }

void snow_session_process_name(pid_t pid, char *name, size_t capacity)
{
    if (pid<=0 || proc_name(pid,name,(uint32_t)capacity)>0) return;
    // Snow Leopard's setuid top denies libproc queries. KERN_PROC_PID still
    // exposes its short process name without reading protected arguments.
    int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_PID,pid}; struct kinfo_proc info={0}; size_t length=sizeof(info);
    if (sysctl(mib,4,&info,&length,NULL,0)==0 && length>0) strlcpy(name,info.kp_proc.p_comm,capacity);
}

static BOOL shell_process(const char *name)
{
    struct passwd *account=getpwuid(getuid());
    const char *configured=account ? account->pw_shell : NULL;
    if (configured) { const char *base=strrchr(configured,'/'); if (!strcmp(name,base ? base+1 : configured)) return YES; }
    const char *shells[]={"sh","bash","zsh","ksh","csh","tcsh","dash","fish","mksh","yash",NULL};
    for (int i=0;shells[i];i++) if (!strcmp(name,shells[i])) return YES;
    return NO;
}

NSArray *snow_session_running_jobs(pid_t child, BOOL retain_output)
{
    if (child<=0) return [NSArray array];
    int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_PID,child}; struct kinfo_proc owner={0}; size_t size=sizeof(owner);
    if (sysctl(mib,4,&owner,&size,NULL,0)<0 || size==0) {
        if (kill(child,0)<0 && errno==ESRCH) return [NSArray array];
        return [NSArray arrayWithObject:@"Running process"];
    }
    NSMutableSet *names=[NSMutableSet set];
    if (owner.kp_proc.p_stat!=SZOMB && (retain_output || !shell_process(owner.kp_proc.p_comm)))
        [names addObject:[NSString stringWithUTF8String:owner.kp_proc.p_comm] ?: @"Running process"];
    // Query only this controlling TTY, including background and stopped jobs.
    // Daemons that have detached from the terminal are deliberately excluded.
    if (owner.kp_eproc.e_tdev!=(dev_t)-1) {
        mib[2]=KERN_PROC_TTY; mib[3]=(int)owner.kp_eproc.e_tdev;
        BOOL listed=NO;
        for (int attempt=0;attempt<3 && !listed;attempt++) {
            size=0; if (sysctl(mib,4,NULL,&size,NULL,0)<0) break;
            size+=8*sizeof(struct kinfo_proc); struct kinfo_proc *processes=malloc(size);
            if (!processes) break;
            if (sysctl(mib,4,processes,&size,NULL,0)==0) {
                listed=YES;
                for (size_t i=0;i<size/sizeof(*processes);i++) {
                    struct kinfo_proc *process=&processes[i];
                    if (process->kp_proc.p_pid==child || process->kp_proc.p_stat==SZOMB) continue;
                    if (owner.kp_eproc.e_sess && process->kp_eproc.e_sess!=owner.kp_eproc.e_sess) continue;
                    // Prompt workers can retain the TTY after daemonizing. An
                    // orphaned background group is no longer a shell-owned job;
                    // foreground and job-controlled background/stopped groups
                    // still require confirmation, regardless of process name.
                    if (owner.kp_eproc.e_tpgid>0 && process->kp_eproc.e_jobc==0 &&
                        process->kp_eproc.e_pgid!=owner.kp_eproc.e_tpgid) continue;
                    [names addObject:[NSString stringWithUTF8String:process->kp_proc.p_comm] ?: @"Running process"];
                }
            }
            free(processes);
        }
        if (!listed) [names addObject:@"Running process"];
    }
    return [[names allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

// A closed tab must not leave a zombie while sibling tabs keep the app alive.
@interface SnowSessionReaper : NSObject
+ (void)reap:(NSNumber *)number;
@end
@implementation SnowSessionReaper
+ (void)reap:(NSNumber *)number
{
    if (waitpid([number intValue],NULL,WNOHANG)==0)
        [self performSelector:@selector(reap:) withObject:number afterDelay:0.5];
}
@end

void snow_session_close(int master, pid_t child)
{
    release_session(master,NO);
    if (master>=0) close(master);
    if (child>0) { kill(child,SIGHUP); [SnowSessionReaper reap:[NSNumber numberWithInt:child]]; }
}

BOOL snow_session_spawn(const char *command, const char *cwd, const char *script,
                          char **ssh_argv, int *master, pid_t *child)
{
    // Resolve account data and environment before fork: new tabs can be opened
    // after AppKit has started helper threads. No Objective-C runs in the child.
    struct passwd *account=getpwuid(getuid());
    const char *configured=account ? account->pw_shell : NULL;
    if (!configured || configured[0]!='/') configured=getenv("SHELL");
    if (!configured || configured[0]!='/') configured="/bin/bash";
    char *shell=strdup(configured);
    if (!shell) return NO;
    PendingSession *session=malloc(sizeof(*session));
    int gate[2]={-1,-1},no_sigpipe=1;
    if (!session || socketpair(AF_UNIX,SOCK_STREAM,0,gate)<0 ||
        fcntl(gate[0],F_SETFD,FD_CLOEXEC)<0 || fcntl(gate[1],F_SETFD,FD_CLOEXEC)<0 ||
        setsockopt(gate[1],SOL_SOCKET,SO_NOSIGPIPE,&no_sigpipe,sizeof(no_sigpipe))<0) {
        if (gate[0]>=0) close(gate[0]); if (gate[1]>=0) close(gate[1]);
        free(session); free(shell); return NO;
    }
    setenv("TERM","xterm-256color",1); setenv("COLORTERM","truecolor",1); setenv("SHELL",shell,1);
    struct winsize size={30,100,900,600};
    *child=forkpty(master,NULL,NULL,&size);
    if (*child==0) {
        close(gate[1]);
        for (PendingSession *other=waiting_sessions;other;other=other->next) close(other->gate);
        // Do not let shell startup format a prompt for the placeholder 100x30
        // size. AppKit must attach/layout the tab and issue TIOCSWINSZ first.
        char start=0; ssize_t count;
        do { count=read(gate[0],&start,1); } while (count<0 && errno==EINTR);
        close(gate[0]); if (count!=1 || start!='S') _exit(0);
        if (cwd && chdir(cwd)<0) _exit(127);
        if (script) execl(script,script,(char *)NULL);
        else if (ssh_argv) execv("/usr/bin/ssh",ssh_argv);
        else if (command) execl("/bin/sh","sh","-c",command,(char *)NULL);
        else execl(shell,shell,"-l",(char *)NULL);
        const char message[]="Could not execute terminal session\r\n";
        write(STDERR_FILENO,message,sizeof(message)-1); _exit(127);
    }
    close(gate[0]);
    free(shell);
    if (*child<0) { close(gate[1]); free(session); perror("forkpty"); return NO; }
    *session=(PendingSession){*master,gate[1],waiting_sessions}; waiting_sessions=session;
    int flags=fcntl(*master,F_GETFL,0);
    if (flags<0 || fcntl(*master,F_SETFL,flags|O_NONBLOCK)<0 || fcntl(*master,F_SETFD,FD_CLOEXEC)<0) {
        perror("PTY flags"); snow_session_close(*master,*child); *master=-1; *child=0; return NO;
    }
    return YES;
}
