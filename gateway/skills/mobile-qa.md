---
name: Mobile QA
description: Test iOS and Android apps: device matrix, Maestro/XCUITest/Espresso tests, interruptions, offline, accessibility and store readiness
triggers: test the app, mobile test, ios test, android test, maestro, appium, xcuitest, espresso, detox, testflight, device testing, app store review, crash
---
Work like a senior mobile QA engineer.

1. **Scope.** Platforms and minimum OS versions, native or cross-platform (SwiftUI/UIKit, Kotlin/Compose, React Native, Flutter), the critical journeys, and how builds are shared (TestFlight, Firebase App Distribution, simulator build).
2. **Device matrix.** Smallest and largest screen per platform, oldest supported OS, one low-memory Android, notch/Dynamic Island, tablet if supported. Say which can be simulators and which need real devices (camera, push, Bluetooth, performance, biometrics).
3. **Mobile-specific cases** for every critical journey:
   - Interruptions: incoming call, notification, app backgrounded and killed mid-flow, low battery mode.
   - Network: offline, airplane mode toggled mid-request, slow 3G, captive portal; check retries and that no data is lost.
   - Lifecycle and state: rotation, split view, dark mode, large Dynamic Type / font scale 200%, language with long words (German) and RTL (Arabic).
   - Permissions: denied, "ask next time", revoked in Settings while the app is open.
   - Deep links and push notifications opening the right screen, logged in and logged out.
   - Upgrade from the previous store version with existing data; fresh install; reinstall.
4. **Automate** with Maestro flows by default (YAML, works on both platforms and React Native/Flutter); use XCUITest (iOS) or Espresso/Compose testing (Android) when the team already does. Use accessibility identifiers, not coordinates or text that gets translated. Show how to run locally and in CI.
   - Maestro: `id:` selectors (`testID` / `accessibilityIdentifier`), reusable sub-flows (`runFlow: login.yaml`) with `env:` parameters, `launchApp: clearState: true` so flows don't depend on each other, `retry` (max 3) only around steps you don't control such as system dialogs, `maestro studio` to find selectors and `maestro test --format junit` in CI.
   - Detox (React Native): it waits for the app to be idle by itself, so never `sleep`; if it hangs, `debugSynchronization` shows what keeps it busy.
   - Track flows that only pass on retry and fix them; retries hide bugs.
   - Handy commands: `xcrun simctl openurl booted <deeplink>`, `simctl push`, `simctl privacy booted grant|revoke`, `simctl status_bar override` for clean screenshots; `adb shell am start -d <deeplink>`, `adb shell svc wifi disable`, `adb shell am kill <pkg>`, and Android's "Don't keep activities".
5. **Accessibility:** VoiceOver/TalkBack labels and reading order, touch targets ≥44 pt / 48 dp, contrast, Reduce Motion, and no information conveyed by colour alone.
6. **Privacy and data-safety basics (OWASP MASVS):** tokens stored in Keychain/Keystore (not UserDefaults/SharedPreferences), nothing sensitive in logs or the app-switcher snapshot, TLS for all traffic.
7. **Performance and stability:** cold start time, scrolling jank on long lists, memory on the low-end device, battery drain over 30 minutes of use, crash-free sessions (Crashlytics/Sentry). Tools: Xcode Instruments (Time Profiler, Leaks), `adb shell dumpsys gfxinfo <pkg>` for jank, Macrobenchmark for cold start, Firebase Test Lab or BrowserStack for real devices.
8. **Store readiness:** privacy labels and permission strings match what the app does, account deletion exists if sign-up does, no placeholder content, screenshots match the build.

Report bugs with: device + OS + build number, steps, expected vs actual, video or screenshot, and logs (Xcode console / `adb logcat`). End with a release verdict and the riskiest untested area.
