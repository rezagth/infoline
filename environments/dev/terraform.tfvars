# Environnement DEV — ressources minimales pour économiser les coûts

aws_region  = "eu-west-3"
environment = "dev"
project     = "infoline"

# Réseau
vpc_cidr = "10.0.0.0/16"

# EKS — petit cluster de dev
eks_cluster_version    = "1.29"
eks_node_instance_type = "t3.small"
eks_node_desired       = 1
eks_node_min           = 1
eks_node_max           = 3

# Lambda
lambda_runtime = "java17"
lambda_memory  = 512
lambda_timeout = 30

# RDS — instance minimale
db_instance_class = "db.t3.micro"
db_name           = "infoline_db"
db_username       = "infoline_admin"
# db_password     = à passer via TF_VAR_db_password ou AWS Secrets
