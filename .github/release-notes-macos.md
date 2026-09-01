Built from `main`. Universal (Apple Silicon and Intel), macOS 15 or later.

**Download** `bnkscope-Field-macOS.zip` below — or always the newest from
<https://github.com/mwiget/bnkscope-field/releases/latest/download/bnkscope-Field-macOS.zip>

### First run

This build is ad-hoc signed and not notarized, so a browser download carries a
quarantine flag and macOS will refuse to open it. Either:

- **System Settings → Privacy & Security**, find the blocked app, **Open Anyway**; or
- `xattr -dr com.apple.quarantine "/Applications/bnkscope Field.app"`

Copying it across with `scp`, `rsync` or a USB drive sets no quarantine flag at
all, and it opens normally.

### Then

The app talks to Kubernetes API servers on your own network, so macOS asks for
**Local Network** permission. Grant it, then **relaunch**: the permission is
only read while a connection is being set up, so granting it to a running app
changes nothing until it restarts. Add your kubeconfigs on the Clusters screen.
