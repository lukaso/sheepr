/* sigchild: run a command and send it a signal at a point a shell cell cannot catch in time
 * (tests/dist/t_exec_guard.sh, t_archive.sh). macOS only (libproc).
 *
 *   sigchild door SIG CMD ARG...   once /private/tmp holds sr-exec-guard.<CMD's pid>.*, send SIG to
 *                                  each child of CMD (the door's judging subshell, which makes
 *                                  that dir)
 *   sigchild tool:NAME SIG CMD ARG...
 *                                  once CMD has a child whose executable is named NAME, send SIG to
 *                                  CMD itself (the script, while its tool runs)
 *
 * CMD starts with every signal at its default (a cell's background job starts with INT and QUIT
 * ignored). SIG is a number; 0 sends nothing (the control: CMD runs on). Prints `pid N` (CMD's),
 * `sent PID...` (or `sent none` when the point never came, within 20 s, or CMD ended first), then
 * `rc N` (N = 128 + the signal when CMD died of one), then, in tool mode, `toolgone yes|no`: whether
 * the tool it saw had ended when CMD ended.
 */
#include <dirent.h>
#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int has_dir(const char *prefix) {
  DIR *d = opendir("/private/tmp");
  struct dirent *e;
  int f = 0;
  if (!d) return 0;
  while ((e = readdir(d)))
    if (strncmp(e->d_name, prefix, strlen(prefix)) == 0) { f = 1; break; }
  closedir(d);
  return f;
}

static int status_rc(int st) { return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st); }

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: sigchild door|tool:NAME SIG CMD ARG...\n"); return 2; }
  int door = strcmp(argv[1], "door") == 0;
  const char *tool = strncmp(argv[1], "tool:", 5) == 0 ? argv[1] + 5 : NULL;
  if (!door && !tool) { fprintf(stderr, "sigchild: mode door or tool:NAME\n"); return 2; }
  int sig = atoi(argv[2]);
  if (sig < 0 || (sig == 0 && strcmp(argv[2], "0") != 0)) { fprintf(stderr, "sigchild: SIG is a number\n"); return 2; }
  pid_t p = fork();
  if (p < 0) { perror("fork"); return 3; }
  if (p == 0) {
    for (int s = 1; s < NSIG; s++) if (s != SIGKILL && s != SIGSTOP) signal(s, SIG_DFL);
    execv(argv[3], argv + 3);
    _exit(127);
  }
  printf("pid %d\n", (int)p);
  fflush(stdout);
  char prefix[64];
  snprintf(prefix, sizeof prefix, "sr-exec-guard.%d.", (int)p);
  pid_t kids[256], seen = 0;
  int st;
  struct timespec t0, t1;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (;;) {
    if (waitpid(p, &st, WNOHANG) == p) { printf("sent none\nrc %d\n", status_rc(st)); if (tool) printf("toolgone no\n"); return 0; }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (t1.tv_sec - t0.tv_sec > 20) break;
    if (door && has_dir(prefix)) {
      int n = proc_listchildpids(p, kids, sizeof kids);
      if (n > 0) {
        printf("sent");
        for (int i = 0; i < n; i++) { kill(kids[i], sig); printf(" %d", (int)kids[i]); }
        printf("\n");
        waitpid(p, &st, 0);
        printf("rc %d\n", status_rc(st));
        return 0;
      }
    }
    if (tool) {
      int n = proc_listchildpids(p, kids, sizeof kids);
      for (int i = 0; i < n && !seen; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(kids[i], path, sizeof path) <= 0) continue;
        const char *b = strrchr(path, '/');
        b = b ? b + 1 : path;
        if (strcmp(b, tool) == 0) seen = kids[i];
      }
      if (seen) {
        kill(p, sig);
        printf("sent %d\n", (int)p);
        waitpid(p, &st, 0);
        printf("rc %d\n", status_rc(st));
        printf("toolgone %s\n", (kill(seen, 0) == -1 && errno == ESRCH) ? "yes" : "no");
        return 0;
      }
    }
    usleep(200);
  }
  printf("sent none\n");
  waitpid(p, &st, 0);
  printf("rc %d\n", status_rc(st));
  if (tool) printf("toolgone no\n");
  return 0;
}
