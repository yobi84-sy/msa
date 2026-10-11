
# =========================================================
# GitHub Actions - EKS Access
# sales-mall-dev-eks / soldesk namespace
# =========================================================

# 1. GitHub Actions Role의 EKS 인증 등록
resource "aws_eks_access_entry" "github_actions" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.github_actions.arn
  type          = "STANDARD"
}

# 2. soldesk 네임스페이스 편집 권한
resource "aws_eks_access_policy_association" "github_actions_soldesk" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.github_actions.principal_arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["soldesk"]
  }
}

# 3. GitHub Actions에서 kubeconfig 생성 시 필요한 IAM 권한
data "aws_iam_policy_document" "github_actions_eks_describe" {
  statement {
    effect = "Allow"

    actions = [
      "eks:DescribeCluster"
    ]

    resources = [
      aws_eks_cluster.main.arn
    ]
  }
}

resource "aws_iam_role_policy" "github_actions_eks_describe" {
  name   = "sales-mall-dev-github-eks-describe"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_eks_describe.json
}
