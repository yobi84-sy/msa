
# =========================================================
# cert-manager - Let's Encrypt HTTPS 자동화
# Kubernetes 1.36 호환 버전
# =========================================================

resource "helm_release" "cert_manager" {
  name            = "cert-manager"
  repository      = "oci://quay.io/jetstack/charts"
  chart           = "cert-manager"
  version         = "v1.21.2"
  upgrade_install = true

  namespace        = "cert-manager"
  create_namespace = true

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      crds = {
        enabled = true
      }

      serviceAccount = {
        create = true
        name   = "cert-manager"

        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.cert_manager.arn
        }
      }
    })
  ]

  # EKS Worker Node 및 필수 Add-on 준비 후 설치
  depends_on = [
    aws_eks_node_group.main,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.coredns,
    aws_eks_addon.kube_proxy,
    aws_iam_role_policy_attachment.cert_manager,
    helm_release.alb_controller
  ]
}
