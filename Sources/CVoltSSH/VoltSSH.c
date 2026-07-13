#include "VoltSSH.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <netdb.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/file.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define VOLT_SFTP_TRANSFER_BUFFER_SIZE (256 * 1024)

typedef struct VoltSession {
    int sock;
    LIBSSH2_SESSION *session;
    LIBSSH2_SFTP *sftp;
} VoltSession;

static pthread_once_t libssh2_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t known_hosts_mutex = PTHREAD_MUTEX_INITIALIZER;
static int libssh2_init_result = -1;
static const int volt_timeout_seconds = 15;

static void initialize_libssh2(void) {
    libssh2_init_result = libssh2_init(0);
}

static void set_error(char *error, size_t error_len, const char *message) {
    if (!error || error_len == 0) return;
    if (!message) message = "Unknown SSH error";
    snprintf(error, error_len, "%s", message);
}

static void set_session_error(LIBSSH2_SESSION *session, char *error, size_t error_len, const char *fallback) {
    char *message = NULL;
    int len = 0;
    if (session) {
        libssh2_session_last_error(session, &message, &len, 0);
    }
    if (message && len > 0) {
        if (error && error_len > 0) {
            size_t copy_len = (size_t)len < error_len - 1 ? (size_t)len : error_len - 1;
            memcpy(error, message, copy_len);
            error[copy_len] = '\0';
        }
    } else {
        set_error(error, error_len, fallback);
    }
}

static int connect_socket(const char *host, int port, char *error, size_t error_len) {
    char port_text[16];
    snprintf(port_text, sizeof(port_text), "%d", port);

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *result = NULL;
    int rc = getaddrinfo(host, port_text, &hints, &result);
    if (rc != 0) {
        set_error(error, error_len, gai_strerror(rc));
        return -1;
    }

    int sock = -1;
    for (struct addrinfo *ai = result; ai; ai = ai->ai_next) {
        sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (sock < 0) continue;

        int original_flags = fcntl(sock, F_GETFL, 0);
        if (original_flags < 0 || fcntl(sock, F_SETFL, original_flags | O_NONBLOCK) != 0) {
            close(sock);
            sock = -1;
            continue;
        }

        int connect_result = connect(sock, ai->ai_addr, ai->ai_addrlen);
        if (connect_result != 0 && errno == EINPROGRESS) {
            fd_set write_set;
            FD_ZERO(&write_set);
            FD_SET(sock, &write_set);
            struct timeval timeout = { .tv_sec = volt_timeout_seconds, .tv_usec = 0 };
            connect_result = select(sock + 1, NULL, &write_set, NULL, &timeout);
            if (connect_result > 0) {
                int socket_error = 0;
                socklen_t socket_error_len = sizeof(socket_error);
                if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &socket_error, &socket_error_len) != 0 || socket_error != 0) {
                    connect_result = -1;
                    errno = socket_error ? socket_error : errno;
                } else {
                    connect_result = 0;
                }
            } else if (connect_result == 0) {
                errno = ETIMEDOUT;
                connect_result = -1;
            }
        }

        if (connect_result == 0) {
            fcntl(sock, F_SETFL, original_flags);
            struct timeval io_timeout = { .tv_sec = volt_timeout_seconds, .tv_usec = 0 };
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &io_timeout, sizeof(io_timeout));
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &io_timeout, sizeof(io_timeout));
            break;
        }
        close(sock);
        sock = -1;
    }

    freeaddrinfo(result);
    if (sock < 0) {
        set_error(error, error_len, strerror(errno));
    }
    return sock;
}

static int auth_with_agent(LIBSSH2_SESSION *session, const char *username, char *error, size_t error_len) {
    LIBSSH2_AGENT *agent = libssh2_agent_init(session);
    if (!agent) return -1;

    int ok = -1;
    if (libssh2_agent_connect(agent) == 0 && libssh2_agent_list_identities(agent) == 0) {
        struct libssh2_agent_publickey *identity = NULL;
        struct libssh2_agent_publickey *prev = NULL;
        while (libssh2_agent_get_identity(agent, &identity, prev) == 0) {
            if (libssh2_agent_userauth(agent, username, identity) == 0) {
                ok = 0;
                break;
            }
            prev = identity;
        }
    }

    libssh2_agent_disconnect(agent);
    libssh2_agent_free(agent);
    if (ok != 0) set_session_error(session, error, error_len, "SSH agent authentication failed.");
    return ok;
}

