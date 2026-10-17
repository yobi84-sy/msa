# =========================================================
# Elastic IP
# NAT Gateway에서 사용할 고정 공인 IP
# =========================================================

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

# =========================================================
# NAT Gateway
# Public Subnet A에 생성
# =========================================================

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["a"].id

  depends_on = [
    aws_internet_gateway.main,
    aws_route.public_internet,
    aws_route_table_association.public
  ]

  tags = {
    Name = "${local.name_prefix}-nat"
  }
}

# =========================================================
# Private Route
# Private A/B -> NAT Gateway
# =========================================================

resource "aws_route" "private_nat" {
  for_each = aws_route_table.private

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}