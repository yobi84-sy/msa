# =========================================================
# Amazon VPC CNI Add-on
# Kubernetes Pod의 VPC 네트워크 및 IP 주소 관리
# =========================================================

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# =========================================================
# CoreDNS Add-on
# Kubernetes 내부 서비스 DNS 이름 해석
# =========================================================

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# =========================================================
# kube-proxy Add-on
# Kubernetes Service 네트워크 트래픽 관리
# =========================================================

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}