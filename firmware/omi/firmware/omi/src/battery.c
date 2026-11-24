#include "lib/core/lib/battery/battery.h"

#include <hal/nrf_saadc.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/dt-bindings/gpio/nordic-nrf-gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(battery, CONFIG_LOG_DEFAULT_LEVEL);

#define DISCHARGE_STATES_COUNT 22
#define CHARGING_STATES_COUNT 23

#define ADC_TOTAL_SAMPLES 50
// +1 for the calibration sample
int16_t sample_buffer[ADC_TOTAL_SAMPLES + 1];

#define ADC_RESOLUTION 12
#define ADC_GAIN ADC_GAIN_1_3
#define ADC_REFERENCE ADC_REF_INTERNAL
#define ADC_ACQUISITION_TIME ADC_ACQ_TIME(ADC_ACQ_TIME_MICROSECONDS, 10)
#define ADC_1ST_CHANNEL_ID 0
#define ADC_1ST_CHANNEL_INPUT NRF_SAADC_INPUT_AIN0

// EMA filter: N=18, alpha = 65535/(18+1) ~= 3449 (~5.3%)
#define BATTERY_FILTER_ALPHA_U16 (uint16_t)(65535/(18+1))
#define FILTER_INIT_CYCLES 8

// Charging state transition smoothing
#define CHARGE_TRANSITION_TICKS 6  // ~60s at 10s interval before fully switching tables
#define MAX_BATTERY_DELTA_PER_TICK 2  // Max percentage change per measurement cycle

// Static variable to store previous EMA value for battery percentage
static uint8_t battery_percentage_ema = 0;
static bool ema_initialized = false;
static bool is_first_measurement = true;
static uint8_t ema_init_counter = 0;

// Charging state transition tracking
static bool prev_is_charging = false;
static bool charge_state_changed = false;
static uint8_t transition_counter = 0;
static uint8_t transition_anchor_pct = 0;

static const struct device *const adc_dev = DEVICE_DT_GET(DT_NODELABEL(adc));
static const struct gpio_dt_spec power_pin = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(power_pin), gpios, {0});
static const struct gpio_dt_spec bat_read_pin = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(bat_read_pin), gpios, {0});
static const struct gpio_dt_spec bat_chg_pin = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(bat_chg_pin), gpios, {0});

static struct gpio_callback bat_chg_cb;

static K_MUTEX_DEFINE(battery_mut);

// 150mAh LiPo battery discharge profile (measured under ~5mA typical load)
// Dense sampling in the 3.7V~3.95V flat region for better mid-range accuracy
typedef struct {
    uint16_t millivolts;
    uint8_t percentage;
} BatteryState;

BatteryState battery_discharge_states[DISCHARGE_STATES_COUNT] = {
    {4140, 100},
    {4120, 97},
    {4100, 94},
    {4070, 88},
    {4040, 82},
    {4010, 76},
    {3980, 70},
    {3955, 65},
    {3935, 60},
    {3910, 55},
    {3890, 50},
    {3870, 45},
    {3845, 40},
    {3820, 35},
    {3790, 30},
    {3760, 25},
    {3730, 20},
    {3700, 15},
    {3670, 10},
    {3630, 5},
    {3500, 1},
    {   0, 0},
};

// Charging profile: independently measured during CC/CV charge cycle
// Voltage is higher than discharge at same SOC due to IR drop + charge overpotential
BatteryState battery_charging_states[CHARGING_STATES_COUNT] = {
    {4200, 100},
    {4190, 97},
    {4175, 94},
    {4155, 88},
    {4130, 82},
    {4105, 76},
    {4080, 70},
    {4055, 65},
    {4030, 60},
    {4005, 55},
    {3985, 50},
    {3965, 45},
    {3940, 40},
    {3920, 35},
    {3895, 30},
    {3870, 25},
    {3840, 20},
    {3810, 15},
    {3780, 10},
    {3750, 5},
    {3700, 3},
    {3650, 1},
    {   0, 0},
};

extern bool is_charging;

