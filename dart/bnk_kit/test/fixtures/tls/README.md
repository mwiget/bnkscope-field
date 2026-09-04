Throwaway TLS material for the transport tests: a CA, a server certificate
for the name `apiserver.test`, and a client certificate, all EC P-256 with
SEC1 `EC PRIVATE KEY` keys, which is the shape k3s and microk8s issue and the
one that used to need platform-specific handling. Generated with openssl for
the tests only; nothing here has ever been near a real cluster. Named `.txt`
so the repository's ban on `*.pem` / `*.key` / `*.crt` files still catches a
real credential.

The leaf certificates are valid for 800 days, not ten years. On macOS and
iOS Dart verifies chains through Security.framework, which refuses a TLS
server certificate valid for more than 825 days; the Swift app evaluated
trust the same way, so this is the policy real clusters already live under.
