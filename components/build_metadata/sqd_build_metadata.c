#include "sqd_build_metadata.h"
#include <inttypes.h>
#include <stddef.h>
#include <stdio.h>
#include "esp_app_desc.h"
#include "esp_log.h"
#include "sqd_build_metadata_generated.h"

static const char *TAG = "sqd_metadata";

__attribute__((used, section(".rodata_custom_desc")))
const char sqd_build_metadata_blob[] =
    "SQD_META_V1"
    "|version=" SQD_META_PRODUCT_VERSION
    "|git=" SQD_META_GIT_COMMIT
    "|dirty=" SQD_META_GIT_DIRTY_STRING
    "|source_time=" SQD_META_SOURCE_TIMESTAMP_UTC
    "|build_time=" SQD_META_BUILD_TIMESTAMP_UTC
    "|profile=" SQD_META_BUILD_PROFILE
    "|target=" SQD_META_TARGET
    "|hardware=" SQD_META_HARDWARE_COMPATIBILITY
    "|compiler=" __VERSION__;

const sqd_build_metadata_t *sqd_build_metadata_get(void)
{
    static sqd_build_metadata_t metadata;
    static char elf_sha256[65];
    const esp_app_desc_t *app = esp_app_get_description();

    for (size_t i = 0; i < sizeof(app->app_elf_sha256); ++i) {
        (void)snprintf(&elf_sha256[i * 2], sizeof(elf_sha256) - (i * 2), "%02x", app->app_elf_sha256[i]);
    }

    metadata.product_version = SQD_META_PRODUCT_VERSION;
    metadata.git_commit = SQD_META_GIT_COMMIT;
    metadata.git_commit_short = SQD_META_GIT_COMMIT_SHORT;
    metadata.git_dirty = (SQD_META_GIT_DIRTY != 0);
    metadata.source_timestamp_utc = SQD_META_SOURCE_TIMESTAMP_UTC;
    metadata.build_timestamp_utc = SQD_META_BUILD_TIMESTAMP_UTC;
    metadata.build_profile = SQD_META_BUILD_PROFILE;
    metadata.target = SQD_META_TARGET;
    metadata.idf_version = app->idf_ver;
    metadata.compiler_version = __VERSION__;
    metadata.hardware_compatibility = SQD_META_HARDWARE_COMPATIBILITY;
    metadata.secure_version = app->secure_version;
    metadata.elf_sha256 = elf_sha256;
    return &metadata;
}

void sqd_build_metadata_log(void)
{
    const sqd_build_metadata_t *m = sqd_build_metadata_get();
    ESP_LOGI(TAG, "SQD_META schema=1");
    ESP_LOGI(TAG, "SQD_META product_version=%s", m->product_version);
    ESP_LOGI(TAG, "SQD_META git_commit=%s", m->git_commit);
    ESP_LOGI(TAG, "SQD_META git_commit_short=%s", m->git_commit_short);
    ESP_LOGI(TAG, "SQD_META git_dirty=%s", m->git_dirty ? "true" : "false");
    ESP_LOGI(TAG, "SQD_META source_timestamp_utc=%s", m->source_timestamp_utc);
    ESP_LOGI(TAG, "SQD_META build_timestamp_utc=%s", m->build_timestamp_utc);
    ESP_LOGI(TAG, "SQD_META build_profile=%s", m->build_profile);
    ESP_LOGI(TAG, "SQD_META target=%s", m->target);
    ESP_LOGI(TAG, "SQD_META idf_version=%s", m->idf_version);
    ESP_LOGI(TAG, "SQD_META compiler_version=%s", m->compiler_version);
    ESP_LOGI(TAG, "SQD_META hardware_compatibility=%s", m->hardware_compatibility);
    ESP_LOGI(TAG, "SQD_META secure_version=%" PRIu32, m->secure_version);
    ESP_LOGI(TAG, "SQD_META elf_sha256=%s", m->elf_sha256);
}
