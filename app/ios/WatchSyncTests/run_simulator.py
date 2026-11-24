#!/usr/bin/env python3
"""Native watchOS regression: actual capture, programmatic navigation and interruptions.

This does not automate watch-face taps, real calls, wrist-down or hand gestures.
Use dedicated test simulators; microphone permission is revoked and restored here.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

IOS = Path(__file__).resolve().parents[1]
BUNDLE = "me.memorion.api.watchkitapp"


def run(*args, env=None):
    return subprocess.check_output(args, text=True, env=env, stderr=subprocess.STDOUT, timeout=60).strip()


def launch(device, **flags):
    env = {key: value for key, value in os.environ.items() if not key.startswith("SIMCTL_CHILD_MEMORION_")}
    env["SIMCTL_CHILD_MEMORION_SCREENSHOT"] = "1"
    env.update({f"SIMCTL_CHILD_{key}": value for key, value in flags.items()})
    run("xcrun", "simctl", "launch", "--terminate-running-process", device, BUNDLE,
        "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", env=env)


def screenshot(device, file):
    run("xcrun", "simctl", "io", device, "screenshot", str(file))


def capture_flow(device, container, output, flow, *, large_text=False):
    report = container / "Library/Caches/watch-simulator-flow.json"
    report.unlink(missing_ok=True)
    for stage in ("started", "marked", "moments", "detail", "queue", "quick-entry",
                  "interrupted", "resumed", "marked-again", "stopped", "saved-queue", "denied",
                  "deferred", "cancelled", "active-after-cancel", "queued-twice",
                  "foreground-started", "background-repeat", "foreground-repeat",
                  "control-started", "control-stale-stop", "control-stopped", "control-stop-again",
                  "control-restarted", "control-old-session", "control-bound-stopped",
                  "url-started", "url-repeated", "url-stopped",
                  "snapshot-started", "snapshot-inactive", "snapshot-prepared", "snapshot-restored",
                  "snapshot-late-task", "snapshot-marked", "snapshot-background", "snapshot-stopped",
                  "snapshot-prelaunch", "snapshot-foreground", "snapshot-restarted", "snapshot-new-stopped"):
        (output / f"{stage}.png").unlink(missing_ok=True)
    (output / "events.json").unlink(missing_ok=True)
    launch(device, MEMORION_SIM_FLOW=flow, MEMORION_SIM_LARGE_TEXT="1" if large_text else "0")
    # The initial idle image is taken before this flow starts. Wait for the
    # simulator compositor after each state snapshot to avoid stale frames.
    captured = {"idle"}
    deadline = time.monotonic() + 40
    terminal = "stopped" if flow == "permission-denied" else "saved-queue"
    while time.monotonic() < deadline:
        if report.exists():
            events = json.loads(report.read_text())
            if events:
                stage = events[-1]["stage"]
                if stage not in captured:
                    time.sleep(0.6)
                    latest = json.loads(report.read_text())
                    if latest[-1]["stage"] != stage:
                        continue
                    captured.add(stage)
                    print(f"{device}: {flow}/{stage}", flush=True)
                    screenshot(device, output / f"{stage}.png")
                if stage == terminal:
                    (output / "events.json").write_text(json.dumps(events, indent=2))
                    return events
        time.sleep(0.15)
    raise RuntimeError(f"Simulator flow did not reach {terminal}: {device}")


def validate_recording(events):
    phases = {event["stage"]: event for event in events}
    first = phases["started"]
    assert first["capturing"] and first["requested"] and first["sessionID"]
    for stage, route in (("moments", "moments"), ("detail", "detail"), ("queue", "queue"), ("quick-entry", "root")):
        event = phases[stage]
        assert event["capturing"] and event["requested"], stage
        assert event["route"] == route, (stage, event["route"])
        assert event["captureFile"] == first["captureFile"], "Navigation/quick entry restarted the mic"
        assert event["sessionID"] == first["sessionID"]
        assert event["pending"] == phases["idle"]["pending"], "Active capture appeared as saved"
    assert not phases["interrupted"]["capturing"] and phases["interrupted"]["requested"]
    resumed = phases["resumed"]
    assert resumed["capturing"] and resumed["requested"]
    assert resumed["sessionID"] == first["sessionID"]
    assert resumed["captureFile"] != first["captureFile"], "Interruption must preserve the previous segment"
    assert not phases["stopped"]["capturing"] and not phases["stopped"]["requested"]
    final = phases["saved-queue"]
    assert final["route"] == "queue"
    clips = [clip for clip in final["saved"] if clip["sessionID"] == first["sessionID"]]
    assert len(clips) == 2 and all(clip["duration"] > 0 for clip in clips)
    assert sum(clip["marks"] for clip in clips) == 2, "Marks were lost across interruption"
    assert final["pending"] == phases["idle"]["pending"] + 2
    return {"clips": clips, "capturedSeconds": sum(clip["duration"] for clip in clips)}


def validate_quick_entry_lifecycle(events):
    phases = {event["stage"]: event for event in events}
    for stage in ("deferred", "queued-twice"):
        event = phases[stage]
        assert event["requested"] and not event["capturing"] and not event["appActive"], stage
        assert not event["captureFile"] and event["sessionID"], stage
    for stage in ("cancelled", "active-after-cancel"):
        assert not phases[stage]["requested"] and not phases[stage]["capturing"], stage
    first = phases["foreground-started"]
    assert first["capturing"] and first["appActive"]
    assert first["sessionID"] == phases["queued-twice"]["sessionID"]
    for stage in ("background-repeat", "foreground-repeat"):
        event = phases[stage]
        assert event["capturing"] and event["requested"], stage
        assert event["captureFile"] == first["captureFile"], stage
        assert event["sessionID"] == first["sessionID"], stage
    assert not phases["background-repeat"]["appActive"]
    stopped = phases["stopped"]
    assert not stopped["requested"] and not stopped["capturing"]
    saved = [item for item in stopped["saved"] if item["sessionID"] == first["sessionID"]]
    assert len(saved) == 1 and saved[0]["duration"] >= 5, saved
    return {"segments": len(saved), "capturedSeconds": saved[0]["duration"],
            "deferredUntilForeground": True, "cancelBeforeForeground": True,
            "repeatedEntryPreservesCapture": True}


def validate_controls(events):
    p = {event["stage"]: event for event in events}
    first = p["control-started"]
    for stage in ("control-started", "control-stale-stop", "control-restarted", "control-old-session"):
        assert p[stage]["capturing"] and p[stage]["controlPhase"] == "recording", stage
    assert p["control-stale-stop"]["captureFile"] == first["captureFile"]
    for stage in ("control-stopped", "control-stop-again", "control-bound-stopped"):
        assert not p[stage]["requested"] and not p[stage]["capturing"], stage
        assert p[stage]["controlPhase"] == "idle", stage
    assert p["control-stop-again"]["pending"] == p["control-stopped"]["pending"]
    restarted = p["control-restarted"]
    assert restarted["sessionID"] != first["sessionID"]
    assert p["control-old-session"]["captureFile"] == restarted["captureFile"]
    assert p["control-bound-stopped"]["pending"] == p["idle"]["pending"] + 2
    return {"stopShortcut": "passed", "sessionBoundStop": "passed", "sharedWidgetState": "passed"}


def validate_shortcut_activation(events):
    p = {event["stage"]: event for event in events}
    for stage in ("pending-cancel", "pending-recovery", "pending-timeout", "timeout-preserved"):
        assert p[stage]["requested"] and not p[stage]["capturing"], stage
        assert not p[stage]["appActive"], stage
    assert "recovered" not in p["pending-recovery"]["shortcutResults"], "Start returned success before capture"
    assert p["result-previous-failure"]["shortcutResults"]["previous-failure"] == "failed"
    assert not p["result-previous-failure"]["capturing"]
    for stage in ("active-after-cancel", "background-stopped", "active-after-stop", "stopped"):
        assert not p[stage]["requested"] and not p[stage]["capturing"], stage
    assert p["result-cancelled"]["shortcutResults"]["cancelled"] == "failed"
    first = p["recovered-without-callback"]
    assert first["capturing"] and first["appActive"], "Lost callback recovery did not start microphone"
    for key in ("recovered", "duplicate", "background-repeat"):
        result = p["result-" + key]
        assert result["shortcutResults"][key] == "success" and result["capturing"], key
        assert result["captureFile"] == first["captureFile"], "Duplicate shortcut restarted capture"
    assert p["timeout-preserved"]["shortcutResults"]["timeout"] == "failed"
    assert p["late-foreground"]["capturing"], "Timeout discarded the user's persisted request"
    final = p["saved-queue"]
    assert not final["requested"] and not final["capturing"]
    clips = [clip for clip in final["saved"] if clip["sessionID"] == first["sessionID"]]
    assert len(clips) == 1 and clips[0]["duration"] >= 2, clips
    return {"missingSceneCallbackRecovery": "passed", "confirmedCaptureBeforeResult": "passed",
            "cancelPendingStart": "passed", "backgroundStop": "passed", "timeoutPreservesRequest": "passed",
            "retryAfterPreviousFailure": "passed"}


def validate_control_urls(events):
    p = {event["stage"]: event for event in events}
    assert p["url-started"]["capturing"] and p["url-started"]["controlPhase"] == "recording"
    assert p["url-repeated"]["captureFile"] == p["url-started"]["captureFile"]
    assert not p["url-stopped"]["requested"] and not p["url-stopped"]["capturing"]
    assert p["url-stopped"]["controlPhase"] == "idle"
    assert p["url-stopped"]["pending"] == p["idle"]["pending"] + 1
    return "Production URL handler passed; simctl Watch URL delivery unavailable (LS error 115)"


def validate_launch_snapshot(events):
    p = {event["stage"]: event for event in events}
    first = p["snapshot-started"]
    assert first["capturing"] and first["sessionID"] and not first["showsLaunchSnapshot"]
    for stage in ("snapshot-inactive", "snapshot-prepared", "snapshot-restored", "snapshot-late-task",
                  "snapshot-marked", "snapshot-background"):
        event = p[stage]
        assert event["capturing"] and event["requested"], stage
        assert event["captureFile"] == first["captureFile"], "Snapshot presentation restarted the mic"
        assert event["sessionID"] == first["sessionID"], stage
        assert event["elapsed"] >= first["elapsed"], "Snapshot presentation reset recording duration"
    for stage in ("snapshot-prepared", "snapshot-background", "snapshot-stopped", "snapshot-prelaunch"):
        assert p[stage]["showsLaunchSnapshot"], stage
    for stage in ("snapshot-inactive", "snapshot-restored", "snapshot-late-task", "snapshot-foreground"):
        assert not p[stage]["showsLaunchSnapshot"], stage
    stopped = p["snapshot-stopped"]
    assert not stopped["capturing"] and not stopped["requested"] and stopped["elapsed"] == 0
    restarted = p["snapshot-restarted"]
    assert restarted["capturing"] and restarted["requested"] and not restarted["showsLaunchSnapshot"]
    assert restarted["sessionID"] != first["sessionID"] and restarted["elapsed"] < 3
    final = p["saved-queue"]
    assert not final["capturing"] and not final["requested"] and final["elapsed"] == 0
    clips = [clip for clip in final["saved"] if clip["sessionID"] in (first["sessionID"], restarted["sessionID"])]
    assert len(clips) == 2 and all(clip["duration"] > 0 for clip in clips), clips
    assert sum(clip["marks"] for clip in clips) == 1, "Snapshot presentation lost the mark"
    return {"neutralSnapshot": "passed", "activeRestore": "passed", "wristDownKeepsLiveUI": "passed",
            "lateTaskCannotCoverActiveUI": "passed", "microphoneContinuity": "passed", "clips": clips}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--snapshot-only", action="store_true", help="Run only the launch snapshot regression")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "summary.json").unlink(missing_ok=True)
    if not args.skip_build:
        with (args.output / "build.log").open("w") as log:
            subprocess.run(["xcodebuild", "-project", str(IOS / "Runner.xcodeproj"), "-target", "MemorionWatch",
                            "-configuration", "Debug-dev", "-sdk", "watchsimulator", "CODE_SIGNING_ALLOWED=NO", "build"],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    available = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
    watches = {device["udid"]: device for runtime, devices in available.items()
               if "watchOS" in runtime for device in devices}
    results = {}
    for index, device in enumerate(args.device):
        assert device in watches, f"Expected a watchOS simulator: {device}"
        output = args.output / device
        output.mkdir(exist_ok=True)
        if watches[device]["state"] != "Booted":
            run("xcrun", "simctl", "boot", device)
        run("xcrun", "simctl", "bootstatus", device, "-b")
        app = IOS / "build/Debug-dev-watchsimulator/MemorionWatch.app"
        for bundle in (app / "PlugIns/MemorionWatchWidgets.appex", app):
            run("codesign", "--force", "--sign", "-", "--entitlements",
                str(IOS / "MemorionWatch/WatchControls.entitlements"), str(bundle))
        run("xcrun", "simctl", "install", device, str(app))
        run("xcrun", "simctl", "privacy", device, "grant", "microphone", BUNDLE)
        try:
            launch(device)
            time.sleep(1)
            container = Path(run("xcrun", "simctl", "get_app_container", device, BUNDLE, "data"))
            screenshot(device, output / "idle.png")
            if args.snapshot_only:
                events = capture_flow(device, container, output, "launch-snapshot")
                results[device] = {"device": watches[device]["name"], **validate_launch_snapshot(events)}
                print(f"PASS: {watches[device]['name']} launch snapshot", flush=True)
                continue
            events = capture_flow(device, container, output, "recording")
            results[device] = {"device": watches[device]["name"], **validate_recording(events)}
            lifecycle_output = output / "quick-entry-lifecycle"
            lifecycle_output.mkdir(exist_ok=True)
            lifecycle = capture_flow(device, container, lifecycle_output, "quick-entry-lifecycle")
            results[device]["quickEntryLifecycle"] = validate_quick_entry_lifecycle(lifecycle)
            for flow, validator, key in (("recording-controls", validate_controls, "recordingControls"),
                                          ("shortcut-activation", validate_shortcut_activation, "shortcutActivation"),
                                          ("control-urls", validate_control_urls, "controlURLs"),
                                          ("launch-snapshot", validate_launch_snapshot, "launchSnapshot")):
                flow_output = output / flow
                flow_output.mkdir(exist_ok=True)
                results[device][key] = validator(capture_flow(device, container, flow_output, flow))
            denied_output = output / "permission-denied"
            denied_output.mkdir(exist_ok=True)
            run("xcrun", "simctl", "privacy", device, "revoke", "microphone", BUNDLE)
            denied = capture_flow(device, container, denied_output, "permission-denied")
            denied_phases = {event["stage"]: event for event in denied}
            assert not denied_phases["denied"]["capturing"]
            assert denied_phases["permission-result"]["shortcutResults"]["permission"] == "failed"
            assert denied_phases["denied"]["controlPhase"] == "unconfirmed"
            assert not denied_phases["stopped"]["requested"]
            assert denied_phases["stopped"]["controlPhase"] == "idle"
            assert denied_phases["stopped"]["pending"] == denied_phases["idle"]["pending"]
            results[device]["permissionDenied"] = "passed"
        finally:
            run("xcrun", "simctl", "privacy", device, "grant", "microphone", BUNDLE)
        if index == 0:
            large = output / "large-text"
            large.mkdir(exist_ok=True)
            events = capture_flow(device, container, large, "recording", large_text=True)
            results[device]["largeText"] = validate_recording(events)
            previews = output / "widget-view-previews"
            previews.mkdir(exist_ok=True)
            for configuration in ("idle:rectangular:adaptive", "recording:rectangular:adaptive",
                                  "paused:rectangular:adaptive", "unconfirmed:rectangular:adaptive",
                                  "interrupted:rectangular:adaptive", "interrupted:circular:adaptive",
                                  "recording:circular:adaptive", "idle:circular:start",
                                  "recording:circular:stop", "recording:inline:adaptive"):
                launch(device, MEMORION_WIDGET_PREVIEW=configuration)
                time.sleep(1)
                screenshot(device, previews / (configuration.replace(":", "-") + ".png"))
            results[device]["widgetViewPreviews"] = "Production SwiftUI view in app harness; not clock-face hosting"
        print(f"PASS: {watches[device]['name']}", flush=True)
    (args.output / "summary.json").write_text(json.dumps(results, indent=2))
    print(f"Saved screenshots and native snapshots to {args.output}", flush=True)


if __name__ == "__main__":
    main()