static int known_host_key_type(int hostkey_type) {
    switch (hostkey_type) {
        case LIBSSH2_HOSTKEY_TYPE_RSA: return LIBSSH2_KNOWNHOST_KEY_SSHRSA;
        case LIBSSH2_HOSTKEY_TYPE_DSS: return LIBSSH2_KNOWNHOST_KEY_SSHDSS;
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return LIBSSH2_KNOWNHOST_KEY_ECDSA_256;
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return LIBSSH2_KNOWNHOST_KEY_ECDSA_384;
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return LIBSSH2_KNOWNHOST_KEY_ECDSA_521;
        case LIBSSH2_HOSTKEY_TYPE_ED25519: return LIBSSH2_KNOWNHOST_KEY_ED25519;
        default: return LIBSSH2_KNOWNHOST_KEY_UNKNOWN;
    }
}

const char *volt_ssh_openssh_host_key_algorithm(int key_type) {
    switch (key_type) {
        case LIBSSH2_HOSTKEY_TYPE_RSA: return "rsa-sha2-512,rsa-sha2-256,ssh-rsa";
        case LIBSSH2_HOSTKEY_TYPE_DSS: return "ssh-dss";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return "ecdsa-sha2-nistp256";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return "ecdsa-sha2-nistp384";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return "ecdsa-sha2-nistp521";
        case LIBSSH2_HOSTKEY_TYPE_ED25519: return "ssh-ed25519";
        default: return NULL;
    }
}

const char *volt_ssh_openssh_known_host_key_type(int key_type) {
    switch (key_type) {
        case LIBSSH2_HOSTKEY_TYPE_RSA: return "ssh-rsa";
        case LIBSSH2_HOSTKEY_TYPE_DSS: return "ssh-dss";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return "ecdsa-sha2-nistp256";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return "ecdsa-sha2-nistp384";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return "ecdsa-sha2-nistp521";
        case LIBSSH2_HOSTKEY_TYPE_ED25519: return "ssh-ed25519";
        default: return NULL;
    }
}

static int check_host_key(
    LIBSSH2_SESSION *session,
    const char *host,
    int port,
    const char *known_hosts_path,
    const char *key,
    size_t key_length,
    int key_type,
    int *trust_status,
    char *error,
    size_t error_len
) {
    LIBSSH2_KNOWNHOSTS *known_hosts = libssh2_knownhost_init(session);
    if (!known_hosts) {
        set_error(error, error_len, "Could not initialize host key verification.");
        return -1;
    }

    int read_result = libssh2_knownhost_readfile(known_hosts, known_hosts_path, LIBSSH2_KNOWNHOST_FILE_OPENSSH);
    if (read_result < 0) {
        libssh2_knownhost_free(known_hosts);
        set_error(error, error_len, "Could not read Volt known_hosts.");
        return -1;
    }

    struct libssh2_knownhost *matched = NULL;
    int type_mask = LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW | known_host_key_type(key_type);
    int check = libssh2_knownhost_checkp(known_hosts, host, port, key, key_length, type_mask, &matched);
    libssh2_knownhost_free(known_hosts);

    switch (check) {
        case LIBSSH2_KNOWNHOST_CHECK_MATCH:
            *trust_status = VOLT_HOSTKEY_MATCH;
            return 0;
        case LIBSSH2_KNOWNHOST_CHECK_MISMATCH:
            *trust_status = VOLT_HOSTKEY_MISMATCH;
            return 0;
        case LIBSSH2_KNOWNHOST_CHECK_NOTFOUND:
            *trust_status = VOLT_HOSTKEY_UNKNOWN;
            return 0;
        default:
            set_error(error, error_len, "Could not verify the SSH host key.");
            return -1;
    }
}

static int verify_host_key(LIBSSH2_SESSION *session, const char *host, int port, const char *known_hosts_path, char *error, size_t error_len) {
    if (!known_hosts_path || !known_hosts_path[0]) {
        set_error(error, error_len, "Host key store is unavailable.");
        return -1;
    }

    size_t key_length = 0;
    int key_type = LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
    const char *key = libssh2_session_hostkey(session, &key_length, &key_type);
    if (!key || key_length == 0) {
        set_error(error, error_len, "The SSH server did not provide a host key.");
        return -1;
    }

    int trust_status = VOLT_HOSTKEY_UNKNOWN;
    if (check_host_key(session, host, port, known_hosts_path, key, key_length, key_type, &trust_status, error, error_len) != 0) {
        return -1;
    }
    if (trust_status != VOLT_HOSTKEY_MATCH) {
        set_error(error, error_len, trust_status == VOLT_HOSTKEY_MISMATCH
            ? "SSH host key mismatch. The connection was rejected."
            : "SSH host key is not trusted by Volt. The connection was rejected.");
        return -1;
    }
    return 0;
}

