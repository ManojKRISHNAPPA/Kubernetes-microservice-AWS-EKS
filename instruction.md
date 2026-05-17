# Deployment Instructions

Blog platform microservices on AWS EKS with RDS PostgreSQL.

---

## Environment

| Variable | Value |
|----------|-------|
| AWS Account ID | `053160386547` |
| Region | `ap-northeast-1` |
| EKS Cluster | `quantam-cluster` |
| ECR Registry | `053160386547.dkr.ecr.ap-northeast-1.amazonaws.com` |
| RDS DB Name | `blogspace` |
| RDS DB User | `postgres` |
| Domain | `amazontechspace.com` |

---

## Prerequisites

Install these tools before starting:

```bash
# AWS CLI
brew install awscli        # macOS
aws configure              # enter Access Key, Secret Key, region: ap-northeast-1, output: json

# eksctl
brew tap weaveworks/tap
brew install weaveworks/tap/eksctl

# kubectl
brew install kubectl

# Helm (for ALB controller)
brew install helm

# Docker Desktop — https://www.docker.com/products/docker-desktop/
```

Verify:
```bash
aws --version && eksctl version && kubectl version --client && helm version && docker --version
```

Set environment variables (run once per terminal session):
```bash
export AWS_ACCOUNT_ID=053160386547
export AWS_REGION=ap-northeast-1
export CLUSTER_NAME=quantam-cluster
export ECR_REGISTRY=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
export DB_USER=postgres
export DB_PASS=Quant1234
export DB_NAME=blogspace
```

---

## Step 1 — Create ECR Repositories

```bash
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ECR_REGISTRY

aws ecr create-repository --repository-name blog-auth-service    --region $AWS_REGION
aws ecr create-repository --repository-name blog-post-service    --region $AWS_REGION
aws ecr create-repository --repository-name blog-comment-service --region $AWS_REGION
aws ecr create-repository --repository-name blog-frontend        --region $AWS_REGION

# Verify
aws ecr describe-repositories --region $AWS_REGION \
  --query 'repositories[].repositoryName' --output table
```

---

## Step 2 — Create the EKS Cluster

```bash
eksctl create cluster -f eks-cluster.yaml
```

> Takes **15–20 minutes**. eksctl creates the VPC, subnets, node group, and configures `kubectl` automatically.

Verify:
```bash
kubectl get nodes
# Expected: 3 nodes with STATUS = Ready
```

Save the VPC ID for Step 3:
```bash
export VPC_ID=$(aws eks describe-cluster \
  --name $CLUSTER_NAME --region $AWS_REGION \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

echo "VPC ID: $VPC_ID"
```

---

## Step 3 — Create RDS PostgreSQL

### 3a. Security Group

```bash
export RDS_SG_ID=$(aws ec2 create-security-group \
  --group-name blog-rds-sg \
  --description "Allow PostgreSQL from EKS nodes" \
  --vpc-id $VPC_ID \
  --region $AWS_REGION \
  --query 'GroupId' --output text)

echo "RDS SG: $RDS_SG_ID"

export EKS_NODE_SG=$(aws eks describe-cluster \
  --name $CLUSTER_NAME --region $AWS_REGION \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

# Allow port 5432 (PostgreSQL) from EKS nodes
aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG_ID \
  --protocol tcp \
  --port 5432 \
  --source-group $EKS_NODE_SG \
  --region $AWS_REGION
```

### 3b. Subnet Group

```bash
export SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].SubnetId' \
  --output text | tr '\t' ',')

aws rds create-db-subnet-group \
  --db-subnet-group-name blog-db-subnet-group \
  --db-subnet-group-description "Blog platform DB subnets" \
  --subnet-ids $(echo $SUBNET_IDS | tr ',' ' ') \
  --region $AWS_REGION
```

### 3c. Create the RDS Instance

```bash
aws rds create-db-instance \
  --db-instance-identifier $DB_NAME \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 15 \
  --master-username $DB_USER \
  --master-user-password $DB_PASS \
  --db-name $DB_NAME \
  --allocated-storage 20 \
  --storage-type gp2 \
  --vpc-security-group-ids $RDS_SG_ID \
  --db-subnet-group-name blog-db-subnet-group \
  --no-publicly-accessible \
  --backup-retention-period 7 \
  --region $AWS_REGION
```

