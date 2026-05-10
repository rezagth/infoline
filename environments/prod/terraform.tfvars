# Environnement PROD — haute disponibilité, multi-AZ

aws_region  = "eu-west-3"
environment = "prod"
project     = "infoline"

# Réseau
vpc_cidr = "10.1.0.0/16"

# EKS — cluster de production
eks_cluster_version    = "1.29"
eks_node_instance_type = "t3.medium"
eks_node_desired       = 3
eks_node_min           = 2
eks_node_max           = 10

# Lambda
lambda_runtime = "java17"
lambda_memory  = 1024    # Plus de mémoire en prod pour réduire la latence JVM
lambda_timeout = 30

# RDS — multi-AZ pour la HA
db_instance_class = "db.t3.small"
db_name           = "infoline_db"
db_username       = "infoline_admin"
# db_password     = à passer via TF_VAR_db_password ou pipeline CI/CD sécurisé
