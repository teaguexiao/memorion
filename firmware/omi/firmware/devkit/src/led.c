#include "led.h"

#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>

#include "utils.h"

LOG_MODULE_REGISTER(led, CONFIG_LOG_DEFAULT_LEVEL);

int led_start(void)
{
    ASSERT_TRUE(gpio_is_ready_dt(&led_red));
    ASSERT_OK(gpio_pin_configure_dt(&led_red, GPIO_OUTPUT_INACTIVE));
    ASSERT_TRUE(gpio_is_ready_dt(&led_green));
    ASSERT_OK(gpio_pin_configure_dt(&led_green, GPIO_OUTPUT_INACTIVE));
    ASSERT_TRUE(gpio_is_ready_dt(&led_blue));
    ASSERT_OK(gpio_pin_configure_dt(&led_blue, GPIO_OUTPUT_INACTIVE));
    LOG_INF("LEDs started (GPIO)");
    return 0;
}

void set_led_red(bool on)
{
    gpio_pin_set_dt(&led_red, on);
}

void set_led_green(bool on)
{
    gpio_pin_set_dt(&led_green, on);
}

void set_led_blue(bool on)
{
    gpio_pin_set_dt(&led_blue, on);
}

void set_led_white_dim(bool on)
{
    gpio_pin_set_dt(&led_red, on);
    gpio_pin_set_dt(&led_green, on);
    gpio_pin_set_dt(&led_blue, on);
}

void set_led_green_dim(bool on)
{
    gpio_pin_set_dt(&led_red, 0);
    gpio_pin_set_dt(&led_green, on);
    gpio_pin_set_dt(&led_blue, 0);
}
