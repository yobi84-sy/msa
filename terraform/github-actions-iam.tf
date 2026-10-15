
# =========================================================
# GitHub Actions IAM Role
# yobi84-sy/msa - yobi-v1 브랜치 전용
# GitHub 기본 OIDC sub와 사용자 지정 ID 포함 sub를 모두 허용.
# 다른 저장소/브랜치에는 권한을 부여하지 않음.
# =========================================================

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type = "Federated"

      identifiers = [
        aws_iam_openid_connect_provider.github.arn
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"

      values = [
        "sts.amazonaws.com"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"

      values = [
        "repo:yobi84-sy@306224385/msa@1406608901:ref:refs/heads/yobi-v1",
        "repo:yobi84-sy/msa:ref:refs/heads/yobi-v1"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name = "sales-mall-dev-github-actions-role"

  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json

  tags = {
    Name    = "sales-mall-dev-github-actions-role"
    Project = "sales-mall"
  }
}
