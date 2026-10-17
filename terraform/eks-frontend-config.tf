# =========================================================
# Yobi V1 - Frontend CloudFront Runtime Config
# Terraform -> Kubernetes ConfigMap -> Frontend
# =========================================================

resource "kubernetes_config_map_v1" "frontend_config" {
  metadata {
    name      = "frontend-runtime-config"
    namespace = kubernetes_namespace_v1.soldesk.metadata[0].name
  }

  data = {
    "config.js" = "window.YOBI_CONFIG = { cloudfrontDomain: ${jsonencode(aws_cloudfront_distribution.product_images.domain_name)} };\n"
  }
}
