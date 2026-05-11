variable "project"            { type = string }
variable "environment"        { type = string }
variable "cluster_version"    { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "eks_nodes_sg_id"    { type = string }
variable "node_instance_type" { type = string }
variable "node_desired"       { type = number }
variable "node_min"           { type = number }
variable "node_max"           { type = number }
variable "admin_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
