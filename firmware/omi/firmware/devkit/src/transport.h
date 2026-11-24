#ifndef TRANSPORT_H
#define TRANSPORT_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef CONFIG_OMI_ENABLE_ACCELEROMETER
#include <zephyr/drivers/sensor.h>
typedef struct sensors {
    struct sensor_value a_x;
    struct sensor_value a_y;
    struct sensor_value a_z;
    struct sensor_value g_x;
    struct sensor_value g_y;
    struct sensor_value g_z;
};
#endif /* CONFIG_OMI_ENABLE_ACCELEROMETER */

/**
 * @brief Initialize the BLE transport logic
 *
 * Initializes the BLE Logic
 *
 * @return 0 if successful, negative errno code if error
 */
int transport_start();
int broadcast_audio_packets(uint8_t *buffer, size_t size);
struct bt_conn *get_current_connection();
int bt_on();
int bt_off();

void accel_off();

/**
 * @brief Pause/resume audio transport to free BLE TX buffers for button notifications
 */
void transport_audio_pause(bool pause);

#endif