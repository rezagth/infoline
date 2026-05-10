# ==============================================================
# MODULE LAMBDA — Fonction serverless Login (User + Admin)
# Fournisseur : AWS Lambda + API Gateway HTTP
# ==============================================================

locals {
  name = "${var.project}-${var.environment}-login"
}

# ---------------------------------------------------------------
# IAM Role pour la fonction Lambda
# ---------------------------------------------------------------
resource "aws_iam_role" "lambda_login" {
  name = "${local.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Politique de base : écriture logs CloudWatch
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_login.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Accès VPC (pour joindre RDS PostgreSQL depuis Lambda)
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_login.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Accès Secrets Manager — récupération des credentials DB et JWT secret
resource "aws_iam_role_policy" "lambda_secrets" {
  name = "${local.name}-secrets-policy"
  role = aws_iam_role.lambda_login.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:*:secret:${var.project}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------------
# Security Group pour Lambda (dans le VPC)
# ---------------------------------------------------------------
resource "aws_security_group" "lambda_login" {
  name        = "${local.name}-sg"
  description = "Lambda login function SG"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound (RDS + Secrets Manager)"
  }

  tags = { Name = "${local.name}-sg" }
}

# ---------------------------------------------------------------
# Secrets Manager — stockage sécurisé des secrets
# ---------------------------------------------------------------
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.project}/db-credentials"
  description             = "PostgreSQL credentials for InfoLine"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    host     = var.db_host
    port     = 5432
    dbname   = var.db_name
  })
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "${var.project}/jwt-secret"
  description             = "JWT signing secret for InfoLine login"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id     = aws_secretsmanager_secret.jwt_secret.id
  secret_string = jsonencode({ jwt_secret = var.jwt_secret })
}

# ---------------------------------------------------------------
# Fonction Lambda — Login
# Le JAR est uploadé via CI/CD (S3 source)
# ---------------------------------------------------------------
resource "aws_lambda_function" "login" {
  function_name = local.name
  description   = "InfoLine - Authentication (users & admins)"

  # Source du code : bucket S3 alimenté par le pipeline CI/CD
  s3_bucket = aws_s3_bucket.lambda_artifacts.id
  s3_key    = "login/login-function-latest.jar"

  runtime       = var.lambda_runtime  # java17
  handler       = "com.infoline.auth.LoginHandler::handleRequest"
  role          = aws_iam_role.lambda_login.arn
  memory_size   = var.lambda_memory   # 512 MB (JVM nécessite plus de mémoire)
  timeout       = var.lambda_timeout  # 30s

  # SnapStart = démarrage JVM ultra-rapide (réduit le cold start Java)
  snap_start {
    apply_on = "PublishedVersions"
  }

  # Déploiement dans le VPC pour accéder à RDS
  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda_login.id]
  }

  # Variables d'environnement (valeurs sensibles via Secrets Manager)
  environment {
    variables = {
      ENVIRONMENT          = var.environment
      DB_SECRET_ARN        = aws_secretsmanager_secret.db_credentials.arn
      JWT_SECRET_ARN       = aws_secretsmanager_secret.jwt_secret.arn
      AWS_REGION_NAME      = var.aws_region
      LOG_LEVEL            = var.environment == "prod" ? "WARN" : "DEBUG"
      CORS_ALLOWED_ORIGINS = var.cors_origins
    }
  }

  # Tracing X-Ray pour le monitoring
  tracing_config {
    mode = "Active"
  }

  tags = { Name = local.name }

  depends_on = [aws_s3_bucket_object.lambda_placeholder]
}

# Version publiée pour SnapStart (obligatoire)
resource "aws_lambda_alias" "login_live" {
  name             = "live"
  description      = "Live alias pointing to latest published version"
  function_name    = aws_lambda_function.login.function_name
  function_version = aws_lambda_function.login.version
}

# Auto-scaling de la concurrence Lambda
resource "aws_appautoscaling_target" "lambda_login" {
  max_capacity       = 100
  min_capacity       = 1
  resource_id        = "function:${aws_lambda_function.login.function_name}:live"
  scalable_dimension = "lambda:function:ProvisionedConcurrency"
  service_namespace  = "lambda"
  depends_on         = [aws_lambda_alias.login_live]
}

resource "aws_appautoscaling_policy" "lambda_login_scaling" {
  name               = "${local.name}-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.lambda_login.resource_id
  scalable_dimension = aws_appautoscaling_target.lambda_login.scalable_dimension
  service_namespace  = aws_appautoscaling_target.lambda_login.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "LambdaProvisionedConcurrencyUtilization"
    }
    target_value = 0.7 # Scale up à 70% d'utilisation
  }
}

