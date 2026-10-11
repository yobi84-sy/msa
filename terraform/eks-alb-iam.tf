# =========================================================
# AWS Load Balancer Controller IAM Policy
# ALB 생성 및 관리에 필요한 AWS API 권한
# =========================================================

resource "aws_iam_policy" "alb_controller" {
  name        = "${local.name_prefix}-alb-controller-policy"
  description = "Policy for AWS Load Balancer Controller"
  policy      = file("${path.module}/iam_policy.json")

  tags = {
    Name = "${local.name_prefix}-alb-controller-policy"
  }
}

# =========================================================
# AWS Load Balancer Controller IAM Role (IRSA)
# kube-system의 Controller ServiceAccount만 사용 허용
# =========================================================

data "aws_iam_policy_document" "alb_controller_assume" {
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
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${local.name_prefix}-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume.json

  tags = {
    Name = "${local.name_prefix}-alb-controller-role"
  }
}

# =========================================================
# IAM Role + Policy 연결
# =========================================================

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}
