# =========================================================
# Amazon ECR
# MSA 서비스별 Docker 이미지 저장소
# =========================================================

resource "aws_ecr_repository" "services" {
  for_each = toset([
    "frontend",
    "apigateway",
    "member",
    "product",
    "ordering"
  ])

  name                 = "${local.name_prefix}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  # 이미지 업로드 시 취약점 검사
  image_scanning_configuration {
    scan_on_push = true
  }

  # 저장 이미지 암호화
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name    = "${local.name_prefix}-${each.key}"
    Service = each.key
  }
}