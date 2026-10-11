
# =========================================================
# Route 53 - NGINX NLB DNS 자동 연결
# =========================================================

# 1. 기존 Route 53 Public Hosted Zone 조회
data "aws_route53_zone" "nginx_public" {
  name         = "sy84.store."
  private_zone = false
}

# 2. Kubernetes가 생성한 NLB를 태그로 자동 조회
data "aws_lb" "nginx_nlb" {
  tags = {
    "service.k8s.aws/stack"    = "nginx-ingress/nginx-ingress-controller"
    "service.k8s.aws/resource" = "LoadBalancer"
    "elbv2.k8s.aws/cluster"    = aws_eks_cluster.main.name
  }

  depends_on = [
    helm_release.nginx_ingress
  ]
}

# 3. server.sy84.store → AWS NLB A Alias
resource "aws_route53_record" "server" {
  zone_id = data.aws_route53_zone.nginx_public.zone_id
  name    = "server.sy84.store"
  type    = "A"

  alias {
    name                   = data.aws_lb.nginx_nlb.dns_name
    zone_id                = data.aws_lb.nginx_nlb.zone_id
    evaluate_target_health = true
  }
}
