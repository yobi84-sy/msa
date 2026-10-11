# Terraform으로 생성한 주요 AWS 리소스 정보를 출력합니다.

# =========================================================
# VPC Output
# 생성된 VPC의 ID 출력
# =========================================================

output "vpc_id" {
  description = "Sales Mall VPC ID"
  value       = aws_vpc.main.id
}


# =========================================================
# EKS Cluster Output
# 생성된 Kubernetes 클러스터 이름 출력
# =========================================================

output "eks_cluster_name" {
  description = "EKS Cluster Name"
  value       = aws_eks_cluster.main.name
}


# =========================================================
# RDS MySQL Output
# 생성된 RDS 데이터베이스 접속 주소 출력
# =========================================================

output "rds_endpoint" {
  description = "RDS MySQL Endpoint"
  value       = aws_db_instance.main.address
}