static const struct adc_channel_cfg m_1st_channel_cfg = {
    .gain = ADC_GAIN,
    .reference = ADC_REFERENCE,
    .acquisition_time = ADC_ACQUISITION_TIME,
    .channel_id = ADC_1ST_CHANNEL_ID,
#if defined(CONFIG_ADC_CONFIGURABLE_INPUTS)
    .input_positive = ADC_1ST_CHANNEL_INPUT,
#endif
};

// Define ADC sequence for this read operation
const struct adc_sequence_options sequence_opts = {
    .extra_samplings = ADC_TOTAL_SAMPLES,
    .interval_us = 0,
    .callback = NULL,
    .user_data = NULL,
};

struct adc_sequence sequence = {
    .options = &sequence_opts,
    .channels = BIT(ADC_1ST_CHANNEL_ID),
    .buffer = sample_buffer,
    .buffer_size = sizeof(sample_buffer),
    .resolution = ADC_RESOLUTION,
};

uint8_t update_ema_filter(uint32_t current_ema, uint8_t new_value)
{
    // At extremes, use slow ±1 stepping to avoid oscillation
    if ((!is_charging && (current_ema <= 5)) || (is_charging && (current_ema >= 95))) {
        if (is_charging) {
            return (new_value > current_ema) ? current_ema + 1 : current_ema;
        } else {
            return (new_value < current_ema) ? current_ema - 1 : current_ema;
        }
    }

    const uint32_t alpha = BATTERY_FILTER_ALPHA_U16;
    const uint32_t alpha_complement = UINT16_MAX - BATTERY_FILTER_ALPHA_U16;

    uint64_t new_ema = (alpha * new_value) + (alpha_complement * current_ema);

    return (uint8_t)((new_ema + 32768) >> 16);
}

static void battery_charging_callback(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
    int err = battery_charging_state_read();
    if (err) {
        LOG_ERR("Failed to read charging state (%d)", err);
    }
}

// Dynamic charging voltage compensation
// CC phase (lower voltage): larger IR drop compensation
// CV phase (near 4.2V): minimal compensation needed
static int16_t get_charging_compensation(int32_t adc_mv)
{
    int32_t approx_vbat = adc_mv * 3;

    if (approx_vbat < 3700) {
        // Deep discharge CC phase — very high IR drop + overpotential
        return 45;
    } else if (approx_vbat < 3900) {
        // Normal CC phase
        return 35;
    } else if (approx_vbat < 4050) {
        // CC to CV transition
        return 18;
    } else {
        // CV phase, current tapering
        return 10;
    }
}

static uint8_t lookup_percentage(BatteryState *states, int count, uint16_t battery_millivolt)
{
    if (battery_millivolt >= states[0].millivolts) {
        return states[0].percentage;
    }
    if (battery_millivolt <= states[count - 1].millivolts) {
        return states[count - 1].percentage;
    }

    for (int i = 0; i < count - 1; i++) {
        if (battery_millivolt <= states[i].millivolts && battery_millivolt > states[i + 1].millivolts) {
            uint16_t voltage_range = states[i].millivolts - states[i + 1].millivolts;
            uint8_t percentage_range = states[i].percentage - states[i + 1].percentage;
            uint16_t voltage_diff = states[i].millivolts - battery_millivolt;

            return states[i].percentage - (voltage_diff * percentage_range) / voltage_range;
        }
    }

    return 0;
}

