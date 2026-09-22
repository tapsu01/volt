#ifndef VOLT_SFTP_ERROR_H
#define VOLT_SFTP_ERROR_H
#include <stdio.h>
#include <libssh2_sftp.h>

static inline const char *volt_sftp_status_description(unsigned long status) {
    switch (status) {
        case LIBSSH2_FX_PERMISSION_DENIED: return "Permission denied";
        case LIBSSH2_FX_NO_SUCH_FILE: return "No such file or directory";
        case LIBSSH2_FX_OP_UNSUPPORTED: return "Operation unsupported by server";
        case LIBSSH2_FX_NO_CONNECTION: return "No connection";
        case LIBSSH2_FX_CONNECTION_LOST: return "Connection lost";
        case LIBSSH2_FX_FAILURE: return "Server reported an SFTP failure";
        default: return "SFTP request failed";
    }
}

static inline void volt_format_sftp_error(char *error, size_t length, const char *operation,
                                          unsigned long status, const char *technical) {
    if (!error || !length) return;
    snprintf(error, length, "%s %s (SFTP %lu). %s", operation,
             volt_sftp_status_description(status), status, technical ? technical : "");
}
#endif
