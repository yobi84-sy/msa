# =========================================================
# AWS Provider Configuration
# AWS 리전, 인증 프로필 및 공통 태그 설정
# =========================================================

provider "aws" {
  # AWS 리전 및 인증 프로필
  region  = var.aws_region
  profile = var.aws_profile

  # Terraform으로 생성하는 AWS 리소스에 공통 태그 적용

  default_tags {
    tags = local.common_tags
  }
}