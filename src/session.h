#pragma once
#import <Foundation/Foundation.h>
#include <sys/types.h>

void snow_session_process_name(pid_t pid, char *name, size_t capacity);
NSArray *snow_session_running_jobs(pid_t child, BOOL retain_output);
void snow_session_close(int master, pid_t child);
// Release a newly spawned child after its view has installed final PTY geometry.
void snow_session_start(int master);
BOOL snow_session_spawn(const char *command, const char *cwd, const char *script,
                        char **ssh_argv, int *master, pid_t *child);
