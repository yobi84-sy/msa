# =========================================================
# Yobi V1 - MSA Ingress
# Single Domain / HTTPS / Path-Based Routing
#
# server.sy84.store/
#   /                -> Frontend
#   /member-service  -> API Gateway
#   /product-service -> API Gateway
#   /ordering-service -> API Gateway
# =========================================================

locals {
  msa_ingress_routes = [
    {
      path    = "/member-service"
      service = "apigateway-service"
    },
    {
      path    = "/product-service"
      service = "apigateway-service"
    },
    {
      path    = "/ordering-service"
      service = "apigateway-service"
    },
    {
      path    = "/"
      service = "frontend-service"
    }
  ]
}

resource "kubernetes_ingress_v1" "msa" {
  metadata {
    name      = "order-backend-ingress"
    namespace = "soldesk"

    annotations = {
      "nginx.org/client-max-body-size" = "20m"
      "nginx.org/http-redirect-code"   = "308"
    }
  }

  spec {
    ingress_class_name = "nginx"

    # 기존 cert-manager TLS Secret 사용
    tls {
      hosts = [
        "server.sy84.store"
      ]

      secret_name = "server-sy84-store-tls"
    }

    # 단일 도메인 - URL 경로 기반 서비스 연결
    rule {
      host = "server.sy84.store"

      http {
        dynamic "path" {
          for_each = local.msa_ingress_routes

          content {
            path      = path.value.path
            path_type = "Prefix"

            backend {
              service {
                name = path.value.service

                port {
                  number = 80
                }
              }
            }
          }
        }
      }
    }
  }

  # NLB 주소 할당 대기
  wait_for_load_balancer = true

  depends_on = [
    helm_release.nginx_ingress,
    kubernetes_namespace_v1.soldesk,
    helm_release.msa_tls
  ]
}