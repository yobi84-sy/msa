# =========================================================
# EKS Cluster IAM Role
# Amazon EKS Control Plane에서 사용할 IAM 역할
# =========================================================

resource "aws_iam_role" "eks_cluster" {
  name = "${local.name_prefix}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"

      Principal = {
        Service = "eks.amazonaws.com"
      }

      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-eks-cluster-role"
  }
}

# =========================================================
# EKS Cluster IAM Policy
# EKS 클러스터 운영에 필요한 AWS 관리형 정책
# =========================================================

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# =========================================================
# EKS Worker Node IAM Role
# EC2 워커 노드가 사용할 IAM 역할
# =========================================================

resource "aws_iam_role" "eks_node" {
  name = "${local.name_prefix}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"

      Principal = {
        Service = "ec2.amazonaws.com"
      }

      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-eks-node-role"
  }
}

# =========================================================
# EKS Worker Node Policy
# EC2 워커 노드의 EKS 클러스터 참여 권한
# =========================================================

resource "aws_iam_role_policy_attachment" "eks_worker" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# =========================================================
# Amazon ECR Pull Policy
# ECR에서 컨테이너 이미지를 다운로드하는 권한
# =========================================================

resource "aws_iam_role_policy_attachment" "eks_ecr" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

# =========================================================
# Amazon VPC CNI Policy
# Kubernetes Pod 네트워크 관리 권한
# =========================================================

resource "aws_iam_role_policy_attachment" "eks_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}