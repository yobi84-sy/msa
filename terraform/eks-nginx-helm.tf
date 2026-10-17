# =========================================================
# F5 NGINX Ingress Controller + AWS NLB
# 기존 NGINX 기반 MSA 배포 구조 재현
# =========================================================

resource "helm_release" "nginx_ingress" {
  name       = "nginx-ingress"
  repository = "oci://ghcr.io/nginx/charts"
  chart      = "nginx-ingress"
  version    = "2.6.4"

  namespace        = "nginx-ingress"
  create_namespace = true

  wait    = true
  timeout = 600

  # 기존 MSA는 Kubernetes Ingress API만 사용
  skip_crds = true

  values = [
    yamlencode({
      controller = {
        reportIngressStatus = {
          enable = true
        }
        replicaCount          = 2
        enableCustomResources = false

        ingressClass = {
          name                = "nginx"
          create              = true
          setAsDefaultIngress = false
        }

        service = {
          create                = true
          type                  = "LoadBalancer"
          loadBalancerClass     = "service.k8s.aws/nlb"
          externalTrafficPolicy = "Cluster"

          annotations = {
            "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"

            "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"

            "service.beta.kubernetes.io/aws-load-balancer-subnets" = join(",", [
              aws_subnet.public["a"].id,
              aws_subnet.public["b"].id
            ])
          }
        }
      }
    })
  ]

  depends_on = [
    helm_release.alb_controller
  ]
}
