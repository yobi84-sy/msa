
# =========================================================
# S3 Product Images - CloudFront OAC
# 비공개 S3에 CloudFront만 읽기 접근 허용
# =========================================================

resource "aws_cloudfront_origin_access_control" "product_images" {
  name                              = "${local.name_prefix}-product-images-oac"
  description                       = "OAC for product images"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# =========================================================
# CloudFront Distribution
# =========================================================

resource "aws_cloudfront_distribution" "product_images" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Sales Mall Product Images"
  price_class         = "PriceClass_200"
  wait_for_deployment = true

  origin {
    domain_name              = aws_s3_bucket.product_images.bucket_regional_domain_name
    origin_id                = "product-images-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.product_images.id
  }

  default_cache_behavior {
    target_origin_id       = "product-images-s3"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# =========================================================
# S3 Bucket Policy
# CloudFront 배포에만 products/* 읽기 허용
# =========================================================

data "aws_iam_policy_document" "product_images_cloudfront" {
  statement {
    sid     = "AllowCloudFrontReadProductImages"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    resources = [
      "${aws_s3_bucket.product_images.arn}/products/*"
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.product_images.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "product_images_cloudfront" {
  bucket = aws_s3_bucket.product_images.id
  policy = data.aws_iam_policy_document.product_images_cloudfront.json
}

# =========================================================
# CloudFront URL Output
# =========================================================

output "product_images_cloudfront_domain" {
  description = "CloudFront domain for product images"
  value       = aws_cloudfront_distribution.product_images.domain_name
}
