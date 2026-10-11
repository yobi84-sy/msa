# =========================================================
# AWS Region
# AWS 리소스를 생성할 기본 리전
# =========================================================

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "ap-northeast-2"
}

# =========================================================
# AWS CLI Profile
# Terraform에서 사용할 AWS 인증 프로필
# =========================================================

variable "aws_profile" {
  description = "AWS CLI profile name"
  type        = string
  default     = "default"
}

# =========================================================
# Project Name
# AWS 리소스 이름 및 공통 태그에 사용할 프로젝트 이름
# =========================================================

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "sales-mall"
}

# =========================================================
# Environment
# 개발 및 운영 환경을 구분하는 변수
# =========================================================

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

# =========================================================
# Availability Zones
# Public / Private Subnet을 배치할 AZ 설정
# =========================================================

variable "availability_zones" {
  description = "Availability Zones for VPCsubnets"
  type        = list(string)

  validation {
    condition = (
      length(var.availability_zones) == 2 &&
      length(distinct(var.availability_zones)) == 2
    )

    error_message = "서로 다른 AZ를 2개 선택해야 합니다. 예: [\"ap-northeast-2a\", \"ap-northeast-2c\"]"
  }
}