# ==============================================================
# MODULE VPC — Réseau isolé pour InfoLine
# ==============================================================

locals {
  name   = "${var.project}-${var.environment}"
  azs    = slice(data.aws_availability_zones.available.names, 0, 3)
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------
# VPC principal
# ---------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name}-vpc"
    # Tag requis par EKS pour la découverte automatique des sous-réseaux
    "kubernetes.io/cluster/${local.name}-eks" = "shared"
  }
}

# ---------------------------------------------------------------
# Subnets publics (Load Balancers, NAT Gateways)
# ---------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                              = "${local.name}-public-${local.azs[count.index]}"
    "kubernetes.io/cluster/${local.name}-eks"         = "shared"
    "kubernetes.io/role/elb"                          = "1"
  }
}

# ---------------------------------------------------------------
# Subnets privés (Nodes EKS, RDS, Lambda dans VPC)
# ---------------------------------------------------------------
resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = {
    Name                                              = "${local.name}-private-${local.azs[count.index]}"
    "kubernetes.io/cluster/${local.name}-eks"         = "shared"
    "kubernetes.io/role/internal-elb"                 = "1"
  }
}

# ---------------------------------------------------------------
# Internet Gateway (accès public entrant/sortant)
# ---------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

# ---------------------------------------------------------------
# NAT Gateway (permet aux subnets privés d'accéder à internet)
# Elastic IP pour le NAT
# ---------------------------------------------------------------
resource "aws_eip" "nat" {
  count  = length(local.azs)
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip-${count.index}" }
}

resource "aws_nat_gateway" "main" {
  count         = length(local.azs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${local.name}-nat-${count.index}" }
  depends_on    = [aws_internet_gateway.main]
}

# ---------------------------------------------------------------
# Route Tables
# ---------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = length(local.azs)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = { Name = "${local.name}-private-rt-${count.index}" }
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------

# SG pour les Load Balancers (trafic HTTP/HTTPS entrant)
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Allow HTTP/HTTPS from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-alb-sg" }
}

# SG pour les nodes EKS (communication intra-cluster + ALB)
resource "aws_security_group" "eks_nodes" {
  name        = "${local.name}-eks-nodes-sg"
  description = "EKS worker nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow all from within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-eks-nodes-sg" }
}

# SG pour RDS PostgreSQL (accès limité au VPC)
resource "aws_security_group" "rds" {
  name        = "${local.name}-rds-sg"
  description = "PostgreSQL access from VPC only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-rds-sg" }
}

# ---------------------------------------------------------------
# Outputs exportés vers les autres modules
# ---------------------------------------------------------------
output "vpc_id"              { value = aws_vpc.main.id }
output "public_subnet_ids"  { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "alb_sg_id"          { value = aws_security_group.alb.id }
output "eks_nodes_sg_id"    { value = aws_security_group.eks_nodes.id }
output "rds_sg_id"          { value = aws_security_group.rds.id }
