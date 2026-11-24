#ifndef SETTINGS_H
#define SETTINGS_H

#include <stdint.h>

#ifdef CONFIG_SETTINGS

int app_settings_init(void);
int app_settings_save_dim_ratio(uint8_t new_ratio);
uint8_t app_settings_get_dim_ratio(void);

#else /* CONFIG_SETTINGS not enabled — no-op stubs */

static inline int app_settings_init(void) { return 0; }
static inline int app_settings_save_dim_ratio(uint8_t new_ratio) { (void)new_ratio; return 0; }
static inline uint8_t app_settings_get_dim_ratio(void) { return 50; /* default */ }

#endif /* CONFIG_SETTINGS */

#endif // SETTINGS_H