int volt_ssh_probe_host_key(const char *host, int port, const char *known_hosts_path, unsigned char **key, size_t *key_len, int *key_type, int *trust_status, char *error, size_t error_len) {
    if (!key || !key_len || !key_type || !trust_status || !known_hosts_path) {
        set_error(error, error_len, "Invalid host key probe request.");
        return -1;
    }
    *key = NULL;
    *key_len = 0;
    *key_type = LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
    *trust_status = VOLT_HOSTKEY_UNKNOWN;

    pthread_once(&libssh2_once, initialize_libssh2);
    if (libssh2_init_result != 0) {
        set_error(error, error_len, "libssh2 initialization failed.");
        return -1;
    }

    int sock = connect_socket(host, port, error, error_len);
    if (sock < 0) return -1;

    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) {
        close(sock);
        set_error(error, error_len, "Could not create SSH probe session.");
        return -1;
    }
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, volt_timeout_seconds * 1000L);

    if (libssh2_session_handshake(session, sock) != 0) {
        set_session_error(session, error, error_len, "SSH host key probe timed out or failed.");
        libssh2_session_free(session);
        close(sock);
        return -1;
    }

    size_t session_key_len = 0;
    int session_key_type = LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
    const char *session_key = libssh2_session_hostkey(session, &session_key_len, &session_key_type);
    if (!session_key || session_key_len == 0 || known_host_key_type(session_key_type) == LIBSSH2_KNOWNHOST_KEY_UNKNOWN) {
        set_error(error, error_len, "The SSH server presented an unsupported host key.");
        libssh2_session_disconnect(session, "Host key probe failed");
        libssh2_session_free(session);
        close(sock);
        return -1;
    }

    if (check_host_key(session, host, port, known_hosts_path, session_key, session_key_len, session_key_type, trust_status, error, error_len) != 0) {
        libssh2_session_disconnect(session, "Host key probe failed");
        libssh2_session_free(session);
        close(sock);
        return -1;
    }

    unsigned char *copy = malloc(session_key_len);
    if (!copy) {
        set_error(error, error_len, "Out of memory while reading the SSH host key.");
        libssh2_session_disconnect(session, "Host key probe failed");
        libssh2_session_free(session);
        close(sock);
        return -1;
    }
    memcpy(copy, session_key, session_key_len);
    *key = copy;
    *key_len = session_key_len;
    *key_type = session_key_type;

    libssh2_session_disconnect(session, "Host key probe complete");
    libssh2_session_free(session);
    close(sock);
    return 0;
}

static int fsync_parent_directory(const char *path) {
    char directory[4096];
    snprintf(directory, sizeof(directory), "%s", path);
    char *separator = strrchr(directory, '/');
    if (!separator) return 0;
    if (separator == directory) separator[1] = '\0';
    else *separator = '\0';
    int fd = open(directory, O_RDONLY);
    if (fd < 0) return -1;
    int result = fsync(fd);
    close(fd);
    return result;
}

