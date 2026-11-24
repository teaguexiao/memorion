#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device.h>

#ifdef CONFIG_OMI_ENABLE_BUTTON
#include "button.h"
#endif
#include "codec.h"
#include "config.h"
#include "led.h"
#include "lib/battery/battery.h"
#include "mic.h"
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
#include "sdcard.h"
#include "storage.h"
#endif
#ifdef CONFIG_OMI_ENABLE_SPEAKER
#include "speaker.h"
#endif
#include "settings.h"
#include "transport.h"
#ifdef CONFIG_OMI_ENABLE_USB
#include "usb.h"
#endif
#include "utils.h"
#include "wdog_facade.h"
#define BOOT_BLINK_DURATION_MS 600
#define BOOT_PAUSE_DURATION_MS 200
LOG_MODULE_REGISTER(main, CONFIG_LOG_DEFAULT_LEVEL);

static void codec_handler(uint8_t *data, size_t len)
{
    int err = broadcast_audio_packets(data, len);
    if (err) {
        LOG_DBG("Failed to broadcast audio packets: %d", err);
    }
}

static void mic_handler(int16_t *buffer)
{
    int err = codec_receive_pcm(buffer, MIC_BUFFER_SAMPLES);
    if (err) {
        LOG_ERR("Failed to process PCM data: %d", err);
    }
}

void bt_ctlr_assert_handle(char *name, int type)
{
    LOG_INF("Bluetooth assert: %s (type %d)", name ? name : "NULL", type);
}

static void print_reset_reason(void)
{
    uint32_t reas = NRF_POWER->RESETREAS;

    // Clear the reset reason register
    NRF_POWER->RESETREAS = reas;

    if (reas & POWER_RESETREAS_DOG_Msk) {
        printk("Reset by WATCHDOG\n");
    } else if (reas & POWER_RESETREAS_NFC_Msk) {
        printk("Wake up by NFC field detect\n");
    } else if (reas & POWER_RESETREAS_RESETPIN_Msk) {
        printk("Reset by pin-reset\n");
    } else if (reas & POWER_RESETREAS_SREQ_Msk) {
        printk("Reset by soft-reset\n");
    } else if (reas & POWER_RESETREAS_LOCKUP_Msk) {
        printk("Reset by CPU LOCKUP\n");
    } else if (reas) {
        printk("Reset by a different source (0x%08X)\n", reas);
    } else {
        printk("Power-on-reset\n");
    }
}

bool is_connected = false;
#ifdef CONFIG_OMI_ENABLE_USB
extern bool is_off;
#else
static bool is_off = false;
#endif

static bool is_vbus_present(void)
{
    return (NRF_POWER->USBREGSTATUS & POWER_USBREGSTATUS_VBUSDETECT_Msk) != 0;
}

// Cached battery voltage for charging state detection.
// Only re-sample every CHARGE_VOLTAGE_CHECK_INTERVAL calls to set_led_state()
// (set_led_state is called every 500ms, so 20 = every 10 seconds)
#define CHARGE_VOLTAGE_CHECK_INTERVAL 20
static uint16_t cached_battery_mv = 0;
static uint8_t charge_voltage_tick = 0;
static void boot_led_sequence(void)
{
    // Red blink
    set_led_red(true);
    k_msleep(BOOT_BLINK_DURATION_MS);
    set_led_red(false);
    k_msleep(BOOT_PAUSE_DURATION_MS);
    // Green blink
    set_led_green(true);
    k_msleep(BOOT_BLINK_DURATION_MS);
    set_led_green(false);
    k_msleep(BOOT_PAUSE_DURATION_MS);
    // Blue blink
    set_led_blue(true);
    k_msleep(BOOT_BLINK_DURATION_MS);
    set_led_blue(false);
    k_msleep(BOOT_PAUSE_DURATION_MS);
    // All LEDs on
    set_led_red(true);
    set_led_green(true);
    set_led_blue(true);
    k_msleep(BOOT_BLINK_DURATION_MS);
    // All LEDs off
    set_led_red(false);
    set_led_green(false);
    set_led_blue(false);
}

