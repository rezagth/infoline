variable "project"            { type = string }
variable "environment"        { type = string }
variable "aws_region"         { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "lambda_runtime"     { type = string }
variable "lambda_memory"      { type = number }
variable "lambda_timeout"     { type = number }
variable "db_host"            { type = string }
variable "db_name"            { type = string }
variable "db_username"        { type = string; sensitive = true }
variable "db_password"        { type = string; sensitive = true }
variable "jwt_secret"         { type = string; sensitive = true }
variable "cors_origins"       { type = string; default = "*" }
variable "alert_email"        { type = string }
