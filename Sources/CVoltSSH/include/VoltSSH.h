#ifndef VOLT_SSH_H
#define VOLT_SSH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VoltSFTPItem {
    char name[1024];
    char path[4096];
    int is_directory;
    int64_t size;
    int64_t modified;
    uint32_t permissions;
    uint32_t uid;
    uint32_t gid;
} VoltSFTPItem;

typedef int (*VoltSFTPProgressCallback)(uint64_t transferred, uint64_t total, void *context);

#define VOLT_HOSTKEY_MATCH 0
#define VOLT_HOSTKEY_UNKNOWN 1
#define VOLT_HOSTKEY_MISMATCH 2
#define VOLT_SFTP_PERMISSION_WARNING 1

int volt_ssh_probe_host_key(const char *host, int port, const char *known_hosts_path, unsigned char **key, size_t *key_len, int *key_type, int *trust_status, char *error, size_t error_len);
int volt_ssh_commit_host_key(const char *host, int port, const char *known_hosts_path, const unsigned char *key, size_t key_len, int key_type, char *error, size_t error_len);
void volt_ssh_free_buffer(void *buffer);

int volt_sftp_list(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *remote_path, VoltSFTPItem **items, int *count, char *error, size_t error_len);
int volt_sftp_upload(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *local_path, const char *remote_path, uint32_t mode, VoltSFTPProgressCallback progress, void *progress_context, char *error, size_t error_len);
int volt_sftp_download(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *remote_path, const char *local_path, VoltSFTPProgressCallback progress, void *progress_context, char *error, size_t error_len);
int volt_sftp_mkdir(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *remote_path, uint32_t mode, char *error, size_t error_len);
int volt_sftp_create_empty_file(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *remote_path, uint32_t mode, char *error, size_t error_len);
int volt_sftp_rename(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *from_path, const char *to_path, char *error, size_t error_len);
int volt_sftp_remove(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *remote_path, int is_directory, char *error, size_t error_len);
void volt_sftp_free_items(VoltSFTPItem *items);
const char *volt_sftp_item_name(const VoltSFTPItem *items, int index);
const char *volt_sftp_item_path(const VoltSFTPItem *items, int index);
int volt_sftp_item_is_directory(const VoltSFTPItem *items, int index);
int64_t volt_sftp_item_size(const VoltSFTPItem *items, int index);
int64_t volt_sftp_item_modified(const VoltSFTPItem *items, int index);
uint32_t volt_sftp_item_permissions(const VoltSFTPItem *items, int index);
uint32_t volt_sftp_item_uid(const VoltSFTPItem *items, int index);
uint32_t volt_sftp_item_gid(const VoltSFTPItem *items, int index);

#ifdef __cplusplus
}
#endif

#endif
