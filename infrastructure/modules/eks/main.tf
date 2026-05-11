provider "aws" {
  region = "eu-west-1"
}

resource "aws_eks_cluster" "main" {
  name     = "mon-cluster"
  role_arn = aws_iam_role.eks.arn

  vpc_config {
    subnet_ids = ["subnet-xxxxxx", "subnet-yyyyyy"]
  }
}

resource "aws_iam_role" "eks" {
  name = "eks-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks.name
}