int volt_ssh_commit_host_key(const char *host, int port, const char *known_hosts_path, const unsigned char *key, size_t key_len, int key_type, char *error, size_t error_len) {
    if (!host || !known_hosts_path || !key || key_len == 0 || known_host_key_type(key_type) == LIBSSH2_KNOWNHOST_KEY_UNKNOWN) {
        set_error(error, error_len, "Invalid host key commit request.");
        return -1;
    }

    pthread_once(&libssh2_once, initialize_libssh2);
    if (libssh2_init_result != 0) {
        set_error(error, error_len, "libssh2 initialization failed.");
        return -1;
    }

    int result = -1;
    int lock_fd = -1;
    LIBSSH2_SESSION *session = NULL;
    LIBSSH2_KNOWNHOSTS *known_hosts = NULL;
    char lock_path[4096];
    char temp_path[4096];
    temp_path[0] = '\0';

    pthread_mutex_lock(&known_hosts_mutex);
    if (snprintf(lock_path, sizeof(lock_path), "%s.lock", known_hosts_path) >= (int)sizeof(lock_path)) {
        set_error(error, error_len, "Host key path is too long.");
        goto cleanup;
    }
    lock_fd = open(lock_path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
    if (lock_fd < 0 || flock(lock_fd, LOCK_EX) != 0) {
        set_error(error, error_len, "Could not lock Volt known_hosts.");
        goto cleanup;
    }
    fchmod(lock_fd, S_IRUSR | S_IWUSR);

    session = libssh2_session_init();
    if (!session) {
        set_error(error, error_len, "Could not initialize host key storage.");
        goto cleanup;
    }
    known_hosts = libssh2_knownhost_init(session);
    if (!known_hosts) {
        set_error(error, error_len, "Could not initialize host key storage.");
        goto cleanup;
    }
    if (libssh2_knownhost_readfile(known_hosts, known_hosts_path, LIBSSH2_KNOWNHOST_FILE_OPENSSH) < 0) {
        set_error(error, error_len, "Could not read Volt known_hosts.");
        goto cleanup;
    }

    struct libssh2_knownhost *matched = NULL;
    int type_mask = LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW | known_host_key_type(key_type);
    int existing = libssh2_knownhost_checkp(known_hosts, host, port, (const char *)key, key_len, type_mask, &matched);
    if (existing == LIBSSH2_KNOWNHOST_CHECK_MISMATCH) {
        set_error(error, error_len, "A different host key is already trusted for this server.");
        goto cleanup;
    }
    if (existing != LIBSSH2_KNOWNHOST_CHECK_MATCH) {
        char host_field[1024];
        int host_length = port == 22
            ? snprintf(host_field, sizeof(host_field), "%s", host)
            : snprintf(host_field, sizeof(host_field), "[%s]:%d", host, port);
        if (host_length < 0 || host_length >= (int)sizeof(host_field)) {
            set_error(error, error_len, "SSH host name is too long.");
            goto cleanup;
        }
        if (libssh2_knownhost_addc(known_hosts, host_field, NULL, (const char *)key, key_len, "Volt", 4, type_mask, NULL) != 0) {
            set_error(error, error_len, "Could not add the SSH host key.");
            goto cleanup;
        }
    }

    if (snprintf(temp_path, sizeof(temp_path), "%s.tmp.XXXXXX", known_hosts_path) >= (int)sizeof(temp_path)) {
        set_error(error, error_len, "Host key path is too long.");
        goto cleanup;
    }
    int temp_fd = mkstemp(temp_path);
    if (temp_fd < 0) {
        set_error(error, error_len, "Could not create a temporary host key file.");
        goto cleanup;
    }
    close(temp_fd);
    if (libssh2_knownhost_writefile(known_hosts, temp_path, LIBSSH2_KNOWNHOST_FILE_OPENSSH) != 0 || chmod(temp_path, S_IRUSR | S_IWUSR) != 0) {
        set_error(error, error_len, "Could not write Volt known_hosts.");
        goto cleanup;
    }
    temp_fd = open(temp_path, O_RDONLY);
    if (temp_fd < 0 || fsync(temp_fd) != 0) {
        if (temp_fd >= 0) close(temp_fd);
        set_error(error, error_len, "Could not finalize Volt known_hosts.");
        goto cleanup;
    }
    close(temp_fd);
    if (rename(temp_path, known_hosts_path) != 0 || fsync_parent_directory(known_hosts_path) != 0) {
        set_error(error, error_len, "Could not atomically update Volt known_hosts.");
        goto cleanup;
    }
    temp_path[0] = '\0';
    result = 0;

cleanup:
    if (temp_path[0]) unlink(temp_path);
    if (known_hosts) libssh2_knownhost_free(known_hosts);
    if (session) libssh2_session_free(session);
    if (lock_fd >= 0) {
        flock(lock_fd, LOCK_UN);
        close(lock_fd);
    }
    pthread_mutex_unlock(&known_hosts_mutex);
    return result;
}

void volt_ssh_free_buffer(void *buffer) {
    free(buffer);
}

void volt_secure_zero(void *buffer, size_t length) {
    volatile unsigned char *bytes = (volatile unsigned char *)buffer;
    while (length-- > 0) *bytes++ = 0;
}

int volt_publish_download(const char *temporary_path, const char *destination_path, int overwrite) {
    if (!temporary_path || !destination_path) {
        errno = EINVAL;
        return -1;
    }
    return overwrite ? rename(temporary_path, destination_path) : renamex_np(temporary_path, destination_path, RENAME_EXCL);
}

static int open_session(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, VoltSession *out, char *error, size_t error_len) {
    memset(out, 0, sizeof(*out));
    out->sock = -1;

    pthread_once(&libssh2_once, initialize_libssh2);
    if (libssh2_init_result != 0) {
        set_error(error, error_len, "libssh2 initialization failed.");
        return -1;
    }

    int sock = connect_socket(host, port, error, error_len);
    if (sock < 0) return -1;

    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) {
        close(sock);
        set_error(error, error_len, "Could not create SSH session.");
        return -1;
    }
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, volt_timeout_seconds * 1000L);

    if (libssh2_session_handshake(session, sock) != 0) {
        set_session_error(session, error, error_len, "SSH handshake failed.");
        libssh2_session_free(session);
        close(sock);
        return -1;
    }

    if (verify_host_key(session, host, port, known_hosts_path, error, error_len) != 0) {
        libssh2_session_disconnect(session, "Host key verification failed");
        libssh2_session_free(session);
        close(sock);
        return -1;
    }

    int auth_rc = -1;
    if (private_key_path && private_key_path[0]) {
        auth_rc = libssh2_userauth_publickey_fromfile(session, username, NULL, private_key_path, (password && password[0]) ? password : NULL);
        if (auth_rc != 0) set_session_error(session, error, error_len, "Private key authentication failed.");
    } else if (password && password[0]) {
        auth_rc = libssh2_userauth_password(session, username, password);
        if (auth_rc != 0) set_session_error(session, error, error_len, "Password authentication failed.");
    } else {
        auth_rc = auth_with_agent(session, username, error, error_len);
    }

    if (auth_rc != 0) {
        libssh2_session_disconnect(session, "Authentication failed");
        libssh2_session_free(session);
        close(sock);
        return -1;
    }

    LIBSSH2_SFTP *sftp = libssh2_sftp_init(session);
    if (!sftp) {
        set_session_error(session, error, error_len, "Could not start SFTP subsystem.");
        libssh2_session_disconnect(session, "SFTP failed");
        libssh2_session_free(session);
        close(sock);
        return -1;
    }

    out->sock = sock;
    out->session = session;
    out->sftp = sftp;
    return 0;
}