int battery_get_millivolt(uint16_t *battery_millivolt)
{
    int err;

    // Voltage divider circuit
    // based on practical measurements adjusted on the omi device
    const uint16_t R1 = 1091;
    const uint16_t R2 = 499;

    k_mutex_lock(&battery_mut, K_FOREVER);

    err = gpio_pin_configure_dt(&bat_read_pin, GPIO_OUTPUT | NRF_GPIO_DRIVE_S0H1);
    if (err < 0) {
        LOG_ERR("Failed to configure bat_read_pin to output: %d", err);
        k_mutex_unlock(&battery_mut);
        return err;
    }

    // Set pin low to enable battery voltage measurement path
    gpio_pin_set(bat_read_pin.port, bat_read_pin.pin, 0);

    if (!device_is_ready(adc_dev)) {
        LOG_ERR("ADC device %s is not ready", adc_dev->name);
        gpio_pin_configure_dt(&bat_read_pin, GPIO_INPUT); // Restore pin state
        k_mutex_unlock(&battery_mut);
        return -ENODEV;
    }

    err = adc_channel_setup(adc_dev, &m_1st_channel_cfg);
    if (err) {
        LOG_ERR("ADC channel setup failed (error %d)", err);
        gpio_pin_configure_dt(&bat_read_pin, GPIO_INPUT); // Restore pin state
        k_mutex_unlock(&battery_mut);
        return err;
    }

    // Trigger offset calibration. The first sample after this will be affected.
    NRF_SAADC_S->TASKS_CALIBRATEOFFSET = 1;
    k_busy_wait(100); // Short delay for calibration, if needed.

    err = adc_read(adc_dev, &sequence);
    if (err) {
        LOG_WRN("ADC read failed (error %d)", err);
        gpio_pin_configure_dt(&bat_read_pin, GPIO_INPUT); // Restore pin state
        k_mutex_unlock(&battery_mut);
        return err;
    }

    // Calculate median of valid samples, discarding the first one (post-calibration)
    // Copy samples to a temporary array for sorting
    int16_t sorted_samples[ADC_TOTAL_SAMPLES];
    for (int i = 0; i < ADC_TOTAL_SAMPLES; i++) {
        sorted_samples[i] = sample_buffer[i + 1];
    }

    // Simple bubble sort for median calculation
    for (int i = 0; i < ADC_TOTAL_SAMPLES - 1; i++) {
        for (int j = 0; j < ADC_TOTAL_SAMPLES - i - 1; j++) {
            if (sorted_samples[j] > sorted_samples[j + 1]) {
                int16_t temp = sorted_samples[j];
                sorted_samples[j] = sorted_samples[j + 1];
                sorted_samples[j + 1] = temp;
            }
        }
    }

    // Calculate median
    int32_t adc_raw_val;
    if (ADC_TOTAL_SAMPLES % 2 == 0) {
        adc_raw_val = (sorted_samples[ADC_TOTAL_SAMPLES / 2 - 1] + sorted_samples[ADC_TOTAL_SAMPLES / 2]) / 2;
    } else {
        adc_raw_val = sorted_samples[ADC_TOTAL_SAMPLES / 2];
    }

    LOG_INF("Median ADC raw (after discarding 1st of %d total): %d", ADC_TOTAL_SAMPLES + 1, adc_raw_val);

    // Convert median ADC value to millivolts at the ADC pin
    uint16_t adc_vref_mv = adc_ref_internal(adc_dev);
    err = adc_raw_to_millivolts(adc_vref_mv, ADC_GAIN, ADC_RESOLUTION, &adc_raw_val);
    if (err) {
        LOG_WRN("ADC raw to millivolts conversion failed (error %d)", err);
        gpio_pin_configure_dt(&bat_read_pin, GPIO_INPUT); // Restore pin state
        k_mutex_unlock(&battery_mut);
        return err;
    }
    LOG_INF("ADC mV at pin (after conversion): %d, charging: %s", adc_raw_val, is_charging ? "true" : "false");

    // Dynamic charging compensation based on charge phase (CC vs CV)
    if (is_charging) {
        adc_raw_val -= get_charging_compensation(adc_raw_val);
    }

    // Calculate battery voltage using the voltage divider formula
    *battery_millivolt = (uint16_t) (adc_raw_val * ((float) (R1 + R2) / R2));
    LOG_INF("Battery voltage (mV): %d", *battery_millivolt);

    // Restore bat_read_pin to INPUT state to save power/avoid affecting other circuits
    err = gpio_pin_configure_dt(&bat_read_pin, GPIO_INPUT);
    if (err < 0) {
        LOG_ERR("Failed to configure bat_read_pin to input: %d", err);
        k_mutex_unlock(&battery_mut);
        return err;
    }

    if (is_first_measurement) {
        LOG_INF("First measurement, skipping to allow voltage to stabilize");
        is_first_measurement = false;
        k_mutex_unlock(&battery_mut);
        return -EAGAIN; // Skip first measurement to allow voltage to stabilize
    }

    k_mutex_unlock(&battery_mut);

    return 0;
}

