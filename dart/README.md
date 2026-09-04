# bnkscope Field, the Dart side

A pub workspace. `dart pub get` here resolves every package.

| package | what | tests |
|---|---|---|
| `bnk_kit` | transport: kubeconfig, mutual TLS from PEM, REST, logs, exec, port-forward, the models; the `bnkfield` CLI | 71 |
| `bnk_engines` | one engine per screen, pure Dart, watched through `Observable.changes` | 27 |

See `bnk_kit/README.md` for the transport, and the top-level `CLAUDE.md`
for the rules the layering follows.
