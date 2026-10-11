# =========================================================
# VPC
# Sales Mall 전체 AWS 인프라의 기본 네트워크
# =========================================================

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# Public Subnets
resource "aws_subnet" "public" {
  for_each = {
    a = "10.0.1.0/24"
    b = "10.0.2.0/24"
  }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = var.availability_zones[each.key == "a" ? 0 : 1]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${local.name_prefix}-public-subnet-${each.key}"
    "kubernetes.io/role/elb" = "1"
  }
}

# Private Subnets
resource "aws_subnet" "private" {
  for_each = {
    a = "10.0.11.0/24"
    b = "10.0.12.0/24"
  }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = var.availability_zones[each.key == "a" ? 0 : 1]

  tags = {
    Name                              = "${local.name_prefix}-private-subnet-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}