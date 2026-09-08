#ifndef VOLT_UPLOAD_PUBLISH_H
#define VOLT_UPLOAD_PUBLISH_H

/* A rejected request is different from a lost reply: never retry an uncertain
 * publish, and retain its temporary path for inspection. No operation here
 * removes the destination. */
enum VoltUploadPublishResult {
    VOLT_UPLOAD_PUBLISHED = 0,
    VOLT_UPLOAD_REJECTED = -1,
    VOLT_UPLOAD_UNCERTAIN = -2
};

typedef int (*VoltUploadRename)(void *, const char *, const char *, int);
typedef void (*VoltUploadCleanup)(void *, const char *);

static inline int volt_upload_publish(void *context, const char *temporary_path,
                                     const char *destination, int overwrite,
                                     VoltUploadRename rename_file,
                                     VoltUploadCleanup cleanup) {
    int result = rename_file(context, temporary_path, destination, overwrite);
    if (result == VOLT_UPLOAD_REJECTED) cleanup(context, temporary_path);
    return result;
}

#endif
