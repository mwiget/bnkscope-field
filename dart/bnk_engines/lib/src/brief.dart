/// One line, for a row in a list. The whole error belongs in a log.
String brief(Object error) {
  final text = error.toString();
  return text.length > 80 ? '${text.substring(0, 80)}…' : text;
}

/// `dpu-cplane-tenant1-tmm-g6lx4-f5-tmm-dhm72` → `dhm72`. The prefix is the
/// same on every pod in a cluster and only costs legend width.
String shortPodName(String pod) => pod.split('-').last;
