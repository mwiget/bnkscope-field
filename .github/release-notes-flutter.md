Built from `main` by the Flutter workflow: one codebase for macOS, iPadOS,
Windows and Android.

| Platform | File | How to install |
|---|---|---|
| macOS 15 or later | `bnkscope-Field-macOS.zip` | Unzip, drag to `/Applications`. Signed with Developer ID and notarized; the ticket is stapled in. |
| Windows 10 or later | `bnkscope-Field-windows.zip` | Unzip anywhere and run `bnkscope_field.exe`. Unsigned builds make SmartScreen warn once; choose *More info* → *Run anyway*. |
| Android 8 or later | `bnkscope-Field-android.apk` | Open on the device with sideloading allowed. `.aab` is the Play Store form of the same build. |
| iPadOS | TestFlight | Not a download: the build is uploaded to TestFlight when the workflow has the App Store secrets. |

### First run

The app talks to Kubernetes API servers on your own network. macOS and iPadOS
ask for **Local Network** permission; grant it, then relaunch, because the
permission is read only while a connection is being set up.

Then import your kubeconfigs from the sidebar. Nothing is bundled with the
app: it reads the same files `kubectl` does, keeps one file per context, and
presents the client certificate and key from the file directly, so nothing is
written to a keychain on any platform.
