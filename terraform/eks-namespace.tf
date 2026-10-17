# =========================================================
# EKS - MSA Namespace
# soldesk 네임스페이스 자동 생성 및 삭제
# =========================================================

resource "kubernetes_namespace_v1" "soldesk" {
  metadata {
    name = "soldesk"

    labels = {
      project = var.project_name
    }
  }

  depends_on = [
    aws_eks_node_group.main
  ]
}
