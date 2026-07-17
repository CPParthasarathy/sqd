#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    const char *product_version;
    const char *git_commit;
    const char *git_commit_short;
    bool git_dirty;
    const char *source_timestamp_utc;
    const char *build_timestamp_utc;
    const char *build_profile;
    const char *target;
    const char *idf_version;
    const char *compiler_version;
    const char *hardware_compatibility;
    uint32_t secure_version;
    const char *elf_sha256;
} sqd_build_metadata_t;
const sqd_build_metadata_t *sqd_build_metadata_get(void);
void sqd_build_metadata_log(void);
#ifdef __cplusplus
}
#endif
