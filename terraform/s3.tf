# =========================================================
# AWS Account Information
# S3 Bucket 이름의 중복 방지를 위한 계정 정보 조회
# =========================================================

data "aws_caller_identity" "current" {}

# =========================================================
# S3 Product Images Bucket
# Product 서비스의 상품 이미지 저장소
# =========================================================

resource "aws_s3_bucket" "product_images" {
  bucket        = "${local.name_prefix}-product-images-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = true

  tags = {
    Name    = "${local.name_prefix}-product-images"
    Service = "Product"
  }
}

# =========================================================
# S3 Public Access Block
# 외부 공개 접근 차단
# =========================================================

resource "aws_s3_bucket_public_access_block" "product_images" {
  bucket = aws_s3_bucket.product_images.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =========================================================
# S3 Server Side Encryption
# S3 저장 데이터 암호화 (SSE-S3)
# =========================================================

resource "aws_s3_bucket_server_side_encryption_configuration" "product_images" {
  bucket = aws_s3_bucket.product_images.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}