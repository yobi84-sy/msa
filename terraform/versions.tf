# =========================================================
# Terraform Version & Provider Requirements
# Terraform 실행 버전 및 AWS Provider 버전 지정
# =========================================================

terraform {
  # Terraform 최소 실행 버전
  required_version = ">= 1.6.0"

  # AWS Provider 버전 범위 지정
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}