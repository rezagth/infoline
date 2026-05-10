variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-3" # Paris
}

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "infoline"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "eks_cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "eks_node_desired" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "eks_node_min" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "eks_node_max" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 5
}

variable "eks_node_instance_type" {
  description = "EC2 instance type for EKS nodes"
  type        = string
  default     = "t3.medium"
}

variable "lambda_runtime" {
  description = "Lambda runtime"
  type        = string
  default     = "java17"
}

variable "lambda_memory" {
  description = "Lambda memory (MB)"
  type        = number
  default     = 512
}

variable "lambda_timeout" {
  description = "Lambda timeout (seconds)"
  type        = number
  default     = 30
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "infoline_db"
}

variable "db_username" {
  description = "PostgreSQL admin username"
  type        = string
  default     = "infoline_admin"
  sensitive   = true
}

variable "db_password" {
  description = "PostgreSQL admin password"
  type        = string
  sensitive   = true
}
