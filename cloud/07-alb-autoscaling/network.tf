locals {
  subnets = {
    public-a  = { cidr = "10.0.1.0/24", az = "us-east-1a", public = true }
    public-b  = { cidr = "10.0.2.0/24", az = "us-east-1b", public = true }
    private-a = { cidr = "10.0.11.0/24", az = "us-east-1a", public = false }
    private-b = { cidr = "10.0.12.0/24", az = "us-east-1b", public = false }
  }

  public_subnet_ids  = [for k, s in aws_subnet.this : s.id if local.subnets[k].public]
  private_subnet_ids = [for k, s in aws_subnet.this : s.id if !local.subnets[k].public]
}

resource "aws_vpc" "main" {
  #checkov:skip=CKV2_AWS_11:The network only lives a few hours, flow logs come in the monitoring lab
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "lab07-vpc"
  }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = {
    Name = "lab07-${each.key}"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "lab07-igw"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "lab07-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.this["public-a"].id

  tags = {
    Name = "lab07-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "lab07-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "lab07-private-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "this" {
  for_each = aws_subnet.this

  subnet_id      = each.value.id
  route_table_id = local.subnets[each.key].public ? aws_route_table.public.id : aws_route_table.private.id
}
