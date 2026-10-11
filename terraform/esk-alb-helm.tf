# =========================================================
# Helm Provider - EKS 연결
# =========================================================

provider "helm" {
  kubernetes = {
    host = aws_eks_cluster.main.endpoint

    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name, "--region", var.aws_region, "--profile", var.aws_profile]

    }
  }
}

# =========================================================
# AWS Load Balancer Controller
# =========================================================

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.14.0"

  namespace = "kube-system"

  values = [
    yamlencode({
      clusterName = aws_eks_cluster.main.name
      region      = var.aws_region
      vpcId       = aws_vpc.main.id

      replicaCount = 2

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"

        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
        }
      }
    })
  ]

  wait    = true
  timeout = 600

  depends_on = [
    aws_iam_role_policy_attachment.alb_controller,
    aws_eks_node_group.main
  ]
}