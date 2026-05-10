# ==============================================================
# InfoLine — Infrastructure as Code (Terraform)
# Fournisseur : AWS / Région : eu-west-3 (Paris)
# ==============================================================

# ---------------------------------------------------------------
# MODULE VPC
# ---------------------------------------------------------------
module "vpc" {
  source      = "./modules/vpc"
  project     = var.project
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
}

# ---------------------------------------------------------------
# MODULE EKS — Cluster Kubernetes (API Java dockerisée)
# ---------------------------------------------------------------
module "eks" {
  source      = "./modules/eks"
  project     = var.project
  environment = var.environment

  cluster_version    = var.eks_cluster_version
  private_subnet_ids = module.vpc.private_subnet_ids
  eks_nodes_sg_id    = module.vpc.eks_nodes_sg_id

  node_instance_type = var.eks_node_instance_type
  node_desired       = var.eks_node_desired
  node_min           = var.eks_node_min
  node_max           = var.eks_node_max

  depends_on = [module.vpc]
}

# ---------------------------------------------------------------
# RDS PostgreSQL — Base de données managée
# ---------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-${var.environment}-db-subnet"
  subnet_ids = module.vpc.private_subnet_ids
  tags       = { Name = "${var.project}-db-subnet-group" }
}

resource "aws_db_instance" "postgres" {
  identifier        = "${var.project}-${var.environment}-postgres"
  engine            = "postgres"
  engine_version    = "15.4"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [module.vpc.rds_sg_id]

  multi_az               = var.environment == "prod" ? true : false
  publicly_accessible    = false
  deletion_protection    = var.environment == "prod" ? true : false
  skip_final_snapshot    = var.environment == "prod" ? false : true
  final_snapshot_identifier = var.environment == "prod" ? "${var.project}-final-snapshot" : null

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "mon:04:00-mon:05:00"

  performance_insights_enabled = true

  tags = { Name = "${var.project}-${var.environment}-postgres" }
}

# ---------------------------------------------------------------
# MODULE LAMBDA — Authentification serverless
# ---------------------------------------------------------------
module "lambda" {
  source      = "./modules/lambda"
  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  lambda_runtime = var.lambda_runtime
  lambda_memory  = var.lambda_memory
  lambda_timeout = var.lambda_timeout

  db_host     = aws_db_instance.postgres.address
  db_name     = var.db_name
  db_username = var.db_username
  db_password = var.db_password
  jwt_secret  = random_password.jwt_secret.result

  cors_origins = "https://infoline.com,https://admin.infoline.com"
  alert_email  = "devops@infoline.com"

  depends_on = [module.vpc, aws_db_instance.postgres]
}

# Génération d'un JWT secret fort aléatoire
resource "random_password" "jwt_secret" {
  length  = 64
  special = true
}

# ---------------------------------------------------------------
# HELM CHARTS sur EKS
# ---------------------------------------------------------------

# NGINX Ingress Controller (Load Balancer Kubernetes)
resource "helm_release" "nginx_ingress" {
  name             = "nginx-ingress"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "4.8.3"

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }
  set {
    name  = "controller.metrics.enabled"
    value = "true"
  }

  depends_on = [module.eks]
}

# Cluster Autoscaler
resource "helm_release" "cluster_autoscaler" {
  name             = "cluster-autoscaler"
  repository       = "https://kubernetes.github.io/autoscaler"
  chart            = "cluster-autoscaler"
  namespace        = "kube-system"
  version          = "9.29.3"

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "awsRegion"
    value = var.aws_region
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.autoscaler_role_arn
  }

  depends_on = [module.eks]
}

# Prometheus + Grafana Stack (monitoring)
resource "helm_release" "kube_prometheus" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = "55.5.0"

  set {
    name  = "grafana.enabled"
    value = "true"
  }
  set {
    name  = "alertmanager.enabled"
    value = "true"
  }
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "15d"
  }

  depends_on = [module.eks]
}

# ---------------------------------------------------------------
# OUTPUTS GLOBAUX
# ---------------------------------------------------------------
output "eks_cluster_name"      { value = module.eks.cluster_name }
output "eks_cluster_endpoint"  { value = module.eks.cluster_endpoint }
output "login_api_url"         { value = module.lambda.api_gateway_url }
output "rds_endpoint"          { value = aws_db_instance.postgres.address }
output "ecr_api_url"           { value = module.eks.ecr_api_url }
output "ecr_frontend_main"     { value = module.eks.ecr_frontend_main_url }
output "ecr_frontend_backoffice" { value = module.eks.ecr_frontend_backoffice_url }
output "sns_alerts_arn"        { value = module.lambda.sns_alerts_arn }

output "kubectl_config_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