static void close_session(VoltSession *session) {
    if (session->sftp) libssh2_sftp_shutdown(session->sftp);
    if (session->session) {
        libssh2_session_disconnect(session->session, "Normal Shutdown");
        libssh2_session_free(session->session);
    }
    if (session->sock >= 0) close(session->sock);
}

static int join_path(const char *base, const char *name, char *out, size_t out_len) {
    int length = strcmp(base, "/") == 0
        ? snprintf(out, out_len, "/%s", name)
        : snprintf(out, out_len, "%s/%s", base, name);
    return length >= 0 && (size_t)length < out_len ? 0 : -1;
}

// Từ chối tên entry của directory listing không an toàn để dùng như một path component cục bộ.
// Quét từng byte trong [0, len) dưới dạng unsigned (tránh signed char làm byte >= 0x80 thành âm và
// vô tình thỏa `< 0x20`). Định nghĩa byte nguy hiểm tường minh, không dùng iscntrl() (tùy locale,
// UB với byte >= 0x80). Byte >= 0x80 được giữ nguyên để tên UTF-8 multibyte đi qua.
int volt_is_safe_entry_name(const char *name, size_t len) {
    if (name == NULL || len == 0) return 0;
    const unsigned char *bytes = (const unsigned char *)name;
    for (size_t i = 0; i < len; i++) {
        if (bytes[i] == 0 || bytes[i] == '/' || bytes[i] < 0x20 || bytes[i] == 0x7f) return 0;
    }
    return 1;
}

int volt_sftp_list(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *remote_path, VoltSFTPItem **items, int *count, int *skipped_unsafe_count, char *error, size_t error_len) {
    *items = NULL;
    *count = 0;
    *skipped_unsafe_count = 0;
    VoltSession session;
    if (open_session(host, port, username, password, private_key_path, known_hosts_path, &session, error, error_len) != 0) return -1;

    LIBSSH2_SFTP_HANDLE *dir = libssh2_sftp_opendir(session.sftp, remote_path);
    if (!dir) {
        set_session_error(session.session, error, error_len, "Could not open remote directory.");
        close_session(&session);
        return -1;
    }

    int capacity = 64;
    int used = 0;
    VoltSFTPItem *list = calloc((size_t)capacity, sizeof(VoltSFTPItem));
    if (!list) {
        libssh2_sftp_closedir(dir);
        close_session(&session);
        set_error(error, error_len, "Out of memory.");
        return -1;
    }

    char name[1024];
    LIBSSH2_SFTP_ATTRIBUTES attrs;
    while (1) {
        memset(&attrs, 0, sizeof(attrs));
        int rc = libssh2_sftp_readdir_ex(dir, name, sizeof(name) - 1, NULL, 0, &attrs);
        if (rc > 0) {
            // Thứ tự bắt buộc: validator quét theo `rc` (không cần NUL) chạy TRƯỚC khi NUL-terminate;
            // strcmp `.`/`..` cần NUL nên chạy SAU. Embedded NUL bị chính validator bắt ở đây.
            if (!volt_is_safe_entry_name(name, (size_t)rc)) {
                (*skipped_unsafe_count)++;
                continue; // Bỏ RIÊNG entry độc hại, vẫn tiếp tục listing → chống DoS.
            }
            name[rc] = '\0'; // An toàn: readdir_ex gọi với sizeof(name) - 1 nên rc < sizeof(name).
            if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue; // Silent-skip, KHÔNG đếm.
            if (used == capacity) {
                capacity *= 2;
                VoltSFTPItem *grown = realloc(list, (size_t)capacity * sizeof(VoltSFTPItem));
                if (!grown) {
                    free(list);
                    libssh2_sftp_closedir(dir);
                    close_session(&session);
                    set_error(error, error_len, "Out of memory.");
                    return -1;
                }
                list = grown;
            }
            memset(&list[used], 0, sizeof(VoltSFTPItem));
            snprintf(list[used].name, sizeof(list[used].name), "%s", name);
            if (join_path(remote_path, name, list[used].path, sizeof(list[used].path)) != 0) {
                free(list);
                libssh2_sftp_closedir(dir);
                close_session(&session);
                set_error(error, error_len, "Remote path exceeds Volt's safety limit.");
                return -1;
            }
            list[used].is_directory = (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) && LIBSSH2_SFTP_S_ISDIR(attrs.permissions);
            list[used].size = (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE) ? (int64_t)attrs.filesize : -1;
            list[used].modified = (attrs.flags & LIBSSH2_SFTP_ATTR_ACMODTIME) ? (int64_t)attrs.mtime : 0;
            list[used].permissions = (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) ? attrs.permissions : 0;
            list[used].uid = (attrs.flags & LIBSSH2_SFTP_ATTR_UIDGID) ? attrs.uid : 0;
            list[used].gid = (attrs.flags & LIBSSH2_SFTP_ATTR_UIDGID) ? attrs.gid : 0;
            used++;
        } else if (rc == 0) {
            break;
        } else {
            free(list);
            libssh2_sftp_closedir(dir);
            close_session(&session);
            set_error(error, error_len, "Could not read remote directory.");
            return -1;
        }
    }

    libssh2_sftp_closedir(dir);
    close_session(&session);
    *items = list;
    *count = used;
    return 0;
}

