# =========================================================
# RDS MySQL Security Group
# =========================================================

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Security group for RDS MySQL"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-rds-sg"
  }
}

# =========================================================
# Allow MySQL from Private Subnets
# =========================================================

resource "aws_vpc_security_group_ingress_rule" "rds_mysql" {
  for_each = aws_subnet.private

  security_group_id = aws_security_group.rds.id

  description = "Allow MySQL access from private subnet ${each.key}"

  cidr_ipv4   = each.value.cidr_block
  from_port   = 3306
  to_port     = 3306
  ip_protocol = "tcp"
}
