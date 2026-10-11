
# =========================================================
# GitHub Actions OIDC Provider
# GitHub → AWS STS 임시 인증
# =========================================================

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  tags = {
    Name    = "sales-mall-dev-github-oidc"
    Project = "sales-mall"
  }
}
