
# EKS Metrics Server - HPA CPU 사용량 수집
resource "aws_eks_addon" "metrics_server" {
  cluster_name  = aws_eks_cluster.main.name
  addon_version = "v0.9.0-eksbuild.11"
  addon_name    = "metrics-server"

  depends_on = [
    aws_eks_node_group.main
  ]
}