void set_led_state()
{
    static uint8_t gentle_tick = 0;
    uint8_t dim_ratio = app_settings_get_dim_ratio();

    // Charging indicator when USB VBUS detected
    if (is_vbus_present()) {
        // Only read ADC every ~10 seconds to save power
        if (charge_voltage_tick == 0) {
            battery_get_millivolt(&cached_battery_mv);
        }
        charge_voltage_tick = (charge_voltage_tick + 1) % CHARGE_VOLTAGE_CHECK_INTERVAL;

        // Battery disconnected (power switch off): voltage out of valid range
        if (cached_battery_mv < 3000 || cached_battery_mv > 4300) {
            // Warning: red/green alternating blink to signal "turn on power switch"
            static uint8_t warn_tick;
            warn_tick = (warn_tick + 1) % 4;
            bool phase = (warn_tick < 2);
            set_led_red(phase);
            set_led_green(!phase);
            set_led_blue(false);
            return;
        }

        if (cached_battery_mv >= 4050) {
            // Charge complete: steady green
            set_led_green_dim(true);
        } else {
            // Charging: brief white flash every ~2s
            static uint8_t charge_tick;
            charge_tick = (charge_tick + 1) % 4;
            set_led_white_dim(charge_tick == 0);
        }
        return;
    }

    if (is_off) {
        set_led_red(false);
        set_led_green(false);
        set_led_blue(false);
        return;
    }

    // Night mode (dim_ratio == 0): all LEDs off
    if (dim_ratio == 0) {
        set_led_red(false);
        set_led_green(false);
        set_led_blue(false);
        return;
    }

    // Gentle mode (dim_ratio 1-29): slow blink, 1s on / 1s off
    // set_led_state() is called every 500ms, so toggle every 2 ticks
    bool gentle_mode = (dim_ratio < 30);
    bool gentle_on = true;
    if (gentle_mode) {
        gentle_tick = (gentle_tick + 1) % 4;
        gentle_on = (gentle_tick < 2);
    }

    // Short flash to save power: 200ms pulse then off
    #define LED_FLASH_MS 200
    // Connected: blue flash every ~1.5s (3 ticks × 500ms)
    // Disconnected: red flash every ~5s (10 ticks × 500ms)
    static uint8_t conn_tick = 0;
    static uint8_t disconn_tick = 0;
    #define CONN_FLASH_PERIOD 3
    #define DISCONN_FLASH_PERIOD 10

    if (is_connected) {
        disconn_tick = 0;
        if (conn_tick == 0 && gentle_on) {
            set_led_blue(true);
            k_msleep(LED_FLASH_MS);
            set_led_blue(false);
        }
        set_led_red(false);
        set_led_green(false);
        conn_tick = (conn_tick + 1) % CONN_FLASH_PERIOD;
    } else {
        conn_tick = 0;
        if (disconn_tick == 0 && gentle_on) {
            set_led_red(true);
            k_msleep(LED_FLASH_MS);
            set_led_red(false);
        }
        set_led_blue(false);
        set_led_green(false);
        disconn_tick = (disconn_tick + 1) % DISCONN_FLASH_PERIOD;
    }
}

