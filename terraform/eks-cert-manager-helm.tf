
# =========================================================
# cert-manager - Let's Encrypt HTTPS 자동화
# Kubernetes 1.36 호환 버전
# =========================================================

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "oci://quay.io/jetstack/charts"
  chart      = "cert-manager"
  version    = "v1.21.2"

  namespace        = "cert-manager"
  create_namespace = true

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      crds = {
        enabled = true
      }
    })
  ]
}
