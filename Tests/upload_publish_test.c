/* Exercise the real upload implementation with scripted SFTP replies. No SSH
 * server or user credentials are used. */
#include <assert.h>
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static LIBSSH2_SFTP_HANDLE *fake_open(LIBSSH2_SFTP *, const char *, unsigned int, unsigned long, long, int);
static ssize_t fake_write(LIBSSH2_SFTP_HANDLE *, const char *, size_t);
static int fake_close(LIBSSH2_SFTP_HANDLE *);
static int fake_stat(LIBSSH2_SFTP_HANDLE *, LIBSSH2_SFTP_ATTRIBUTES *, int);
static int fake_rename(LIBSSH2_SFTP *, const char *, unsigned int, const char *, unsigned int, long);
static int fake_posix_rename(LIBSSH2_SFTP *, const char *, size_t, const char *, size_t);
static int fake_unlink(LIBSSH2_SFTP *, const char *, unsigned int);
static int fake_last_errno(LIBSSH2_SESSION *session);
static unsigned long fake_sftp_last_error(LIBSSH2_SFTP *sftp);
#define libssh2_session_last_errno fake_last_errno
#define libssh2_sftp_last_error fake_sftp_last_error
#define libssh2_sftp_open_ex fake_open
#define libssh2_sftp_write fake_write
#define libssh2_sftp_close_handle fake_close
#define libssh2_sftp_fstat_ex fake_stat
#define libssh2_sftp_rename_ex fake_rename
#define libssh2_sftp_posix_rename_ex fake_posix_rename
#define libssh2_sftp_unlink_ex fake_unlink
#include "../Sources/CVoltSSH/VoltSSH.c"

static char temporary[4096], staged[128], destination[128];
static int rename_reply, rename_calls, cleanup_calls, posix_calls;
static int permission_reply, fail_write, fail_close, cancel_before_publish;
static int progress_calls, file_closed;
static int fake_last_errno(LIBSSH2_SESSION *session) {
    (void)session;
    return (rename_reply == LIBSSH2_ERROR_SFTP_PROTOCOL || fail_write || fail_close) ? LIBSSH2_ERROR_SFTP_PROTOCOL : rename_reply;
}
static unsigned long fake_sftp_last_error(LIBSSH2_SFTP *sftp) {
    (void)sftp;
    // Cleanup overwrites the server status; the caller must capture it first.
    return cleanup_calls ? LIBSSH2_FX_OK : LIBSSH2_FX_PERMISSION_DENIED;
}

static void reset(void) {
    temporary[0] = staged[0] = '\0';
    strcpy(destination, "old contents");
    rename_reply = rename_calls = cleanup_calls = posix_calls = 0;
    permission_reply = fail_write = fail_close = cancel_before_publish = progress_calls = file_closed = 0;
}

static LIBSSH2_SFTP_HANDLE *fake_open(LIBSSH2_SFTP *sftp, const char *path, unsigned int length,
                                      unsigned long flags, long mode, int type) {
    (void)sftp; (void)mode; (void)type;
    assert(length < sizeof(temporary));
    assert(strstr(path, "/destination.volt-part-") == path);
    assert(flags & LIBSSH2_FXF_EXCL);
    strcpy(temporary, path);
    return (LIBSSH2_SFTP_HANDLE *)&temporary;
}

static ssize_t fake_write(LIBSSH2_SFTP_HANDLE *handle, const char *data, size_t length) {
    (void)handle;
    if (fail_write) return -1;
    assert(strlen(staged) + length < sizeof(staged));
    strncat(staged, data, length);
    return (ssize_t)length;
}

static int fake_close(LIBSSH2_SFTP_HANDLE *handle) { (void)handle; file_closed = 1; return fail_close ? -1 : 0; }
static int fake_stat(LIBSSH2_SFTP_HANDLE *handle, LIBSSH2_SFTP_ATTRIBUTES *attrs, int setstat) {
    (void)handle; (void)attrs; assert(setstat); return permission_reply;
}

static int publish(const char *source, const char *target) {
    assert(strcmp(source, temporary) == 0);
    assert(strcmp(target, "/destination") == 0);
    rename_calls++;
    if (rename_reply == 0) strcpy(destination, staged);
    return rename_reply;
}

