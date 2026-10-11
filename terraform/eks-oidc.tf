# =========================================================
# EKS OIDC Provider
# Kubernetes ServiceAccount와 AWS IAM 연동 (IRSA)
# =========================================================

resource "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer

  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name = "${local.name_prefix}-oidc"
  }
}