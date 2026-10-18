resource "helm_release" "argocd_web" {
  name       = "argocd-web"
  chart      = "${path.module}/charts/argocd-web"
  namespace  = "argocd"
  wait       = true
  timeout    = 600
  depends_on = [helm_release.argocd, helm_release.nginx_ingress, helm_release.msa_tls]
}
