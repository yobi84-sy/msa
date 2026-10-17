# =========================================================
# cert-manager - Route 53 DNS-01 IAM / IRSA
# 기존 EKS OIDC Provider 재사용
# =========================================================

data "aws_iam_policy_document" "cert_manager_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"
      identifiers = [
        aws_iam_openid_connect_provider.eks.arn
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:cert-manager:cert-manager"]
    }
  }
}

# cert-manager 전용 IAM Role
resource "aws_iam_role" "cert_manager" {
  name               = "${local.name_prefix}-cert-manager-role"
  assume_role_policy = data.aws_iam_policy_document.cert_manager_assume.json
}

# Route 53 DNS-01 전용 IAM 권한
data "aws_iam_policy_document" "cert_manager" {
  statement {
    sid       = "ReadDnsChanges"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    sid    = "ChangeDns01TxtRecords"
    effect = "Allow"

    actions = [
      "route53:ChangeResourceRecordSets"
    ]

    resources = [
      "arn:aws:route53:::hostedzone/${data.aws_route53_zone.sy84.zone_id}"
    ]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }
  }

  statement {
    sid    = "ReadDnsRecords"
    effect = "Allow"

    actions = [
      "route53:ListResourceRecordSets"
    ]

    resources = [
      "arn:aws:route53:::hostedzone/${data.aws_route53_zone.sy84.zone_id}"
    ]
  }
}

resource "aws_iam_policy" "cert_manager" {
  name   = "${local.name_prefix}-cert-manager-policy"
  policy = data.aws_iam_policy_document.cert_manager.json
}

resource "aws_iam_role_policy_attachment" "cert_manager" {
  role       = aws_iam_role.cert_manager.name
  policy_arn = aws_iam_policy.cert_manager.arn
}