# ---------------------------------------------------------------
# S3 — Bucket d'artifacts Lambda (alimenté par CI/CD)
# ---------------------------------------------------------------
resource "aws_s3_bucket" "lambda_artifacts" {
  bucket = "${var.project}-${var.environment}-lambda-artifacts"
  tags   = { Name = "${var.project}-lambda-artifacts" }
}

resource "aws_s3_bucket_versioning" "lambda_artifacts" {
  bucket = aws_s3_bucket.lambda_artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lambda_artifacts" {
  bucket = aws_s3_bucket.lambda_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "lambda_artifacts" {
  bucket                  = aws_s3_bucket.lambda_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Placeholder vide pour permettre la création initiale de la fonction Lambda
resource "aws_s3_bucket_object" "lambda_placeholder" {
  bucket  = aws_s3_bucket.lambda_artifacts.id
  key     = "login/login-function-latest.jar"
  content = "placeholder"
  lifecycle { ignore_changes = [content, etag] }
}

# ---------------------------------------------------------------
# API Gateway HTTP — expose la Lambda en endpoint REST
# ---------------------------------------------------------------
resource "aws_apigatewayv2_api" "login" {
  name          = "${local.name}-api"
  protocol_type = "HTTP"
  description   = "InfoLine Login API"

  cors_configuration {
    allow_headers = ["Content-Type", "Authorization", "X-Requested-With"]
    allow_methods = ["POST", "OPTIONS"]
    allow_origins = split(",", var.cors_origins)
    max_age       = 300
  }
}

resource "aws_apigatewayv2_stage" "login" {
  api_id      = aws_apigatewayv2_api.login.id
  name        = var.environment
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      sourceIp       = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      protocol       = "$context.protocol"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  default_route_settings {
    throttling_burst_limit = 1000
    throttling_rate_limit  = 500
  }
}

# Intégration Lambda → API Gateway
resource "aws_apigatewayv2_integration" "login" {
  api_id             = aws_apigatewayv2_api.login.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_alias.login_live.invoke_arn
  payload_format_version = "2.0"
}

# Routes exposées
resource "aws_apigatewayv2_route" "login_user" {
  api_id    = aws_apigatewayv2_api.login.id
  route_key = "POST /auth/login"
  target    = "integrations/${aws_apigatewayv2_integration.login.id}"
}

resource "aws_apigatewayv2_route" "login_admin" {
  api_id    = aws_apigatewayv2_api.login.id
  route_key = "POST /auth/admin/login"
  target    = "integrations/${aws_apigatewayv2_integration.login.id}"
}

resource "aws_apigatewayv2_route" "register" {
  api_id    = aws_apigatewayv2_api.login.id
  route_key = "POST /auth/register"
  target    = "integrations/${aws_apigatewayv2_integration.login.id}"
}

resource "aws_apigatewayv2_route" "refresh_token" {
  api_id    = aws_apigatewayv2_api.login.id
  route_key = "POST /auth/refresh"
  target    = "integrations/${aws_apigatewayv2_integration.login.id}"
}

# Permission : API Gateway peut invoquer la Lambda
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.login.function_name
  qualifier     = aws_lambda_alias.login_live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.login.execution_arn}/*/*"
}

# ---------------------------------------------------------------
# CloudWatch — Logs et Alarmes
# ---------------------------------------------------------------
resource "aws_cloudwatch_log_group" "lambda_login" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 30
  tags              = { Name = "${local.name}-logs" }
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = 14
}

# Alarme : taux d'erreurs Lambda > 5%
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda login error rate too high"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.login.function_name
  }
}

# Alarme : durée d'exécution > 10s (cold start JVM)
resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  alarm_name          = "${local.name}-high-duration"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "p99"
  threshold           = 10000 # 10 secondes
  alarm_description   = "Lambda login P99 duration too high"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.login.function_name
  }
}

# SNS Topic pour les notifications (email, Slack, PagerDuty…)
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-${var.environment}-alerts"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------
output "login_function_name" { value = aws_lambda_function.login.function_name }
output "login_function_arn"  { value = aws_lambda_function.login.arn }
output "api_gateway_url"     { value = aws_apigatewayv2_stage.login.invoke_url }
output "artifacts_bucket"    { value = aws_s3_bucket.lambda_artifacts.bucket }
output "sns_alerts_arn"      { value = aws_sns_topic.alerts.arn }