> Takes **5–10 minutes**. Wait for it:

```bash
aws rds wait db-instance-available \
  --db-instance-identifier $DB_NAME \
  --region $AWS_REGION

export RDS_HOST=$(aws rds describe-db-instances \
  --db-instance-identifier $DB_NAME \
  --region $AWS_REGION \
  --query 'DBInstances[0].Endpoint.Address' --output text)

echo "RDS Endpoint: $RDS_HOST"
```

### 3d. Update secrets.yaml with the RDS Endpoint

Open `k8s/secrets.yaml` and replace `<RDS_ENDPOINT>` with the value of `$RDS_HOST`:

```yaml
db-auth-url:     "postgresql://postgres:Quant1234@<PASTE_RDS_HOST_HERE>:5432/blogspace?sslmode=require"
db-posts-url:    "postgresql://postgres:Quant1234@<PASTE_RDS_HOST_HERE>:5432/blogspace?sslmode=require"
db-comments-url: "postgresql://postgres:Quant1234@<PASTE_RDS_HOST_HERE>:5432/blogspace?sslmode=require"
```

---

## Step 4 — Install AWS Load Balancer Controller

### 4a. Enable OIDC

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster $CLUSTER_NAME \
  --region $AWS_REGION \
  --approve
```

### 4b. IAM Policy

```bash
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json \
  --region $AWS_REGION
```

### 4c. IAM Service Account

```bash
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --region $AWS_REGION
```

### 4d. Install via Helm

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# Verify
kubectl get deployment -n kube-system aws-load-balancer-controller
# Expected: READY 2/2
```

---

## Step 5 — Build and Push Docker Images

```bash
# Re-authenticate (token expires every 12 hours)
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ECR_REGISTRY

# Build
docker build -t $ECR_REGISTRY/blog-auth-service:latest    ./services/auth-service
docker build -t $ECR_REGISTRY/blog-post-service:latest    ./services/post-service
docker build -t $ECR_REGISTRY/blog-comment-service:latest ./services/comment-service
docker build -t $ECR_REGISTRY/blog-frontend:latest        ./frontend

# Push
docker push $ECR_REGISTRY/blog-auth-service:latest
docker push $ECR_REGISTRY/blog-post-service:latest
docker push $ECR_REGISTRY/blog-comment-service:latest
docker push $ECR_REGISTRY/blog-frontend:latest
```

---

## Step 6 — Deploy to Kubernetes

### 6a. Namespace and Secrets

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secrets.yaml

# Verify
kubectl get namespace blog
kubectl get secret blog-secrets -n blog
```

### 6b. Push DB Schema (Run Once — Never on Pod Startup)

Schema is applied once via a temporary pod. Pods do **not** run `prisma db push` on startup — doing so with 2 replicas causes table drops and data loss.

```bash
# Auth schema
kubectl run prisma-auth --rm -it \
  --image=$ECR_REGISTRY/blog-auth-service:latest \
  --restart=Never \
  --env="DATABASE_URL=postgresql://$DB_USER:$DB_PASS@$RDS_HOST:5432/$DB_NAME?sslmode=require" \
  -- sh -c "npx prisma db push --skip-generate"

# Posts schema
kubectl run prisma-posts --rm -it \
  --image=$ECR_REGISTRY/blog-post-service:latest \
  --restart=Never \
  --env="DATABASE_URL=postgresql://$DB_USER:$DB_PASS@$RDS_HOST:5432/$DB_NAME?sslmode=require" \
  -- sh -c "npx prisma db push --skip-generate"

# Comments schema
kubectl run prisma-comments --rm -it \
  --image=$ECR_REGISTRY/blog-comment-service:latest \
  --restart=Never \
  --env="DATABASE_URL=postgresql://$DB_USER:$DB_PASS@$RDS_HOST:5432/$DB_NAME?sslmode=require" \
  -- sh -c "npx prisma db push --skip-generate"
```

> Re-run this step only when a Prisma schema file changes.

### 6c. Deploy Services

```bash
kubectl apply -f k8s/auth-service/deployment.yaml
kubectl apply -f k8s/auth-service/service.yaml
kubectl apply -f k8s/auth-service/hpa.yaml

