# -----------------------------------------------------------------------------
# cw-vpc: Reusable VPC for AWS CloudWatch labs
# Public-subnet VPC with optional second AZ (for ASG labs).
# No NAT/private subnet — CW Agent uses HTTPS to public endpoints.
# -----------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

# --- VPC ---

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}

# --- Internet Gateway ---

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-igw"
  })
}

# --- Public Subnet (AZ 1) ---

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-public-1"
  })
}

# --- Public Subnet (AZ 2 — conditional, for ASG multi-AZ) ---

resource "aws_subnet" "public_2" {
  count = var.enable_second_public_subnet ? 1 : 0

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr_2
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-public-2"
  })
}

# --- Route Table ---

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  count = var.enable_second_public_subnet ? 1 : 0

  subnet_id      = aws_subnet.public_2[0].id
  route_table_id = aws_route_table.public.id
}

# --- Instance Security Group ---

resource "aws_security_group" "instance" {
  name        = "${var.project_name}-instance-sg"
  description = "Security group for CloudWatch-monitored instances"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-instance-sg"
  })
}
