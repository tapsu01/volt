/* Local SFTP benchmark driver. The script supplies an isolated destination,
 * generated test key and pinned test host. Never uses saved Volt connections. */
#include "VoltSSH.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>

static const char *username, *key, *known_hosts, *source, *destination;
static int port, count, workers;
static int overwrite;
static uint64_t cancel_after;
typedef struct Worker { int index; int failed; } Worker;

static int progress(uint64_t transferred, uint64_t total, void *context) {
    (void)total; (void)context;
    return cancel_after && transferred >= cancel_after;
}

static void *run_worker(void *context) {
    Worker *worker = context;
    char error[4096], path[4096];
#ifndef VOLT_BASELINE
    VoltSessionHandle *session = NULL;
    if (volt_session_open("127.0.0.1", port, username, NULL, key, known_hosts,
                          &session, error, sizeof(error)) != 0) {
        fprintf(stderr, "%s\n", error); worker->failed = 1; return NULL;
    }
#endif
    for (int i = worker->index; i < count; i += workers) {
        snprintf(path, sizeof(path), "%s/file-%d", destination, i);
#ifdef VOLT_BASELINE
        int status = volt_sftp_upload("127.0.0.1", port, username, NULL, key, known_hosts,
                                     source, path, 0600, overwrite, progress, NULL, error, sizeof(error));
#else
        int status = volt_sftp_upload_on(session, source, path, 0600, overwrite, progress, NULL, error, sizeof(error));
#endif
        if (status < 0) { fprintf(stderr, "%s\n", error); worker->failed = 1; break; }
    }
#ifndef VOLT_BASELINE
    volt_session_close(session);
#endif
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 9 || argc > 11) return 2;
    port = atoi(argv[1]); username = argv[2]; key = argv[3]; known_hosts = argv[4];
    source = argv[5]; destination = argv[6]; count = atoi(argv[7]); workers = atoi(argv[8]);
    overwrite = argc >= 10 ? atoi(argv[9]) : 0;
    cancel_after = argc == 11 ? strtoull(argv[10], NULL, 10) : 0;
    if (count < 1 || workers < 1 || workers > 4) return 2;
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    pthread_t threads[4]; Worker contexts[4] = {0};
    for (int i = 0; i < workers; i++) {
        contexts[i].index = i;
        if (pthread_create(&threads[i], NULL, run_worker, &contexts[i]) != 0) return 3;
    }
    int failed = 0;
    for (int i = 0; i < workers; i++) { pthread_join(threads[i], NULL); failed |= contexts[i].failed; }
    clock_gettime(CLOCK_MONOTONIC, &end);
    struct rusage usage; getrusage(RUSAGE_SELF, &usage);
    double elapsed = end.tv_sec - start.tv_sec + (end.tv_nsec - start.tv_nsec) / 1e9;
#ifdef VOLT_BASELINE
    int sessions = count;
#else
    int sessions = workers;
#endif
    printf("files=%d workers=%d sessions=%d seconds=%.3f driver_peak_rss_bytes=%ld result=%s\n",
           count, workers, sessions, elapsed, usage.ru_maxrss, failed ? "failed" : "passed");
    return failed;
}
