# =========================================================
# Local Values
# 프로젝트 공통 이름 및 태그 정의
# =========================================================

locals {

  # AWS 리소스 이름에 사용할 공통 접두어
  # 예: sales-mall-dev-vpc
  name_prefix = "${var.project_name}-${var.environment}"
  # 모든 AWS 리소스에 적용할 공통 태그
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}