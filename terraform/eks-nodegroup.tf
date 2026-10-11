# =========================================================
# EKS Managed Node Group
# MSA 애플리케이션을 실행할 EC2 Worker Node
# =========================================================

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name_prefix}-nodegroup"
  node_role_arn   = aws_iam_role.eks_node.arn

  # Private Subnet A/B에 Node 배치
  subnet_ids = [
  for subnet in aws_subnet.private : subnet.id]

  # EC2 인스턴스 설정
  instance_types = ["t3.medium"]
  capacity_type  = "ON_DEMAND"
  ami_type       = "AL2023_x86_64_STANDARD"
  disk_size      = 30

  # Node Group 크기
  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 5
  }

  # Node 업데이트 설정
  update_config {
    max_unavailable = 1
  }

  #kubernetes Node Labels
  labels = {
    environment = var.environment
    project     = var.project_name
  }

  # IAM 정책 연결 후 Node Group 생성
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker,
    aws_iam_role_policy_attachment.eks_ecr,
    aws_iam_role_policy_attachment.eks_cni
  ]


  tags = {
    Name = "${local.name_prefix}-nodegroup"
  }
}