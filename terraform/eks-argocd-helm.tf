# =========================================================
# Yobi V1 - ArgoCD Installation
# Terraform manages ArgoCD infrastructure.
# ArgoCD manages application deployments.
# =========================================================

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.10.3"
  namespace        = "argocd"
  create_namespace = true

  wait            = true
  timeout         = 900
  atomic          = true
  cleanup_on_fail = true

  depends_on = [
    aws_eks_node_group.main
  ]
}