int volt_sftp_upload(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *local_path, const char *remote_path, uint32_t mode, VoltSFTPProgressCallback progress, void *progress_context, char *error, size_t error_len) {
    VoltSession session;
    if (open_session(host, port, username, password, private_key_path, known_hosts_path, &session, error, error_len) != 0) return -1;
    FILE *input = fopen(local_path, "rb");
    if (!input) {
        set_error(error, error_len, strerror(errno));
        close_session(&session);
        return -1;
    }
    struct stat input_stat;
    uint64_t total_size = fstat(fileno(input), &input_stat) == 0 && input_stat.st_size > 0
        ? (uint64_t)input_stat.st_size
        : 0;
    uint64_t transferred = 0;
    char temp_path[4096];
    int temp_path_length = snprintf(temp_path, sizeof(temp_path), "%s.volt-part-%ld-%08x", remote_path, (long)getpid(), arc4random());
    if (temp_path_length < 0 || (size_t)temp_path_length >= sizeof(temp_path)) {
        fclose(input);
        set_error(error, error_len, "Remote upload path is too long.");
        close_session(&session);
        return -1;
    }
    mode_t safe_mode = (mode_t)(mode & 0777U);
    LIBSSH2_SFTP_HANDLE *file = libssh2_sftp_open(
        session.sftp,
        temp_path,
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC | LIBSSH2_FXF_EXCL,
        safe_mode
    );
    if (!file) {
        fclose(input);
        set_session_error(session.session, error, error_len, "Could not create temporary remote upload file.");
        close_session(&session);
        return -1;
    }
    char buffer[VOLT_SFTP_TRANSFER_BUFFER_SIZE];
    size_t n;
    while ((n = fread(buffer, 1, sizeof(buffer), input)) > 0) {
        char *ptr = buffer;
        size_t left = n;
        while (left > 0) {
            ssize_t written = libssh2_sftp_write(file, ptr, left);
            if (written <= 0) {
                libssh2_sftp_close(file);
                libssh2_sftp_unlink(session.sftp, temp_path);
                fclose(input);
                set_session_error(session.session, error, error_len, "SFTP write failed.");
                close_session(&session);
                return -1;
            }
            ptr += written;
            left -= (size_t)written;
        }
        transferred += (uint64_t)n;
        if (progress && progress(transferred, total_size, progress_context) != 0) {
            libssh2_sftp_close(file);
            libssh2_sftp_unlink(session.sftp, temp_path);
            fclose(input);
            set_error(error, error_len, "Transfer cancelled.");
            close_session(&session);
            return -1;
        }
    }
    if (ferror(input)) {
        libssh2_sftp_close(file);
        libssh2_sftp_unlink(session.sftp, temp_path);
        fclose(input);
        set_error(error, error_len, "Could not read the local upload file.");
        close_session(&session);
        return -1;
    }
    LIBSSH2_SFTP_ATTRIBUTES permission_attrs;
    memset(&permission_attrs, 0, sizeof(permission_attrs));
    permission_attrs.flags = LIBSSH2_SFTP_ATTR_PERMISSIONS;
    permission_attrs.permissions = safe_mode;
    int permission_result = libssh2_sftp_fsetstat(file, &permission_attrs);
    int close_result = libssh2_sftp_close(file);
    fclose(input);
    if (close_result != 0) {
        libssh2_sftp_unlink(session.sftp, temp_path);
        set_session_error(session.session, error, error_len, "Could not finalize temporary remote upload file.");
        close_session(&session);
        return -1;
    }

    long rename_flags = LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC | LIBSSH2_SFTP_RENAME_NATIVE;
    int rename_result = libssh2_sftp_rename_ex(
        session.sftp,
        temp_path,
        (unsigned int)strlen(temp_path),
        remote_path,
        (unsigned int)strlen(remote_path),
        rename_flags
    );
    if (rename_result != 0) {
        rename_result = libssh2_sftp_rename_ex(
            session.sftp,
            temp_path,
            (unsigned int)strlen(temp_path),
            remote_path,
            (unsigned int)strlen(remote_path),
            LIBSSH2_SFTP_RENAME_OVERWRITE
        );
    }
    if (rename_result != 0) {
        libssh2_sftp_unlink(session.sftp, temp_path);
        set_session_error(session.session, error, error_len, "Could not publish completed remote upload.");
        close_session(&session);
        return -1;
    }
    close_session(&session);
    if (permission_result != 0) {
        set_error(error, error_len, "Uploaded, but could not apply requested permissions.");
        return VOLT_SFTP_PERMISSION_WARNING;
    }
    return 0;
}

