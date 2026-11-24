# Firmware projects

| Project | Source and setup |
| --- | --- |
| Omi | [nRF5340 build instructions](omi/firmware/omi/README.md). Uses nRF Connect SDK 2.9.0 and the `omi/nrf5340/cpuapp` board target. |
| DevKit | [DevKit sources and presets](omi/firmware/devkit/). Choose the preset that matches your board revision. |

For Omi builds that use MCUboot signing, generate your own signing key and supply it at `omi/firmware/bootloader/mcuboot/root-rsa-2048.pem`, or update the local sysbuild configuration to use a key outside this checkout. Keep the key out of Git. Use signing and update procedures appropriate to your board and bootloader.
