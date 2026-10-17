# [Yobi V1 Monitoring DNS] 기존 NLB/Route53 구성에 모니터링 호스트 등록
# sy84.store의 기존 HTTPS/DNS와 충돌하지 않는지 Terraform plan에서 점검
# =========================================================
# Yobi V1 - Route 53 Single Domain
# server.sy84.store -> NGINX NLB
# 기존 Hosted Zone 유지
# =========================================================

locals {
  msa_dns_names = toset([
    "server",
    # Grafana와 Prometheus도 기존 NGINX NLB를 사용해 별도 LoadBalancer 비용을 만들지 않음.
    # 기존 server.sy84.store 레코드는 그대로 유지.
    "grafana",
    "prometheus"
  ])
}

# AWS Load Balancer Controller가 생성한 NLB 조회
data "aws_lb" "nginx_nlb" {
  count = var.enable_nlb_dns ? 1 : 0

  tags = {
    "service.k8s.aws/stack"    = "nginx-ingress/nginx-ingress-controller"
    "service.k8s.aws/resource" = "LoadBalancer"
    "elbv2.k8s.aws/cluster"    = aws_eks_cluster.main.name
  }

  depends_on = [
    helm_release.nginx_ingress,
    kubernetes_ingress_v1.msa
  ]
}

# 단일 A Alias 레코드 생성
resource "aws_route53_record" "msa" {
  for_each = var.enable_nlb_dns ? local.msa_dns_names : toset([])

  zone_id = data.aws_route53_zone.sy84.zone_id
  name    = "${each.key}.sy84.store"
  type    = "A"

  alias {
    name                   = data.aws_lb.nginx_nlb[0].dns_name
    zone_id                = data.aws_lb.nginx_nlb[0].zone_id
    evaluate_target_health = true
  }
}