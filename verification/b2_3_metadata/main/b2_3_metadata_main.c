#include <stdbool.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "sqd_build_metadata.h"
static const char *TAG = "b2_3_verify";
void app_main(void)
{
    sqd_build_metadata_log();
    ESP_LOGI(TAG, "B2.3_METADATA_RUNTIME_PASS");
    while (true) { vTaskDelay(pdMS_TO_TICKS(1000)); }
}
