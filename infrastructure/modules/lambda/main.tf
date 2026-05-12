# ---------------------------------------------------------------
# MODULE LAMBDA — Authentification serverless Java
# ---------------------------------------------------------------

locals {
  name = "${var.project}-${var.environment}"
}

# Rôle IAM pour Lambda
resource "aws_iam_role" "lambda" {
  name = "${local.name}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda.name
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  role       = aws_iam_role.lambda.name
}

# Security Group Lambda
resource "aws_security_group" "lambda" {
  name        = "${local.name}-lambda-sg"
  description = "Lambda login function"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Bucket S3 pour stocker le JAR
resource "aws_s3_bucket" "lambda_artifacts" {
  bucket        = "${local.name}-lambda-artifacts"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "lambda_artifacts" {
  bucket = aws_s3_bucket.lambda_artifacts.id
  versioning_configuration { status = "Enabled" }
}

# Fonction Lambda
resource "aws_lambda_function" "login" {
  function_name = "${local.name}-login"
  role          = aws_iam_role.lambda.arn

  # Déployé via CI/CD (s3_bucket + s3_key mis à jour par pipeline)
  s3_bucket = aws_s3_bucket.lambda_artifacts.bucket
  s3_key    = "login/login-function-latest.jar"

  runtime     = var.lambda_runtime   # java17 — depuis variables
  handler     = "infoline.LoginHandler::handleRequest"
  memory_size = var.lambda_memory
  timeout     = var.lambda_timeout

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_HOST      = var.db_host
      DB_NAME      = var.db_name
      DB_USERNAME  = var.db_username
      DB_PASSWORD  = var.db_password
      JWT_SECRET   = var.jwt_secret
      CORS_ORIGINS = var.cors_origins
    }
  }

  depends_on = [aws_s3_bucket.lambda_artifacts]
}

# API Gateway HTTP → Lambda
resource "aws_apigatewayv2_api" "login" {
  name          = "${local.name}-login-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = split(",", var.cors_origins)
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
  }
}

resource "aws_apigatewayv2_integration" "login" {
  api_id             = aws_apigatewayv2_api.login.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.login.invoke_arn
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "login" {
  api_id    = aws_apigatewayv2_api.login.id
  route_key = "POST /auth/login"
  target    = "integrations/${aws_apigatewayv2_integration.login.id}"
}

resource "aws_apigatewayv2_stage" "login" {
  api_id      = aws_apigatewayv2_api.login.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api_gw" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.login.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.login.execution_arn}/*/*"
}

# SNS pour alertes
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Outputs
output "api_gateway_url" { value = aws_apigatewayv2_stage.login.invoke_url }
output "sns_alerts_arn"  { value = aws_sns_topic.alerts.arn }