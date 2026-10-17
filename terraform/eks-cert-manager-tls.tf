# =========================================================
# Yobi V1 - Let's Encrypt Wildcard TLS
# Route53 DNS-01 / cert-manager
# =========================================================

resource "helm_release" "msa_tls" {
  name      = "msa-tls"
  chart     = "${path.module}/charts/msa-tls"
  namespace = "soldesk"

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      acme = {
        email = var.acme_email
      }

      route53 = {
        region       = var.aws_region
        hostedZoneID = data.aws_route53_zone.sy84.zone_id
      }

      certificate = {
        namespace  = "soldesk"
        secretName = "server-sy84-store-tls"
        dnsNames   = ["*.sy84.store"]
      }
    })
  ]

  depends_on = [
    helm_release.cert_manager,
    kubernetes_namespace_v1.soldesk
  ]
}
