#ifndef LED_H
#define LED_H

#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>

static const struct gpio_dt_spec led_red = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);
static const struct gpio_dt_spec led_green = GPIO_DT_SPEC_GET(DT_ALIAS(led1), gpios);
static const struct gpio_dt_spec led_blue = GPIO_DT_SPEC_GET(DT_ALIAS(led2), gpios);

int led_start(void);
void set_led_red(bool on);
void set_led_green(bool on);
void set_led_blue(bool on);

/**
 * @brief Set dim white LED (charging indicator).
 *        GPIO mode: on = all three LEDs on, off = all off.
 */
void set_led_white_dim(bool on);

/**
 * @brief Set dim green LED (charge complete indicator).
 *        GPIO mode: on = green on (others off), off = all off.
 */
void set_led_green_dim(bool on);

#endif