int main(void)
{
    int err;

    // Print and clear reset reason
    print_reset_reason();

    NRF_POWER->DCDCEN = 1;
    NRF_POWER->DCDCEN0 = 1;

    LOG_INF("Booting...\n");

    LOG_INF("Model: %s", CONFIG_BT_DIS_MODEL);
    LOG_INF("Firmware revision: %s", CONFIG_BT_DIS_FW_REV_STR);
    LOG_INF("Hardware revision: %s", CONFIG_BT_DIS_HW_REV_STR);
    // Force QSPI flash into deep sleep mode
    const struct device *flash_dev = DEVICE_DT_GET(DT_NODELABEL(p25q16h));
    if (device_is_ready(flash_dev)) {
        err = pm_device_action_run(flash_dev, PM_DEVICE_ACTION_SUSPEND);
        if (err) {
            LOG_ERR("Failed to suspend QSPI flash: %d", err);
        }
    } else {
        LOG_ERR("QSPI flash device not ready");
    }
    LOG_PRINTK("\n");
    LOG_INF("Initializing LEDs...\n");

    err = led_start();
    if (err) {
        LOG_ERR("Failed to initialize LEDs (err %d)", err);
        return err;
    }

    // Run the boot LED sequence
    boot_led_sequence();

    // Initialize settings (NVS) for LED dim ratio persistence
    err = app_settings_init();
    if (err) {
        LOG_WRN("Settings init failed (err %d), using defaults", err);
    }

    // Initialize watchdog early to catch any freezes during boot
    err = watchdog_init();
    if (err) {
        LOG_WRN("Watchdog init failed (err %d), continuing without watchdog", err);
    }

    // Enable battery
#ifdef CONFIG_OMI_ENABLE_BATTERY
    err = battery_init();
    if (err) {
        LOG_ERR("Battery init failed (err %d)", err);
        return err;
    }

    err = battery_charge_start();
    if (err) {
        LOG_ERR("Battery failed to start (err %d)", err);
        return err;
    }
    LOG_INF("Battery initialized");
#endif

    // Enable button
#ifdef CONFIG_OMI_ENABLE_BUTTON
    err = button_init();
    if (err) {
        LOG_ERR("Failed to initialize Button (err %d)", err);
        return err;
    }
    LOG_INF("Button initialized");
    activate_button_work();
#endif

    // Enable accelerometer
#ifdef CONFIG_OMI_ENABLE_ACCELEROMETER
    err = accel_start();
    if (err) {
        LOG_ERR("Accelerometer failed to activated (err %d)", err);
        return err;
    }
    LOG_INF("Accelerometer initialized");
#endif

    // Enable speaker
#ifdef CONFIG_OMI_ENABLE_SPEAKER
    err = speaker_init();
    if (err) {
        LOG_ERR("Speaker failed to start");
        return err;
    }
    LOG_INF("Speaker initialized");
#endif

    // Enable sdcard
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    LOG_PRINTK("\n");
    LOG_INF("Mount SD card...\n");

    err = mount_sd_card();
    if (err) {
        LOG_WRN("Failed to mount SD card (err %d), continuing without offline storage", err);
    } else {
        k_msleep(500);

        LOG_PRINTK("\n");
        LOG_INF("Initializing storage...\n");

        err = storage_init();
        if (err) {
            LOG_WRN("Failed to initialize storage (err %d)", err);
        }
    }
#endif

    // Enable haptic
#ifdef CONFIG_OMI_ENABLE_HAPTIC
    LOG_PRINTK("\n");
    LOG_INF("Initializing haptic...\n");

    err = init_haptic_pin();
    if (err) {
        LOG_ERR("Failed to initialize haptic pin (err %d)", err);
        return err;
    }
    LOG_INF("Haptic pin initialized");
#endif

    // Enable usb
#ifdef CONFIG_OMI_ENABLE_USB
    LOG_PRINTK("\n");
    LOG_INF("Initializing power supply check...\n");

    err = init_usb();
    if (err) {
        LOG_ERR("Failed to initialize power supply (err %d)", err);
        return err;
    }
#endif

    // Indicate transport initialization
    LOG_PRINTK("\n");
    LOG_INF("Initializing transport...\n");

    set_led_green(true);
    set_led_green(false);

    // Start transport
    int transportErr;
    transportErr = transport_start();
    if (transportErr) {
        LOG_ERR("Failed to start transport (err %d)", transportErr);
        // TODO: Detect the current core is app core or net core
        // Blink green LED to indicate error
        for (int i = 0; i < 5; i++) {
            set_led_green(i % 2 == 0);
            k_msleep(200);
        }
        set_led_green(false);

        return transportErr;
    }

#ifdef CONFIG_OMI_ENABLE_SPEAKER
    play_boot_sound();
#endif

    LOG_PRINTK("\n");
    LOG_INF("Initializing codec...\n");

    set_led_blue(true);

    // Audio codec(opus) callback
    set_codec_callback(codec_handler);
    err = codec_start();
    if (err) {
        LOG_ERR("Failed to start codec: %d", err);
        // Blink blue LED to indicate error
        for (int i = 0; i < 5; i++) {
            set_led_blue(i % 2 == 0);
            k_msleep(200);
        }
        set_led_blue(false);
        return err;
    }

#ifdef CONFIG_OMI_ENABLE_HAPTIC
    play_haptic_milli(500);
#endif
    set_led_blue(false);

    // Indicate microphone initialization
    LOG_PRINTK("\n");
    LOG_INF("Initializing microphone...\n");

    set_led_red(true);
    set_led_green(true);

    set_mic_callback(mic_handler);
    err = mic_start();
    if (err) {
        LOG_ERR("Failed to start microphone: %d", err);
        // Blink red and green LEDs to indicate error
        for (int i = 0; i < 5; i++) {
            set_led_red(i % 2 == 0);
            set_led_green(i % 2 == 0);
            k_msleep(200);
        }
        set_led_red(false);
        set_led_green(false);
        return err;
    }

    set_led_red(false);
    set_led_green(false);

    // Indicate successful initialization
    LOG_PRINTK("\n");
    LOG_INF("Device initialized successfully\n");

    set_led_blue(true);
    k_msleep(1000);
    set_led_blue(false);

    // Main loop
    LOG_PRINTK("\n");
    LOG_INF("Entering main loop...\n");

    while (1) {
        watchdog_feed();

        set_led_state();
        k_msleep(500);
    }

    // Unreachable
    return 0;
}
