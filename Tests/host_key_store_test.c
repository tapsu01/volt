#include "VoltSSH.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void make_ed25519_key(unsigned char key[51], unsigned char seed) {
    const char algorithm[] = "ssh-ed25519";
    memset(key, 0, 51);
    key[3] = 11;
    memcpy(key + 4, algorithm, 11);
    key[18] = 32;
    for (int index = 0; index < 32; index++) key[19 + index] = (unsigned char)(seed + index);
}

static int line_count(const char *path) {
    FILE *file = fopen(path, "r");
    if (!file) return -1;
    int count = 0;
    int character;
    while ((character = fgetc(file)) != EOF) if (character == '\n') count++;
    fclose(file);
    return count;
}

static int commit(const char *host, const char *path, unsigned char seed) {
    unsigned char key[51];
    make_ed25519_key(key, seed);
    char error[1024] = {0};
    return volt_ssh_commit_host_key(host, 2222, path, key, sizeof(key), 6, error, sizeof(error));
}

int main(void) {
    char directory[] = "/tmp/VoltHostKeyTests.XXXXXX";
    if (!mkdtemp(directory)) return 1;

    char known_hosts[1024];
    snprintf(known_hosts, sizeof(known_hosts), "%s/known_hosts", directory);
    FILE *empty = fopen(known_hosts, "w");
    if (!empty) return 2;
    fclose(empty);

    unsigned char first_key[51];
    unsigned char different_key[51];
    make_ed25519_key(first_key, 1);
    make_ed25519_key(different_key, 2);
    char error[1024] = {0};

    if (volt_ssh_commit_host_key("example.test", 2222, known_hosts, first_key, sizeof(first_key), 6, error, sizeof(error)) != 0) return 3;
    if (volt_ssh_commit_host_key("example.test", 2222, known_hosts, first_key, sizeof(first_key), 6, error, sizeof(error)) != 0) return 4;
    if (line_count(known_hosts) != 1) return 5;
    if (volt_ssh_commit_host_key("example.test", 2222, known_hosts, different_key, sizeof(different_key), 6, error, sizeof(error)) >= 0) return 6;
    if (line_count(known_hosts) != 1) return 7;

    pid_t child = fork();
    if (child < 0) return 8;
    if (child == 0) _exit(commit("child.example.test", known_hosts, 3) == 0 ? 0 : 1);
    if (commit("parent.example.test", known_hosts, 4) != 0) return 9;
    int child_status = 0;
    if (waitpid(child, &child_status, 0) < 0 || !WIFEXITED(child_status) || WEXITSTATUS(child_status) != 0) return 10;
    if (line_count(known_hosts) != 3) return 11;

    struct stat attributes;
    if (stat(known_hosts, &attributes) != 0 || (attributes.st_mode & 0777) != 0600) return 12;

    unlink(known_hosts);
    char lock_path[1100];
    snprintf(lock_path, sizeof(lock_path), "%s.lock", known_hosts);
    unlink(lock_path);
    rmdir(directory);
    puts("Host key store security test passed.");
    return 0;
}
