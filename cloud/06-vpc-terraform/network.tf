locals {
  subnets = {
    public-a  = { cidr = "10.0.1.0/24", az = "us-east-1a", public = true }
    public-b  = { cidr = "10.0.2.0/24", az = "us-east-1b", public = true }
    private-a = { cidr = "10.0.11.0/24", az = "us-east-1a", public = false }
    private-b = { cidr = "10.0.12.0/24", az = "us-east-1b", public = false }
  }
}

resource "aws_vpc" "main" {
  #checkov:skip=CKV2_AWS_11:The network only lives a few hours, flow logs come in the monitoring lab
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "lab06-vpc"
  }
}

resource "aws_subnet" "this" {
  #checkov:skip=CKV_AWS_130:The public subnets hand out public IPs on purpose
  for_each = local.subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = each.value.public

  tags = {
    Name = "lab06-${each.key}"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "lab06-igw"
  }
}

resource "aws_eip" "nat" {
  count  = var.enable_nat ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "lab06-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  count = var.enable_nat ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.this["public-a"].id

  tags = {
    Name = "lab06-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "lab06-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "lab06-private-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route" "private_nat" {
  count = var.enable_nat ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

resource "aws_route_table_association" "this" {
  for_each = aws_subnet.this

  subnet_id      = each.value.id
  route_table_id = local.subnets[each.key].public ? aws_route_table.public.id : aws_route_table.private.id
}

resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [for k, s in aws_subnet.this : s.id if local.subnets[k].public]

  tags = {
    Name = "lab06-public-nacl"
  }
}

resource "aws_network_acl_rule" "allow_all" {
  #checkov:skip=CKV_AWS_352:Allow all like the default NACL, the security groups do the filtering
  #checkov:skip=CKV_AWS_229:Same, port 21 is closed by the security groups
  #checkov:skip=CKV_AWS_230:Same, port 20 is closed by the security groups
  #checkov:skip=CKV_AWS_231:Same, port 3389 is closed by the security groups
  #checkov:skip=CKV_AWS_232:Same, port 22 is closed by the security groups
  for_each = { in = false, out = true }

  network_acl_id = aws_network_acl.public.id
  rule_number    = 100
  egress         = each.value
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

resource "aws_network_acl_rule" "block_my_ip" {
  count = var.block_my_ip ? 1 : 0

  network_acl_id = aws_network_acl.public.id
  rule_number    = 90
  egress         = false
  protocol       = "tcp"
  rule_action    = "deny"
  cidr_block     = "${var.my_ip}/32"
  from_port      = 80
  to_port        = 80
}
