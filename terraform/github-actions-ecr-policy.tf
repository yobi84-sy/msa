
# =========================================================
# GitHub Actions - ECR Push IAM Policy
# 대상: Terraform으로 생성한 MSA ECR 저장소 5개
# =========================================================

data "aws_iam_policy_document" "github_actions_ecr" {

  # ECR 로그인 토큰 발급
  statement {
    sid    = "ECRAuthentication"
    effect = "Allow"

    actions = [
      "ecr:GetAuthorizationToken"
    ]

    resources = ["*"]
  }

  # MSA ECR 저장소 5개에 이미지 Push
  statement {
    sid    = "ECRPushImages"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage"
    ]

    resources = [
      for repo in values(aws_ecr_repository.services) :
      repo.arn
    ]
  }
}

# 기존 GitHub Actions Role에 권한 연결
resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "sales-mall-dev-github-ecr-push"

  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_ecr.json
}
