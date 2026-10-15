# Zoop 2.0 — Goal-based smart alarm (experimental)

The sleep planner's alarm can wait for a goal inside a wake window instead of ringing at one fixed
time: **At a fixed time** (the classic alarm, optionally earlier in light sleep), **Sleep need
reached**, or **Recovery reached (≥ X, default 67 = green)**. Example: "if my recovery reaches 80,
wake me between 06:30 and 06:50".

## How WHOOP does it (research, October 2026)

- WHOOP's Sleep Planner has the same three modes: *Exact Time*, *Sleep Goal* (100 / 85 / 70 % of
  the need) and *In the Green* (wake once recovery is green). The goal modes take a latest wake time,
  and the alarm fires in a window before it (users report a fixed 1-hour window).
  Sources: [Wareable, WHOOP alarms explained](https://www.wareable.com/wearable-tech/how-to-set-an-alarm-on-whoop-4),
  [WHOOP: Sleep Coach with haptic alerts](https://www.whoop.com/thelocker/new-whoop-4-0-feature-sleep-coach-with-haptic-alerts),
  [WHOOP community: Smart Recovery Alarm](https://www.community.whoop.com/t/smart-recovery-alarm/14616),
  [WHOOP community: sleep-goal alarm window](https://www.community.whoop.com/t/feature-request-whoop-sleep-goal-alarm-with-unbounded-time-window/14636.md).
- The buzz itself is a haptic on the strap, and WHOOP describes it as working without the phone's
  sound. **What decides "goal reached" is not documented.** Community replies say the app should be
  open in the background with the strap connected and Bluetooth on overnight, and WHOOP staff advise a
  phone alarm as a backup and > 10 % battery. Sources:
  [WHOOP community: alarm not working](https://www.community.whoop.com/t/whoop-alarm-not-working/13508),
  [WHOOP community: haptic alarm strength](https://www.community.whoop.com/t/haptic-alarm-strength/1692.md?page=2).
- Users report the green-recovery mode does not look for light sleep; a sleep-phase alarm is a
  feature request. These are community reports, not specifications.

Reading: the goal modes are most likely app-driven (the app computes the goal from synced data and
moves the strap's alarm), with the latest wake time armed on the strap as the fallback. That is the
design Zoop uses too.

## Zoop's design

- **Deadline invariant.** The strap's firmware alarm is armed at the **window end** all night, through
  the same `ble.armStrapAlarm(at:)` path as before. No new strap command; only that arm and the existing
  sync request are used.
- **Checks.** From the window start, every 3 minutes, `SmartWakeWindow` asks for a sync, waits up to
  75 s for it, then reads the night so far (`SmartWakeProbe`):
  - asleep minutes since tonight's sleep onset, from `SleepStager.detectSleep` on the data synced so far
    (`NightProgress.tonight`), against tonight's sleep need × the planner's goal (100 / 85 / 70 %), the
    same need the Tonight card uses (`SmartWakeProbe.needTonight`);
  - a **partial-night recovery estimate** (`PartialNightRecovery`, StrandAnalytics): the same
    `RecoveryScorer` with the inputs available mid-night (HRV and resting HR so far vs the personal
    baselines, sleep sufficiency so far). No respiration, no skin temperature, at least 90 min asleep.
    It is an estimate, not the morning score;
  - the light-sleep signal (`SmartWake.lightSleepSignal`: movement or heart rate rising off the
    night's low).
- **Decision** (`GoalWake.decide`, pure, tested): goal met and (light sleep, or 10 min into the window,
  or light sleep not preferred) → arm the strap at **now + 30 s, once**. Never before the window
  start, never within 2 min of the deadline. *At a fixed time* with a window only moves earlier on
  light sleep (the former "Gentle wake").
- **After an early wake.** The strap holds one alarm instant, so the early arm replaces the deadline.
  If the strap's own "alarm executed" event (57) arrives, this morning is done and the next day's
  alarm is armed. If it does not arrive within 90 s of the early wake, the deadline is armed again, so
  a missed early buzz still leaves the window end. A missed event 57 can mean a second buzz at the
  window end; that is the safe side.
- **Background time.** Each check holds a short iOS background task (about 30 s). A check also runs
  as soon as the app is woken inside the window (Bluetooth restore, a background sync finishing,
  foreground) when none ran for a full interval.

## Reliability limits

- Earlier waking needs the app to **run during the window**: iOS must keep Zoop alive or wake it
  (Bluetooth background mode), and the strap must be in range. If iOS suspends the app, timers do not
  fire and no check runs; the strap still rings at the window end.
- A WHOOP 5/MG arms its firmware alarm only with Protocol probes on (Test Centre), as before.
- Mid-night sleep detection on a still-open night, and the estimate's agreement with the morning
  recovery, are **unvalidated on hardware**. Treat early wakes as experimental.

## Reading the diagnostics (Test Centre › Smart alarm nights)

Every night with an alarm is written to `Application Support/SmartAlarm/nights.json` (last 30 nights,
readable while the phone is locked). The list shows, per night:

| Status | Meaning |
|---|---|
| ✓ App was active and could decide | Every planned check up to the decision ran. |
| ⚠ App ran for part of the window | Some checks ran, some did not. |
| ✗ App didn't run in the window | No check ran; only the strap's deadline could wake you. |

The summary reads "In N of M nights the app could act" (nights with at least one check in the window).
The night's timeline lists: each strap arm (and whether it went out or was queued with no strap
connection), the arm readback when it is attributable to the same strap and arm (`AlarmReadback`),
app foreground / background, background launches, Bluetooth restores, finished syncs, every check
(planned slot, actual time, sync result, strap connected, age of the newest heart-rate sample, asleep
vs need, recovery estimate, light-sleep signal, decision), each planned check that never ran
("missed – app not running"), the early wake, and the strap's fire report.

The planner shows the morning's result in one line: *"Today: woken at 06:41 – sleep need reached"*
only when the strap reported firing; otherwise *"alarm moved to 06:41"*, *"window end 06:50 – goal not
reached"* or *"window end 06:50 – the app wasn't running at night"*.

## What needs a real night to validate

1. Does iOS keep the app running (or wake it) inside the window with the phone locked, strap in range?
   The nights page answers this directly.
2. Does `detectSleep` find the open session mid-night, and do asleep minutes match the morning's total?
3. Does the recovery estimate land near the morning recovery on nights with different recoveries?
4. Does the strap buzz at the early-wake instant, and does event 57 arrive (WHOOP 4.0 vs 5/MG)?
