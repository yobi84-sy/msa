# =========================================================
# RDS DB Subnet Group
# Private Subnet A/B 사용
# =========================================================

resource "aws_db_subnet_group" "main" {
  name = "${local.name_prefix}-db-subnet-group"

  subnet_ids = [
    for subnet in aws_subnet.private : subnet.id
  ]

  tags = {
    Name = "${local.name_prefix}-db-subnet-group"
  }
}

# =========================================================
# RDS MySQL
# =========================================================

resource "aws_db_instance" "main" {
  identifier = "${local.name_prefix}-mysql"

  # Datebase Engine
  engine                     = "mysql"
  engine_version             = "8.4"
  instance_class             = "db.t4g.micro"
  auto_minor_version_upgrade = true

  # Storage
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  # Datebase
  db_name  = "ordermsa"
  username = "admin"

  # AWS Secrets Manager에서 마스터 비밀번호 관리
  manage_master_user_password = true

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Availability
  multi_az = false

  # Backup
  backup_retention_period = 1

  # Development Environment
  deletion_protection = false
  skip_final_snapshot = true

  tags = {
    Name = "${local.name_prefix}-mysql"
  }
}