kubectl apply -f k8s/post-service/deployment.yaml
kubectl apply -f k8s/post-service/service.yaml
kubectl apply -f k8s/post-service/hpa.yaml

kubectl apply -f k8s/comment-service/deployment.yaml
kubectl apply -f k8s/comment-service/service.yaml
kubectl apply -f k8s/comment-service/hpa.yaml

kubectl apply -f frontend/deployment.yaml
kubectl apply -f frontend/service.yaml
```

### 6d. Apply Ingress

```bash
kubectl apply -f k8s/cluster-issuer.yaml
kubectl apply -f k8s/ingress.yaml

# Watch ALB being provisioned (takes 2–3 minutes)
kubectl get ingress -n blog --watch
```

Once the ADDRESS column fills in:
```bash
export ALB_DNS=$(kubectl get ingress blog-ingress -n blog \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "ALB DNS: $ALB_DNS"
```

---

## Step 7 — Configure DNS (Route 53)

```bash
export ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='amazontechspace.com.'].Id" \
  --output text | cut -d'/' -f3)

aws route53 change-resource-record-sets \
  --hosted-zone-id $ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"amazontechspace.com\",
        \"Type\": \"CNAME\",
        \"TTL\": 300,
        \"ResourceRecords\": [{\"Value\": \"$ALB_DNS\"}]
      }
    }]
  }"
```

---

## Step 8 — Verify Everything

```bash
# All pods should be Running
kubectl get pods -n blog

# Services
kubectl get services -n blog

# Ingress with ALB address
kubectl get ingress -n blog

# HPA status
kubectl get hpa -n blog

# Health checks
curl https://amazontechspace.com/api/auth/health
curl https://amazontechspace.com/api/posts/health
curl https://amazontechspace.com/api/comments/health
```

Expected pod output:
```
NAME                               READY   STATUS    RESTARTS
auth-service-xxxx-xxxx             1/1     Running   0
auth-service-xxxx-yyyy             1/1     Running   0
comment-service-xxxx-xxxx          1/1     Running   0
comment-service-xxxx-yyyy          1/1     Running   0
frontend-xxxx-xxxx                 1/1     Running   0
frontend-xxxx-yyyy                 1/1     Running   0
post-service-xxxx-xxxx             1/1     Running   0
post-service-xxxx-yyyy             1/1     Running   0
```

---

## CI/CD — Automated Deployments

After initial setup, GitHub Actions handles all deployments automatically on every push to `master`.

**Required GitHub Secrets** (set once in repo Settings → Secrets):
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

The pipeline detects which service changed and only rebuilds + redeploys that service. A commit touching only `services/auth-service/**` will not trigger a frontend rebuild.

---

## Updating a Service Manually

```bash
export GIT_SHA=$(git rev-parse --short HEAD)

docker build -t $ECR_REGISTRY/blog-post-service:$GIT_SHA ./services/post-service
docker push $ECR_REGISTRY/blog-post-service:$GIT_SHA

aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

kubectl set image deployment/post-service \
  post-service=$ECR_REGISTRY/blog-post-service:$GIT_SHA \
  -n blog

kubectl rollout status deployment/post-service -n blog --timeout=120s
```

---

## Debugging

```bash
# Pod events (first place to look when a pod won't start)
kubectl describe pod <pod-name> -n blog

# Live logs
kubectl logs -f -l app=post-service -n blog

# Logs from all replicas
kubectl logs -l app=auth-service -n blog --tail=50

# Shell into a running pod
kubectl exec -it <pod-name> -n blog -- sh

# HPA scaling decisions
kubectl describe hpa post-service-hpa -n blog

# Rolling restart (picks up new secrets without redeploying)
kubectl rollout restart deployment/auth-service -n blog
```

---

## Local Development (No AWS Required)

```bash
# Start all services locally with Docker Compose
docker-compose up --build

# Stop (keeps data)
docker-compose down

# Stop and wipe all data
docker-compose down -v
```

| Service | Local URL |
|---------|-----------|
| Frontend | http://localhost |
| Auth | http://localhost:3001 |
| Posts | http://localhost:3002 |
| Comments | http://localhost:3003 |

> Docker Compose uses MySQL locally. The production EKS setup uses PostgreSQL RDS — keep this in mind if testing schema changes locally before pushing.
