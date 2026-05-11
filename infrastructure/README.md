# InfoLine — Infrastructure as Code

## Architecture AWS

```
Internet
    │
    ▼
[CloudFront / Route53]
    │
    ├─── [API Gateway HTTP] ──► [Lambda login] ──► [RDS PostgreSQL]
    │         (auth serverless)
    │
    └─── [ALB / NGINX Ingress] ──► [EKS Cluster]
                                        │
                                   [infoline-api]  (Java, 2-10 pods)
                                        │
                                   [RDS PostgreSQL] (subnet privé)
```

## Structure du projet

```
infoline-infra/
├── main.tf                        # Assemblage des modules
├── variables.tf                   # Variables globales
├── provider.tf                    # AWS + Kubernetes + Helm providers
├── modules/
│   ├── vpc/main.tf                # VPC, subnets, NAT, Security Groups
│   ├── eks/main.tf                # Cluster EKS, Node Group, ECR, Autoscaler
│   └── lambda/main.tf             # Lambda login, API Gateway, SNS alertes
├── eks/
│   └── api-deployment.yaml        # Manifests Kubernetes (Deployment, HPA, Ingress)
├── ci-cd/
│   └── pipeline.yml               # GitHub Actions CI/CD
└── environments/
    ├── dev/terraform.tfvars
    └── prod/terraform.tfvars
```

## Prérequis

- Terraform >= 1.5
- AWS CLI configuré (`aws configure`)
- kubectl
- helm >= 3

## Déploiement

### 1. Initialiser le backend S3 (une seule fois)

```bash
aws s3 mb s3://infoline-terraform-state --region eu-west-3
aws dynamodb create-table \
  --table-name infoline-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-3
```

### 2. Déployer l'environnement dev

```bash
cd infoline-infra
terraform init
terraform plan -var-file=environments/dev/terraform.tfvars \
               -var="db_password=VOTRE_MDP_SECURE"
terraform apply -var-file=environments/dev/terraform.tfvars \
                -var="db_password=VOTRE_MDP_SECURE"
```

### 3. Configurer kubectl

```bash
# La commande exacte est affichée en output Terraform
aws eks update-kubeconfig --region eu-west-3 --name infoline-dev-eks
kubectl get nodes
```

### 4. Déployer l'API sur Kubernetes

```bash
# Remplacer les placeholders par les vraies valeurs (fait automatiquement par CI/CD)
kubectl apply -f eks/api-deployment.yaml
kubectl get pods -n infoline
```

## CI/CD

Le pipeline GitHub Actions (`.github/workflows/pipeline.yml`) :

1. **Build & Test** : Maven, JUnit
2. **Docker Build** : image poussée sur ECR
3. **Lambda deploy** : JAR uploadé sur S3 → `aws lambda update-function-code`
4. **EKS deploy** : `kubectl set image` + rollout watch + rollback automatique

Variables GitHub Secrets à configurer :
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

## Monitoring

- **CloudWatch** : logs Lambda + API Gateway, alarmes erreurs/latence
- **Prometheus + Grafana** : métriques Kubernetes (installé via Helm)
- **SNS** : notifications email `devops@infoline.com` en cas d'incident
- **EKS Control Plane Logs** : audit, scheduler, API dans CloudWatch

## Scalabilité

| Composant | Min | Max | Déclencheur |
|-----------|-----|-----|-------------|
| EKS Nodes | 2   | 10  | CPU node > 70% |
| API Pods  | 2   | 10  | CPU pod > 70% ou RAM > 80% |
| Lambda    | 1   | 100 | Concurrence provisionnée > 70% |
| RDS       | -   | -   | Multi-AZ en prod (failover auto) |
# infoline-infra