int volt_sftp_download(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *remote_path, const char *local_path, int overwrite, VoltSFTPProgressCallback progress, void *progress_context, char *error, size_t error_len) {
    VoltSession session;
    if (open_session(host, port, username, password, private_key_path, known_hosts_path, &session, error, error_len) != 0) return -1;
    LIBSSH2_SFTP_HANDLE *file = libssh2_sftp_open(session.sftp, remote_path, LIBSSH2_FXF_READ, 0);
    if (!file) {
        set_session_error(session.session, error, error_len, "Could not open remote file for reading.");
        close_session(&session);
        return -1;
    }
    LIBSSH2_SFTP_ATTRIBUTES remote_attrs;
    memset(&remote_attrs, 0, sizeof(remote_attrs));
    uint64_t total_size = libssh2_sftp_fstat(file, &remote_attrs) == 0 && (remote_attrs.flags & LIBSSH2_SFTP_ATTR_SIZE)
        ? (uint64_t)remote_attrs.filesize
        : 0;
    uint64_t transferred = 0;
    char temp_path[4096];
    int temp_path_length = snprintf(temp_path, sizeof(temp_path), "%s.volt-part.XXXXXX", local_path);
    if (temp_path_length < 0 || (size_t)temp_path_length >= sizeof(temp_path)) {
        libssh2_sftp_close(file);
        set_error(error, error_len, "Local download path is too long.");
        close_session(&session);
        return -1;
    }
    int output_fd = mkstemp(temp_path);
    FILE *output = output_fd >= 0 ? fdopen(output_fd, "wb") : NULL;
    if (!output) {
        if (output_fd >= 0) close(output_fd);
        unlink(temp_path);
        libssh2_sftp_close(file);
        set_error(error, error_len, strerror(errno));
        close_session(&session);
        return -1;
    }
    if (fchmod(output_fd, S_IRUSR | S_IWUSR) != 0) {
        fclose(output);
        unlink(temp_path);
        libssh2_sftp_close(file);
        set_error(error, error_len, "Could not secure the downloaded file permissions.");
        close_session(&session);
        return -1;
    }
    char buffer[VOLT_SFTP_TRANSFER_BUFFER_SIZE];
    while (1) {
        ssize_t n = libssh2_sftp_read(file, buffer, sizeof(buffer));
        if (n > 0) {
            if (fwrite(buffer, 1, (size_t)n, output) != (size_t)n) {
                fclose(output);
                unlink(temp_path);
                libssh2_sftp_close(file);
                set_error(error, error_len, "Could not write the downloaded file.");
                close_session(&session);
                return -1;
            }
            transferred += (uint64_t)n;
            if (progress && progress(transferred, total_size, progress_context) != 0) {
                fclose(output);
                unlink(temp_path);
                libssh2_sftp_close(file);
                set_error(error, error_len, "Transfer cancelled.");
                close_session(&session);
                return -1;
            }
        }
        else if (n == 0) break;
        else {
            fclose(output);
            unlink(temp_path);
            libssh2_sftp_close(file);
            set_session_error(session.session, error, error_len, "SFTP read failed.");
            close_session(&session);
            return -1;
        }
    }
    int flush_result = fflush(output);
    int output_close_result = fclose(output);
    if (flush_result != 0 || output_close_result != 0) {
        unlink(temp_path);
        libssh2_sftp_close(file);
        set_error(error, error_len, "Could not finalize the downloaded file.");
        close_session(&session);
        return -1;
    }
    int publish_result = volt_publish_download(temp_path, local_path, overwrite);
    if (publish_result != 0) {
        unlink(temp_path);
        libssh2_sftp_close(file);
        set_error(error, error_len, strerror(errno));
        close_session(&session);
        return -1;
    }
    libssh2_sftp_close(file);
    close_session(&session);
    return 0;
}

