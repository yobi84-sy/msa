# =========================================================
# Product Service - IRSA IAM Role
# =========================================================

data "aws_iam_policy_document" "product_irsa_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:soldesk:product-sa"]
    }
  }
}

# =========================================================
# Product IAM Role
# =========================================================

resource "aws_iam_role" "product_s3" {
  name               = "${local.name_prefix}-product-s3-role"
  assume_role_policy = data.aws_iam_policy_document.product_irsa_assume.json

  tags = {
    Name = "${local.name_prefix}-product-s3-role"
  }
}

# =========================================================
# Product S3 IAM Policy
# 실제 Terraform S3 Bucket만 접근 허용
# =========================================================

resource "aws_iam_policy" "product_s3" {
  name = "${local.name_prefix}-product-s3-policy"

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ]
        Resource = [
          "${aws_s3_bucket.product_images.arn}/*"
        ]
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-product-s3-policy"
  }
}

# =========================================================
# IAM Role + Policy 연결
# =========================================================

resource "aws_iam_role_policy_attachment" "product_s3" {
  role       = aws_iam_role.product_s3.name
  policy_arn = aws_iam_policy.product_s3.arn
}