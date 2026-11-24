#include "lib/core/led.h"

#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>

#include "lib/core/settings.h"
#include "lib/core/utils.h"

LOG_MODULE_REGISTER(led, CONFIG_LOG_DEFAULT_LEVEL);

// Define LED GPIO specs from device tree
static const struct gpio_dt_spec led_red = GPIO_DT_SPEC_GET(DT_NODELABEL(led_red), gpios);
static const struct gpio_dt_spec led_green = GPIO_DT_SPEC_GET(DT_NODELABEL(led_green), gpios);
static const struct gpio_dt_spec led_blue = GPIO_DT_SPEC_GET(DT_NODELABEL(led_blue), gpios);

int led_start()
{
    ASSERT_TRUE(gpio_is_ready_dt(&led_red));
    ASSERT_TRUE(gpio_is_ready_dt(&led_green));
    ASSERT_TRUE(gpio_is_ready_dt(&led_blue));

    gpio_pin_configure_dt(&led_red, GPIO_OUTPUT_INACTIVE);
    gpio_pin_configure_dt(&led_green, GPIO_OUTPUT_INACTIVE);
    gpio_pin_configure_dt(&led_blue, GPIO_OUTPUT_INACTIVE);

    LOG_INF("LEDs (GPIO) started");
    return 0;
}

static void set_led_on_off(const struct gpio_dt_spec *led, bool on)
{
    if (!gpio_is_ready_dt(led)) {
        LOG_ERR("LED GPIO device not ready");
        return;
    }

    if (on) {
        uint8_t ratio = app_settings_get_dim_ratio();
        if (ratio < 10) {
            gpio_pin_set_dt(led, 0);
            return;
        }
    }

    gpio_pin_set_dt(led, on ? 1 : 0);
}

void set_led_red(bool on)
{
    set_led_on_off(&led_red, on);
}

void set_led_green(bool on)
{
    set_led_on_off(&led_green, on);
}

void set_led_blue(bool on)
{
    set_led_on_off(&led_blue, on);
}

void set_led_pwm(led_color_t color, uint8_t level)
{
    const struct gpio_dt_spec *led;

    switch (color) {
    case LED_RED:
        led = &led_red;
        break;
    case LED_GREEN:
        led = &led_green;
        break;
    case LED_BLUE:
        led = &led_blue;
        break;
    default:
        LOG_ERR("Invalid LED color");
        return;
    }

    if (!gpio_is_ready_dt(led)) {
        LOG_ERR("LED GPIO device not ready");
        return;
    }

    gpio_pin_set_dt(led, level > 0 ? 1 : 0);
}

void led_off(void)
{
    set_led_red(false);
    k_msleep(10);
    set_led_green(false);
    k_msleep(10);
    set_led_blue(false);
}