int volt_sftp_mkdir(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *remote_path, uint32_t mode, char *error, size_t error_len) {
    VoltSession session;
    if (open_session(host, port, username, password, private_key_path, known_hosts_path, &session, error, error_len) != 0) return -1;
    mode_t safe_mode = (mode_t)(mode & 0777U);
    int rc = libssh2_sftp_mkdir(session.sftp, remote_path, safe_mode);
    if (rc != 0) set_session_error(session.session, error, error_len, "Could not create remote directory.");
    int permission_result = 0;
    if (rc == 0) {
        LIBSSH2_SFTP_ATTRIBUTES attrs;
        memset(&attrs, 0, sizeof(attrs));
        attrs.flags = LIBSSH2_SFTP_ATTR_PERMISSIONS;
        attrs.permissions = safe_mode;
        permission_result = libssh2_sftp_setstat(session.sftp, remote_path, &attrs);
    }
    close_session(&session);
    if (rc != 0) return -1;
    if (permission_result != 0) {
        set_error(error, error_len, "Folder created, but could not apply requested permissions.");
        return VOLT_SFTP_PERMISSION_WARNING;
    }
    return 0;
}

int volt_sftp_create_empty_file(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *remote_path, uint32_t mode, char *error, size_t error_len) {
    VoltSession session;
    if (open_session(host, port, username, password, private_key_path, known_hosts_path, &session, error, error_len) != 0) return -1;
    mode_t safe_mode = (mode_t)(mode & 0777U);
    LIBSSH2_SFTP_HANDLE *file = libssh2_sftp_open(session.sftp, remote_path, LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC, safe_mode);
    if (!file) {
        set_session_error(session.session, error, error_len, "Could not create remote file.");
        close_session(&session);
        return -1;
    }
    LIBSSH2_SFTP_ATTRIBUTES attrs;
    memset(&attrs, 0, sizeof(attrs));
    attrs.flags = LIBSSH2_SFTP_ATTR_PERMISSIONS;
    attrs.permissions = safe_mode;
    int permission_result = libssh2_sftp_fsetstat(file, &attrs);
    libssh2_sftp_close(file);
    close_session(&session);
    if (permission_result != 0) {
        set_error(error, error_len, "File created, but could not apply requested permissions.");
        return VOLT_SFTP_PERMISSION_WARNING;
    }
    return 0;
}

int volt_sftp_rename(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *from_path, const char *to_path, char *error, size_t error_len) {
    VoltSession session;
    if (open_session(host, port, username, password, private_key_path, known_hosts_path, &session, error, error_len) != 0) return -1;
    int rc = libssh2_sftp_rename(session.sftp, from_path, to_path);
    if (rc != 0) set_session_error(session.session, error, error_len, "Could not rename remote item.");
    close_session(&session);
    return rc == 0 ? 0 : -1;
}

int volt_sftp_remove(const char *host, int port, const char *username, const char *password, const char *private_key_path, const char *known_hosts_path, const char *remote_path, int is_directory, char *error, size_t error_len) {
    VoltSession session;
    if (open_session(host, port, username, password, private_key_path, known_hosts_path, &session, error, error_len) != 0) return -1;
    int rc = is_directory ? libssh2_sftp_rmdir(session.sftp, remote_path) : libssh2_sftp_unlink(session.sftp, remote_path);
    if (rc != 0) set_session_error(session.session, error, error_len, "Could not remove remote item.");
    close_session(&session);
    return rc == 0 ? 0 : -1;
}

void volt_sftp_free_items(VoltSFTPItem *items) {
    free(items);
}

const char *volt_sftp_item_name(const VoltSFTPItem *items, int index) {
    return items[index].name;
}

const char *volt_sftp_item_path(const VoltSFTPItem *items, int index) {
    return items[index].path;
}

int volt_sftp_item_is_directory(const VoltSFTPItem *items, int index) {
    return items[index].is_directory;
}

int64_t volt_sftp_item_size(const VoltSFTPItem *items, int index) {
    return items[index].size;
}

int64_t volt_sftp_item_modified(const VoltSFTPItem *items, int index) {
    return items[index].modified;
}

uint32_t volt_sftp_item_permissions(const VoltSFTPItem *items, int index) {
    return items[index].permissions;
}

uint32_t volt_sftp_item_uid(const VoltSFTPItem *items, int index) {
    return items[index].uid;
}

uint32_t volt_sftp_item_gid(const VoltSFTPItem *items, int index) {
    return items[index].gid;
}
