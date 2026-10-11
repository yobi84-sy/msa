# =========================================================
# Amazon EKS Cluster
# Sales Mall MSA Kubernetes 클러스터
# =========================================================

resource "aws_eks_cluster" "main" {
  name     = "${local.name_prefix}-eks"
  role_arn = aws_iam_role.eks_cluster.arn

  # Kubernetes 클러스터 네트워크
  vpc_config {
    subnet_ids = [
      for subnet in aws_subnet.private : subnet.id
    ]

    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # Kubernetes API 인증 방식
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }
  # 개발 환경에서는 삭제 보호 비활성화
  deletion_protection = false

  # IAM 정책 연결 후 클러스터 생성
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster
  ]
  tags = {
    Name = "${local.name_prefix}-eks"
  }
}