
# =========================================================
# Cluster Autoscaler - Helm 자동 설치
# EKS Kubernetes 1.36 호환
# =========================================================

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.55.0"

  namespace = "kube-system"

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      cloudProvider = "aws"
      awsRegion     = var.aws_region

      autoDiscovery = {
        clusterName = aws_eks_cluster.main.name
      }

      image = {
        repository = "registry.k8s.io/autoscaling/cluster-autoscaler"
        tag        = "v1.36.1"
      }

      rbac = {
        serviceAccount = {
          create = true
          name   = "cluster-autoscaler"

          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.cluster_autoscaler.arn
          }
        }
      }

      extraArgs = {
        expander                      = "least-waste"
        skip-nodes-with-local-storage = "false"
      }

      resources = {
        requests = {
          cpu    = "50m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "200m"
          memory = "512Mi"
        }
      }
    })
  ]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_autoscaler,
    aws_autoscaling_group_tag.cluster_autoscaler_enabled,
    aws_autoscaling_group_tag.cluster_autoscaler_cluster,
    aws_eks_node_group.main
  ]
}
