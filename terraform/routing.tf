# =========================================================
# Internet Gateway
# =========================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# =========================================================
# Public Route Table
# =========================================================

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

# Public Subnet -> Internet Gateway

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Public Subnet A/B 라우팅 연결

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# =========================================================
# Private Route Tables
# =========================================================

resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-private-rt-${each.key}"
  }
}

# Private Subnet A/B 라우팅 연결

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}