# ChipletRing interoperability provenance

The iOS adapter uses Apple's CoreBluetooth and a Memorion implementation of
raw IMA ADPCM. It does not import, link, bundle, or redistribute BCLRingSDK.
Its only CocoaPods dependency is Flutter. Existing device transports and the
application's iOSDFULibrary dependency retain their original implementations.

## Reference material

- Vendor documentation: https://yongxin.gitbook.io/yongxin-docs
- Public SDK/Demo repository: https://github.com/BravechipSpace/ChipletRing-APPSDK
- Reference revision: `ab64c550df48074cdd3c3e4c9a80a267bdca41c4`.
- Reference iOS binary: BCLRingSDK 1.2.6,
  `IOS/library/BCLRingSDK_New/iOS_New_Framework_1.2.6/BCLRingSDK.xcframework`.
- Test hardware: BCL603, 603V1.23.2, firmware 6.0.1.8Z62.
- Recording feedback: vendor smart-ring vibration/alarm documentation,
  `documentation/zhi-neng-jie-zhi-sdk-shi-yong/zhen-dong-nao-zhong`;
  public Android SET/GET_RING_MOTOR_MODE command fields (0x8D02/0x8E02).
- Health: vendor history documentation `documentation/zhi-neng-jie-zhi-sdk-shi-yong/interactive-blocks`
  and health chart catalogue `documentation/gong-neng-zong-lan/jian-kang-tong-ji-tu-she-ji`;
  public Android history field offsets and dynamic extension widths.
- Time: public protocol guide `documentation/zhi-neng-jie-zhi-sdk-shi-yong/xie-yi-kai-fa-zhi-nan`,
  including its UTC Unix-millisecond / signed whole-hour timezone example.

The public Android BLE service supplies the GATT service/write/notify UUIDs.
A BCL603 scan contained HID service 1812, no advertised
local name, and manufacturer bytes `11ff followed by six address bytes`. Discovery accepts this
exact eight-byte vendor/MAC layout together with HID, or the existing BCL name
and recording-service routes. It exposes the vendor-encoded MAC; this is not
a hardware address obtained from Apple's CoreBluetooth API. Unrelated HID
devices and malformed/empty manufacturer addresses are excluded by tests.
Generated commands from the SDK were compared with independent command
builders. Packet fields were checked against notifications from a BCL603. Standard IMA decoding was independently implemented, then compared
with vendor mono/stereo outputs covering every nibble and continuing state
across packets. Synthetic oracle data is in `tests/decoder-oracle.json`.
No vendor binary or disassembled code is included in this plugin.

## Scope and verification

`RingProtocol.swift` checks lengths, sequence continuity, duplicates, counts
and directory sizes. `RingAudio.swift` writes incomplete audio as `.part`,
publishes a WAV only after validation, and cleans interrupted partials.
`ChipletRingPlugin.swift` owns a separate central and only handles ring
peripherals. Z62 uses command 0x7101 and emits mono 0x7108 audio; stopping has
no firmware reply, so the adapter waits for the GATT write and buffered audio.
The observed Z62 battery response also contains 101, an undocumented value.
Values above 100 are exposed as unknown (-1), without invalidating a healthy
connection; malformed battery payload lengths still fail validation.
Initial battery queries are published to listeners. Cached values, native pushes
and foreground idle polling feed the same stream; old connection results are
discarded. Background, capture and transfer periods skip routine polling.
Notification subscription is followed by a three-second readiness wait;
Dart commands are serialized with 300 ms spacing after both success and failure.

Hardware 1.23 recording feedback is configured before readiness. It now uses
the vendor's style 2: one long vibration for start and two long vibrations for
stop, instead of the previously tested style 1 short vibrations. The observed
6.0.1.8Z62 firmware receives GATT-acknowledged SET_RING_MOTOR_MODE writes but did not answer
GET_RING_MOTOR_MODE within 30 seconds. For Z62, both setting writes must receive
GATT acknowledgments; readbackVerified remains false. Other firmware retains
strict readback. Physical testing recorded no vibration for recording start/stop, both
immediate-vibration formats or find-ring tests, and no light change for find-ring.
These acknowledgments do not establish firmware acceptance or motor capability.
A green light appeared during manual recording. Further testing with style 2
long feedback produced no vibration. Both short and long settings
have therefore failed physical acceptance on this ring; motor presence, firmware
support and any required enable condition remain unresolved. The transmitted
0x8D/0x02 payloads match the public documentation and Android Lite SDK implementation.
The health query uses seven-day ALL history (0x3601), preserving the vendor's
unuploaded cursor. Invalid/unworn records are omitted; respiration is read only
from its actual extension, never derived from heart rate. Values and timestamps
remain local to the device-detail snapshot. The feature catalogue does not
claim that every sensor or vendor cloud algorithm is available. Temperature
scale and vendor-only calculated metrics remain explicitly unresolved.
The Z62 seven-day history query previously timed out; actual health readings
have not been accepted on this device. The details UI offers one-click reading
of all available stored metrics. Expanding health triggers a read, followed by
five-minute refreshes while that route is current and the app is in the foreground.
Recording/import defers reads; missed intervals coalesce into one request. Manual
reads restart the interval. Collapse, disconnection, account loss and disposal
prevent automatic requests. A failed refresh labels any retained snapshot with
its last successful read time. This reads history, without starting measurements
or uploading health data. APP_BIND (which clears health/steps) and cursor-changing
composite connect/refresh commands are not used as initialization shortcuts.
The details UI now retains a failed health request across timeout-triggered BLE
loss, distinguishing it from a successful empty response. Skin contact and the
collection interval may affect samples, but wearing longer is not a verified
solution to the Z62 timeout or the missing vendor algorithms.

The ring recording page uses the existing Soundcore recorder cards, headings,
pagination, refresh summary, processing link and byte-percent progress rings.
Live capture displays its start timestamp and elapsed mm:ss. Offline device
calendar strings are displayed as unconfirmed; they never become an upload
timestamp until the owner confirms them. Malformed calendar strings are rejected.

Clock calibration is manual and shares the recording/transfer maintenance lock.
SET/GET readback must agree on UTC milliseconds within five seconds and on the
signed whole-hour timezone; fractional timezones, malformed replies and stale
connection/account results fail. Protocol fixtures pass, but Z62 physical
calibration remains unverified, so no automatic time write is performed.

Supported audio formats: mono 8/B at 8 kHz and stereo D at 16 kHz. The mono
Z62 format has an accepted real audio fixture. Stereo D has synthetic codec
coverage; it still needs an appropriate physical device recording. Unknown
formats, standalone offline recording control and firmware OTA are excluded.
The firmware status dialog explicitly reports that OTA is not integrated and
updates have not been checked. A matching hardware firmware package, vendor
authorization and verified Apollo/Nordic/PHY upgrade and recovery implementation
are required. Android native transport, full capability/HID/SN discovery and
vendor cloud algorithms remain outside the implemented adapter.

## Earlier vendor dependency conflict

The initial vendor-based adapter produced duplicate Objective-C runtime
classes from NordicDFU, RxSwift, SwiftDate, Foil, SwiftyBeaver and ZIPFoundation
embedded in BCLRingSDK and linked separately by Memorion. Shared CocoaPods
declarations could not remove the embedded copies. Public issue #34 reports
the same packaging problem; the public installation guide documents Swift
compiler compatibility, but no runtime duplicate-class fix.

The vendor-based adapter and binary have been removed from the build. Private
diagnostic copies remain outside tracked source. The SDK's redistribution
terms were not established; this adapter does not distribute that SDK.
