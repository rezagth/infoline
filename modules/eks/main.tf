# ==============================================================
# MODULE EKS — Cluster Kubernetes managé pour InfoLine API
# ==============================================================

locals {
  name = "${var.project}-${var.environment}-eks"
}

# ---------------------------------------------------------------
# IAM Role pour le Control Plane EKS
# ---------------------------------------------------------------
resource "aws_iam_role" "eks_cluster" {
  name = "${local.name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# ---------------------------------------------------------------
# IAM Role pour les Worker Nodes
# ---------------------------------------------------------------
resource "aws_iam_role" "eks_nodes" {
  name = "${local.name}-nodes-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}

# Politique CloudWatch pour la supervision depuis les nodes
resource "aws_iam_role_policy_attachment" "eks_cloudwatch" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.eks_nodes.name
}

# ---------------------------------------------------------------
# Cluster EKS
# ---------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = local.name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [var.eks_nodes_sg_id]
    endpoint_private_access = true   # API server accessible depuis le VPC
    endpoint_public_access  = true   # Accès public pour kubectl (restreint par CIDR en prod)
    public_access_cidrs     = var.environment == "prod" ? var.admin_cidrs : ["0.0.0.0/0"]
  }

  # Journaux du control plane envoyés à CloudWatch
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]

  tags = { Name = local.name }
}

# ---------------------------------------------------------------
# Node Group — workers autoscalables
# ---------------------------------------------------------------
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name}-ng"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = [var.node_instance_type]
  ami_type       = "AL2_x86_64" # Amazon Linux 2 optimisé EKS

  scaling_config {
    desired_size = var.node_desired
    min_size     = var.node_min
    max_size     = var.node_max
  }

  # Mise à jour progressive : max 1 node indisponible à la fois
  update_config {
    max_unavailable = 1
  }

  # Disque root EBS
  disk_size = 50

  labels = {
    role        = "worker"
    environment = var.environment
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]

  tags = { Name = "${local.name}-ng" }

  # Ignore les changements de desired_size pour laisser l'autoscaler gérer
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# ---------------------------------------------------------------
# Cluster Autoscaler — ajuste automatiquement le nombre de nodes
# ---------------------------------------------------------------
resource "aws_iam_role" "cluster_autoscaler" {
  name = "${local.name}-autoscaler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "${local.name}-autoscaler-policy"
  role = aws_iam_role.cluster_autoscaler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeTags",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "ec2:DescribeLaunchTemplateVersions"
        ]
        Resource = "*"
      }
    ]
  })
}

# OIDC Provider pour l'authentification des ServiceAccounts Kubernetes vers AWS IAM
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# ---------------------------------------------------------------
# ECR — Registry Docker privé pour les images InfoLine
# ---------------------------------------------------------------
resource "aws_ecr_repository" "api" {
  name                 = "${var.project}/api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true # Scan automatique des vulnérabilités
  }

  tags = { Name = "${var.project}-api-ecr" }
}

resource "aws_ecr_repository" "frontend_main" {
  name                 = "${var.project}/frontend-main"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  tags = { Name = "${var.project}-frontend-main-ecr" }
}

resource "aws_ecr_repository" "frontend_backoffice" {
  name                 = "${var.project}/frontend-backoffice"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  tags = { Name = "${var.project}-frontend-backoffice-ecr" }
}

# Politique de rétention des images (max 10 images par repo)
resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------
output "cluster_name"       { value = aws_eks_cluster.main.name }
output "cluster_endpoint"   { value = aws_eks_cluster.main.endpoint }
output "cluster_ca_certificate" {
  value = aws_eks_cluster.main.certificate_authority[0].data
}
output "cluster_token" {
  value     = data.aws_eks_cluster_auth.main.token
  sensitive = true
}
output "ecr_api_url"               { value = aws_ecr_repository.api.repository_url }
output "ecr_frontend_main_url"     { value = aws_ecr_repository.frontend_main.repository_url }
output "ecr_frontend_backoffice_url" { value = aws_ecr_repository.frontend_backoffice.repository_url }
output "oidc_provider_arn"         { value = aws_iam_openid_connect_provider.eks.arn }
output "autoscaler_role_arn"       { value = aws_iam_role.cluster_autoscaler.arn }

data "aws_eks_cluster_auth" "main" {
  name = aws_eks_cluster.main.name
}
