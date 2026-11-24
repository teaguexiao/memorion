# Watch receipt recovery tests

Run from the repository root:

```sh
bash app/ios/WatchSyncTests/run.sh
```

The runner compiles the production `WatchTransfer`, `WatchSessionService`,
`PendingRecordingStore` and shared receipt code. Only WatchConnectivity transport
and the Flutter channel are replaced with deterministic doubles. Fixtures use
private temporary directories and isolated UserDefaults suites; no account, audio
recording, cloud service or attached device is accessed.

Coverage includes lost receipts for already uploaded recordings, cancellation of
redundant transfers, malformed/legacy replies, protection of unfinished files,
unknown-file retries, offline metadata requests, failed copies, duplicate file
receipt, inactive sessions, persisted acknowledgements across service recreation,
failed delivery, history retention, batching, failed cleanup, concurrent receipt
updates, off-main copying, bounded receipt queues and audio retry backoff.

Automatic audio retries use a finite budget (at most three per foreground/manual
recovery cycle, with backoff). Receipt-only queries can continue. At most 50
acknowledgements are outstanding in the system queue; unsent receipts remain
persisted and are not expired while the Watch may still need them.
Once a receipt is confirmed, failed Watch cleanup also retries locally on a
foreground timer or nudge, even if the phone is offline.

These tests do not demonstrate real WatchConnectivity delivery. Also build the
watchOS target and typecheck/build the iPhone source against Apple's SDKs. A paired
physical iPhone and Watch are required for final end-to-end acceptance.

## Recording controls

The pure native runner also compiles `WatchRecordingControlState`: state publication,
idempotent writes, session-bound stop URLs, live owner lease, process termination,
corrupt data, and unavailable shared container.

`run_simulator.py` exercises actual AVAudioRecorder and Start/Stop intents, invokes
the production start/stop URL handler, and verifies shared App Group state and stale-session
protection. It captures production widget views in an app preview harness. These
screenshots do not verify real watch-face placement, tap routing, or refresh timing.
Watch simctl URL delivery failed with LSApplicationWorkspace error 115; URL routing
checks invoke the same handler used by SwiftUI onOpenURL without claiming OS delivery.

On a paired Watch, add the adaptive Memorion Recording complication. Start from idle,
confirm the stop icon after refresh, then stop and confirm a saved recording. Also
add the separate Start and Stop complications and test repeated commands. Run the
Stop shortcut from Watch Shortcuts and a separately configured AssistiveTouch gesture.
Check interruption/pending-resume cancellation. WidgetKit controls refresh latency;
an outdated stop icon must not stop a newer recording session.

## On-device acceptance

1. Install the updated iPhone and embedded Watch companion together.
2. Open both apps with the devices nearby. Previously uploaded recordings retained
   on the Watch should clear after the phone answers the receipt query, without
   creating duplicate conversations. Check `[WatchSession] receipt reconciliation`
   and `[WatchTransfer] iPhone confirmed` logs.
3. Disconnect while recording, stop, and reopen/reconnect. Unconfirmed files must
   remain until the phone actually saves them; active recordings must never clear.
4. Restart the phone app with an outstanding receipt. Confirmation should resume
   on activation, reachability changes or a Watch query.
5. The Watch queue label must say queued, not sending. A queued count is not byte
   progress or proof of delivery.

Reconciliation uses exact recording filenames and the phone's existing inbox,
rejected-file storage or handled-recording history. It does not query cloud
accounts. If the iPhone app was uninstalled and its local receipts were erased,
keep the Watch copy and use the normal transfer path; cloud presence alone is not
used as permission to delete a Watch recording.