int battery_get_percentage(uint8_t *battery_percentage, uint16_t battery_millivolt)
{
    uint8_t raw_percentage = 0;

    // Detect charging state change and start transition period
    if (ema_initialized && is_charging != prev_is_charging) {
        charge_state_changed = true;
        transition_counter = 0;
        transition_anchor_pct = battery_percentage_ema;
        prev_is_charging = is_charging;
        LOG_INF("Charge state changed, anchoring at %d%%, starting transition", transition_anchor_pct);
    }

    // During transition: blend between anchor and new table's value
    if (charge_state_changed) {
        uint8_t new_table_pct;
        if (is_charging) {
            new_table_pct = lookup_percentage(battery_charging_states, CHARGING_STATES_COUNT, battery_millivolt);
        } else {
            new_table_pct = lookup_percentage(battery_discharge_states, DISCHARGE_STATES_COUNT, battery_millivolt);
        }

        transition_counter++;
        if (transition_counter >= CHARGE_TRANSITION_TICKS) {
            // Transition complete, use new table fully
            charge_state_changed = false;
            raw_percentage = new_table_pct;
            LOG_INF("Charge transition complete, now at %d%%", raw_percentage);
        } else {
            // Linear blend: weight shifts from anchor toward new table value
            uint8_t weight = (transition_counter * 100) / CHARGE_TRANSITION_TICKS;
            raw_percentage = (uint8_t)(((100 - weight) * transition_anchor_pct + weight * new_table_pct) / 100);
        }
    } else {
        // Normal operation: use appropriate table
        if (is_charging) {
            raw_percentage = lookup_percentage(battery_charging_states, CHARGING_STATES_COUNT, battery_millivolt);
        } else {
            raw_percentage = lookup_percentage(battery_discharge_states, DISCHARGE_STATES_COUNT, battery_millivolt);
        }
    }

    // Monotonicity enforcement: only allow percentage to move in the expected direction
    if (battery_percentage_ema != 0 && !charge_state_changed) {
        if (is_charging && raw_percentage < battery_percentage_ema) {
            raw_percentage = battery_percentage_ema;
        } else if (!is_charging && raw_percentage > battery_percentage_ema) {
            raw_percentage = battery_percentage_ema;
        }
    }

    // Global delta clamp: prevent large jumps even during EMA init or after reboot
    if (battery_percentage_ema != 0 || ema_init_counter > 0) {
        int16_t delta = (int16_t)raw_percentage - (int16_t)battery_percentage_ema;
        if (delta > MAX_BATTERY_DELTA_PER_TICK) {
            raw_percentage = battery_percentage_ema + MAX_BATTERY_DELTA_PER_TICK;
        } else if (delta < -MAX_BATTERY_DELTA_PER_TICK) {
            raw_percentage = (battery_percentage_ema > MAX_BATTERY_DELTA_PER_TICK)
                ? battery_percentage_ema - MAX_BATTERY_DELTA_PER_TICK : 0;
        }
    }

    // EMA initialization: seed the filter over FILTER_INIT_CYCLES before enabling smoothing
    if (!ema_initialized) {
        battery_percentage_ema = raw_percentage;
        ema_init_counter++;

        if (ema_init_counter >= FILTER_INIT_CYCLES) {
            ema_initialized = true;
            prev_is_charging = is_charging;
            LOG_INF("Battery EMA initialized at %d%%", battery_percentage_ema);
        }

        *battery_percentage = battery_percentage_ema;
    } else {
        battery_percentage_ema = update_ema_filter(battery_percentage_ema, raw_percentage);
        *battery_percentage = battery_percentage_ema;
    }

    return 0;
}

