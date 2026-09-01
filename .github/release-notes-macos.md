Built from `main`. Universal (Apple Silicon and Intel), macOS 15 or later.
Signed with Developer ID and notarized by Apple.

**Download** `bnkscope-Field-macOS.zip` below — or always the newest from
<https://github.com/mwiget/bnkscope-field/releases/latest/download/bnkscope-Field-macOS.zip>

Unzip it and drag it to `/Applications`. It opens normally: the notarization
ticket is stapled into the app, so it is accepted even on a Mac that is offline
when you first run it.

### First run

The app talks to Kubernetes API servers on your own network, so macOS asks for
**Local Network** permission. Grant it, then **relaunch**: the permission is
only read while a connection is being set up, so granting it to an app that is
already running changes nothing until it restarts.

Then add your kubeconfigs on the Clusters screen. Nothing is bundled with the
app — it reads the same files `kubectl` does.