static int fake_rename(LIBSSH2_SFTP *sftp, const char *source, unsigned int slen,
                       const char *target, unsigned int tlen, long flags) {
    (void)sftp; (void)slen; (void)tlen;
    assert(flags == 0); // create-new must never request overwrite
    return publish(source, target);
}

static int fake_posix_rename(LIBSSH2_SFTP *sftp, const char *source, size_t slen,
                             const char *target, size_t tlen) {
    (void)sftp; (void)slen; (void)tlen;
    posix_calls++;
    return publish(source, target);
}

static int fake_unlink(LIBSSH2_SFTP *sftp, const char *path, unsigned int length) {
    (void)sftp; (void)length;
    assert(strcmp(path, "/destination") != 0);
    assert(strcmp(path, temporary) == 0);
    cleanup_calls++;
    return 0;
}

static int progress(uint64_t transferred, uint64_t total, void *context) {
    (void)transferred; (void)total; (void)context;
    progress_calls++;
    // Cancellation after transfer bytes, before the destination is published.
    return cancel_before_publish && file_closed;
}

int main(void) {
    char local[] = "/tmp/volt-upload-test.XXXXXX";
    int fd = mkstemp(local);
    assert(fd >= 0);
    assert(write(fd, "new contents", 12) == 12);
    close(fd);
    VoltSessionHandle session = { .session = { .sock = -1, .session = NULL, .sftp = NULL } };
    char error[4096];

    for (int overwrite = 0; overwrite <= 1; overwrite++) {
        reset();
        assert(volt_sftp_upload_on(&session, local, "/destination", 0600, overwrite,
                                  progress, NULL, error, sizeof(error)) == 0);
        assert(strcmp(destination, "new contents") == 0);
        assert(rename_calls == 1 && posix_calls == overwrite && cleanup_calls == 0);
    }
    const int rejections[] = { LIBSSH2_ERROR_SFTP_PROTOCOL, LIBSSH2_ERROR_METHOD_NOT_SUPPORTED };
    for (size_t i = 0; i < sizeof(rejections) / sizeof(rejections[0]); i++) {
        reset(); rename_reply = rejections[i];
        assert(volt_sftp_upload_on(&session, local, "/destination", 0600, 1,
                                  progress, NULL, error, sizeof(error)) < 0);
        assert(strcmp(destination, "old contents") == 0);
        assert(rename_calls == 1 && cleanup_calls == 1);
        if (rejections[i] == LIBSSH2_ERROR_SFTP_PROTOCOL) assert(strstr(error, "Permission denied"));
        assert(strstr(error, "not removed"));
    }
    reset(); rename_reply = LIBSSH2_ERROR_SOCKET_RECV;
    assert(volt_sftp_upload_on(&session, local, "/destination", 0600, 1,
                              progress, NULL, error, sizeof(error)) < 0);
    assert(rename_calls == 1 && cleanup_calls == 0);
    assert(strstr(error, "unknown") && strstr(error, temporary));

    reset(); cancel_before_publish = 1;
    assert(volt_sftp_upload_on(&session, local, "/destination", 0600, 1,
                              progress, NULL, error, sizeof(error)) < 0);
    assert(rename_calls == 0 && cleanup_calls == 1);
    assert(strcmp(destination, "old contents") == 0);

    reset(); permission_reply = -1;
    assert(volt_sftp_upload_on(&session, local, "/destination", 0600, 1,
                              progress, NULL, error, sizeof(error)) == VOLT_SFTP_PERMISSION_WARNING);
    assert(strcmp(destination, "new contents") == 0);

    reset(); fail_write = 1;
    assert(volt_sftp_upload_on(&session, local, "/destination", 0600, 1,
                              progress, NULL, error, sizeof(error)) < 0);
    assert(rename_calls == 0 && strcmp(destination, "old contents") == 0);
    reset(); fail_close = 1;
    assert(volt_sftp_upload_on(&session, local, "/destination", 0600, 1,
                              progress, NULL, error, sizeof(error)) < 0);
    assert(rename_calls == 0 && strcmp(destination, "old contents") == 0);
    unlink(local);
    puts("Upload publish fault-injection tests passed.");
    return 0;
}
