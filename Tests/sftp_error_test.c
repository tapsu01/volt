#include <assert.h>
#include <string.h>
#include "../Sources/CVoltSSH/SFTPError.h"
int main(void) {
    char message[512];
    volt_format_sftp_error(message, sizeof(message), "Could not create upload file.", LIBSSH2_FX_PERMISSION_DENIED, "SFTP Protocol Error");
    assert(strstr(message, "Permission denied"));
    assert(strstr(message, "SFTP 3"));
    assert(strstr(message, "SFTP Protocol Error"));
    volt_format_sftp_error(message, sizeof(message), "Could not publish.", LIBSSH2_FX_FAILURE, "Failure");
    assert(!strstr(message, "Permission denied"));
    volt_format_sftp_error(message, sizeof(message), "Could not read.", 999, NULL);
    assert(strstr(message, "SFTP 999"));
    char tiny[4];
    volt_format_sftp_error(tiny, sizeof(tiny), "Failed", 3, NULL);
    assert(tiny[3] == '\0');
    volt_format_sftp_error(NULL, 0, "Failed", 3, NULL);
    return 0;
}