int battery_charge_start()
{
    return 0;
}

int battery_charge_stop()
{
    return 0;
}

int battery_set_fast_charge()
{
    return 0;
}

int battery_set_slow_charge()
{
    return 0;
}

int battery_charging_state_read()
{
    if (gpio_pin_get(bat_chg_pin.port, bat_chg_pin.pin) == 0) {
        is_charging = true;
    } else {
        is_charging = false;
    }
    return 0;
}

int battery_enable_read()
{
    int err;

    // Perform voltage divider configs
    err = gpio_pin_configure_dt(&bat_read_pin, GPIO_OUTPUT | NRF_GPIO_DRIVE_S0H1);
    if (err < 0) {
        LOG_ERR("Failed to configure bat_read_pin to output: %d", err);
        return err;
    }

    // Set pin low to enable battery voltage measurement path
    gpio_pin_set(bat_read_pin.port, bat_read_pin.pin, 0);
    k_msleep(10);

    if (!device_is_ready(adc_dev)) {
        LOG_ERR("ADC device %s is not ready", adc_dev->name);
        gpio_pin_configure_dt(&bat_read_pin, GPIO_INPUT); // Restore pin state
        return -ENODEV;
    }

    err = adc_channel_setup(adc_dev, &m_1st_channel_cfg);
    if (err) {
        LOG_ERR("ADC channel setup failed (error %d)", err);
        gpio_pin_configure_dt(&bat_read_pin, GPIO_INPUT); // Restore pin state
        return err;
    }

    // Trigger offset calibration with proper settling time
    NRF_SAADC_S->TASKS_CALIBRATEOFFSET = 1;
    k_msleep(5);

    // Read samples
    err = adc_read(adc_dev, &sequence);
    if (err) {
        LOG_WRN("ADC read failed (error %d)", err);
        gpio_pin_configure_dt(&bat_read_pin, GPIO_INPUT); // Restore pin state
        return err;
    }

    // Restore bat_read_pin
    err = gpio_pin_configure_dt(&bat_read_pin, GPIO_INPUT);
    if (err < 0) {
        LOG_ERR("Failed to configure bat_read_pin to input: %d", err);
        return err;
    }

    return 0;
}

int battery_init()
{
    int err;

    k_mutex_lock(&battery_mut, K_FOREVER);

    err = gpio_pin_configure_dt(&bat_read_pin, GPIO_INPUT);
    if (err < 0) {
        LOG_ERR("Failed to configure enable pin (%d)", err);
        k_mutex_unlock(&battery_mut);
        return err;
    }

    err = gpio_pin_configure_dt(&bat_chg_pin, GPIO_INPUT | GPIO_PULL_UP);
    if (err < 0) {
        LOG_ERR("Failed to configure enable pin (%d)", err);
        k_mutex_unlock(&battery_mut);
        return err;
    }
    battery_charging_callback(NULL, NULL, 0);
    err = gpio_pin_interrupt_configure_dt(&bat_chg_pin, GPIO_INT_EDGE_BOTH);
    if (err < 0) {
        LOG_ERR("Failed to configure interrupt for bat_chg_pin (%d)", err);
        k_mutex_unlock(&battery_mut);
        return err;
    }
    gpio_init_callback(&bat_chg_cb, battery_charging_callback, BIT(bat_chg_pin.pin));
    gpio_add_callback(bat_chg_pin.port, &bat_chg_cb);

    err = battery_enable_read();
    if (err < 0) {
        LOG_ERR("Failed to enable battery read (%d)", err);
        k_mutex_unlock(&battery_mut);
        return err;
    }

    k_mutex_unlock(&battery_mut);

    // Charging state read
    int chargingStateErr;
    chargingStateErr = battery_charging_state_read();
    if (chargingStateErr) {
        LOG_ERR("Failed to read charging state (%d)", chargingStateErr);
    }

    return 0;
}
