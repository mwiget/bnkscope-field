# bnk_kit

The transport layer of bnkscope Field, in Dart, so that one codebase serves
iPadOS, macOS, Windows and Android. It is a port of the Swift `BNKKit`
package and keeps its shape: everything reaches a cluster through the
apiserver, and nothing here knows about a screen.

What is different from the Swift original is the one thing that had to be:
TLS. The client certificate and key go to the TLS stack as the PEM bytes the
kubeconfig carries, and the cluster's CA is pinned the same way. No keychain
on any platform, so the `PRIVATE_KEY_OPERATION_FAILED` trap in `CLAUDE.md`
does not apply: `bnkfield` can be pointed at the kubeconfig the app uses.

```bash
cd dart/bnk_kit
dart pub get
dart analyze
dart test                                  # 71 cases, no cluster needed
dart run bin/bnkfield.dart contexts ~/.kube/config
dart run bin/bnkfield.dart probe ~/.kube/config my-context
dart compile exe bin/bnkfield.dart -o bnkfield
```

`test/transport_test.dart` stands up a fake apiserver on loopback with the
throwaway certificates in `test/fixtures/tls/` and drives mutual TLS, the CA
pin, the `tls-server-name` override, a held port-forward tunnel reading a
gzipped chunked reply, `exec`, and a followed log over real sockets.

One platform fact worth knowing: on macOS and iOS, Dart verifies certificate
chains through Security.framework, which refuses a TLS server certificate
valid for more than 825 days. The Swift app evaluated trust the same way, so
real clusters already live under this rule; it only matters for test
fixtures, which is why the ones here are issued for 800 days.
