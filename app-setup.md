# Blog Platform – Complete AWS EKS Setup Guide

A step-by-step training guide to provision infrastructure and deploy the Blog Platform
microservices from scratch on AWS.

---

## Architecture Overview

```
Internet
   │
   ▼
AWS ALB (Application Load Balancer)
   │
   ├── /api/auth    ──► auth-service   (port 3001)  ──► RDS auth_db
   ├── /api/posts   ──► post-service   (port 3002)  ──► RDS posts_db
   ├── /api/comments──► comment-service(port 3003)  ──► RDS comments_db
   └── /            ──► frontend       (port 80)
```

**AWS Services used:**
- **ECR** – stores Docker images for all 4 services
- **EKS** – Kubernetes cluster running all service pods
- **RDS** PostgreSQL 15 – managed relational database (one instance, database: `blogspace`)
- **ALB** – routes external traffic into the cluster via AWS Load Balancer Controller

---

## Environment Variables (set once, reuse everywhere)

```bash
export AWS_ACCOUNT_ID=053160386547
export AWS_REGION=ap-northeast-1
export CLUSTER_NAME=quantam-cluster
export ECR_REGISTRY=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
export APP_DOMAIN=amazontechspace.com

# RDS (update RDS_HOST after the instance is created in Step 3)
export RDS_IDENTIFIER=blogspace
export RDS_HOST=<PASTE_RDS_ENDPOINT_HERE>
export DB_USER=postgres
export DB_PASS=Quant1234
export DB_NAME=blogspace
```

---

## Prerequisites

Install the following tools before starting:

```bash
# AWS CLI
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /            # macOS
# For Linux: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-linux.html

# Configure AWS credentials
aws configure
# Enter: AWS Access Key ID, Secret Access Key, Region (us-west-2), Output format (json)

# eksctl
brew tap weaveworks/tap
brew install weaveworks/tap/eksctl

# kubectl
brew install kubectl

# Helm (for ALB controller)
brew install helm

# Docker Desktop – https://www.docker.com/products/docker-desktop/

# Node.js 20+
brew install node@20
```

Verify installs:
```bash
aws --version
eksctl version
kubectl version --client
helm version
docker --version
node --version
```

---

## Step 1 – Create ECR Repositories

ECR stores the Docker images that EKS pulls during deployment.

```bash
# Authenticate Docker with ECR
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ECR_REGISTRY

# Create one repository per service
aws ecr create-repository --repository-name blog-auth-service    --region $AWS_REGION
aws ecr create-repository --repository-name blog-post-service    --region $AWS_REGION
aws ecr create-repository --repository-name blog-comment-service --region $AWS_REGION
aws ecr create-repository --repository-name blog-frontend        --region $AWS_REGION

# Verify
aws ecr describe-repositories --region $AWS_REGION \
  --query 'repositories[].repositoryName' --output table
```

You should see four repositories:
```
blog-auth-service
blog-post-service
blog-comment-service
blog-frontend
```

---

## Step 2 – Create the EKS Cluster

This creates a managed Kubernetes cluster with 2 worker nodes (auto-scaling to 3).

```bash
eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --nodegroup-name blog-nodes \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 3 \
  --managed
```

> This takes **15–20 minutes**. eksctl creates the VPC, subnets, node group, and configures kubectl automatically.

Verify the cluster is ready:
```bash
kubectl get nodes
# Expected: 2 nodes with STATUS = Ready
```

Save the VPC ID for the RDS step:
```bash
export VPC_ID=$(aws eks describe-cluster \
  --name $CLUSTER_NAME --region $AWS_REGION \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

echo "VPC ID: $VPC_ID"
```

---

## Step 3 – Create the RDS PostgreSQL Database

### 3a. Create a Security Group for RDS

```bash
# Create the security group
export RDS_SG_ID=$(aws ec2 create-security-group \
  --group-name blog-rds-sg \
  --description "Allow PostgreSQL from EKS nodes" \
  --vpc-id $VPC_ID \
  --region $AWS_REGION \
  --query 'GroupId' --output text)

echo "RDS Security Group: $RDS_SG_ID"
```

Get the EKS node security group and allow it to reach PostgreSQL:
```bash
# Get the EKS node security group ID
export EKS_NODE_SG=$(aws eks describe-cluster \
  --name $CLUSTER_NAME --region $AWS_REGION \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

# Allow PostgreSQL (5432) from EKS nodes
aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG_ID \
  --protocol tcp \
  --port 5432 \
  --source-group $EKS_NODE_SG \
  --region $AWS_REGION
```

### 3b. Create the DB Subnet Group

```bash
# Get private subnets from the EKS VPC
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
  --db-instance-identifier $RDS_IDENTIFIER \
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

> This takes **5–10 minutes**. Wait for it to become available:

```bash
aws rds wait db-instance-available \
  --db-instance-identifier $RDS_IDENTIFIER \
  --region $AWS_REGION

echo "RDS is ready!"

# Get the endpoint
export RDS_HOST=$(aws rds describe-db-instances \
  --db-instance-identifier $RDS_IDENTIFIER \
  --region $AWS_REGION \
  --query 'DBInstances[0].Endpoint.Address' --output text)

echo "RDS Endpoint: $RDS_HOST"
```

> **Important:** Copy the RDS endpoint and update `k8s/secrets.yaml` — replace `<RDS_ENDPOINT>` with this value. Then re-apply the secret: `kubectl apply -f k8s/secrets.yaml`

---

## Step 4 – Install the AWS Load Balancer Controller

The ALB Controller lets Kubernetes create an AWS Application Load Balancer via an Ingress resource.

### 4a. Enable OIDC for the Cluster

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster $CLUSTER_NAME \
  --region $AWS_REGION \
  --approve
```

### 4b. Create IAM Policy for the ALB Controller

```bash
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json \
  --region $AWS_REGION
```

### 4c. Create IAM Service Account

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
```

Verify it is running:
```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
# Expected: READY 2/2
```

---

## Step 5 – Initialize Database Schema (Run Once)

The Prisma schema is pushed to RDS **once** before deploying pods. Pods do NOT run
`prisma db push` on startup (that would cause data loss with multiple replicas).

Run from inside the cluster using a temporary pod (RDS is not publicly accessible):

```bash
# Auth DB schema
kubectl run prisma-auth --rm -it \
  --image=$ECR_REGISTRY/blog-auth-service:latest \
  --restart=Never \
  --env="DATABASE_URL=postgresql://$DB_USER:$DB_PASS@$RDS_HOST:5432/$DB_NAME?sslmode=require" \
  -- sh -c "npx prisma db push --skip-generate"

# Posts DB schema
kubectl run prisma-posts --rm -it \
  --image=$ECR_REGISTRY/blog-post-service:latest \
  --restart=Never \
  --env="DATABASE_URL=postgresql://$DB_USER:$DB_PASS@$RDS_HOST:5432/$DB_NAME?sslmode=require" \
  -- sh -c "npx prisma db push --skip-generate"

# Comments DB schema
kubectl run prisma-comments --rm -it \
  --image=$ECR_REGISTRY/blog-comment-service:latest \
  --restart=Never \
  --env="DATABASE_URL=postgresql://$DB_USER:$DB_PASS@$RDS_HOST:5432/$DB_NAME?sslmode=require" \
  -- sh -c "npx prisma db push --skip-generate"
```

> Run this step again only when the Prisma schema file changes.

---

## Step 6 – Build Docker Images

Run all build commands from the **project root directory**.

```bash
# Authenticate Docker with ECR (refresh token expires in 12 hours)
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ECR_REGISTRY
```

### Build auth-service
```bash
docker build -t blog-auth-service ./services/auth-service
```

### Build post-service
```bash
docker build -t blog-post-service ./services/post-service
```

### Build comment-service
```bash
docker build -t blog-comment-service ./services/comment-service
```

### Build frontend
```bash
docker build \
  --build-arg VITE_API_URL=http://$APP_DOMAIN \
  -t blog-frontend \
  ./frontend
```

---

## Step 7 – Tag and Push Images to ECR

### Tag all images with the ECR registry URL

```bash
docker tag blog-auth-service    $ECR_REGISTRY/blog-auth-service:latest
docker tag blog-post-service    $ECR_REGISTRY/blog-post-service:latest
docker tag blog-comment-service $ECR_REGISTRY/blog-comment-service:latest
docker tag blog-frontend        $ECR_REGISTRY/blog-frontend:latest
```

### Push all images to ECR

```bash
docker push $ECR_REGISTRY/blog-auth-service:latest
docker push $ECR_REGISTRY/blog-post-service:latest
docker push $ECR_REGISTRY/blog-comment-service:latest
docker push $ECR_REGISTRY/blog-frontend:latest
```

Verify images are in ECR:
```bash
aws ecr list-images --repository-name blog-auth-service    --region $AWS_REGION
aws ecr list-images --repository-name blog-post-service    --region $AWS_REGION
aws ecr list-images --repository-name blog-comment-service --region $AWS_REGION
aws ecr list-images --repository-name blog-frontend        --region $AWS_REGION
```

---

## Step 8 – Deploy to Kubernetes

### 8a. Create Namespace

```bash
kubectl apply -f k8s/namespace.yaml
kubectl get namespace blog
```

### 8b. Create Secrets

```bash
kubectl apply -f k8s/secrets.yaml
kubectl get secret blog-secrets -n blog
```

---

### 8c. Deploy Frontend

```bash
# Apply Deployment
kubectl apply -f frontend/deployment.yaml

# Apply Service (ClusterIP on port 80)
kubectl apply -f frontend/service.yaml

# Verify
kubectl get pods -n blog -l app=frontend
kubectl get service frontend -n blog
```

Wait until pods are Running:
```bash
kubectl rollout status deployment/frontend -n blog
```

---

### 8d. Deploy Post Service

```bash
# Apply Deployment
kubectl apply -f k8s/post-service/deployment.yaml

# Apply Service (ClusterIP on port 3002)
kubectl apply -f k8s/post-service/service.yaml

# Apply HPA (auto-scales 2–5 replicas at 70% CPU)
kubectl apply -f k8s/post-service/hpa.yaml

# Verify
kubectl get pods -n blog -l app=post-service
kubectl rollout status deployment/post-service -n blog
```

---

### 8e. Deploy Comment Service

```bash
# Apply Deployment
kubectl apply -f k8s/comment-service/deployment.yaml

# Apply Service (ClusterIP on port 3003)
kubectl apply -f k8s/comment-service/service.yaml

# Apply HPA (auto-scales 2–5 replicas at 70% CPU)
kubectl apply -f k8s/comment-service/hpa.yaml

# Verify
kubectl get pods -n blog -l app=comment-service
kubectl rollout status deployment/comment-service -n blog
```

---

### 8f. Deploy Auth Service

```bash
# Apply Deployment
kubectl apply -f k8s/auth-service/deployment.yaml

# Apply Service (ClusterIP on port 3001)
kubectl apply -f k8s/auth-service/service.yaml

# Apply HPA (auto-scales 2–5 replicas at 70% CPU)
kubectl apply -f k8s/auth-service/hpa.yaml

# Verify
kubectl get pods -n blog -l app=auth-service
kubectl rollout status deployment/auth-service -n blog
```

---

### 8g. Apply Ingress (ALB)

```bash
kubectl apply -f k8s/ingress.yaml

# Watch ALB being provisioned (takes 2–3 minutes)
kubectl get ingress -n blog --watch
```

Once the ADDRESS column fills in, note the ALB DNS name:
```bash
export ALB_DNS=$(kubectl get ingress blog-ingress -n blog \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "ALB DNS: $ALB_DNS"
```

---

## Step 9 – Configure DNS

In your DNS provider (Route 53, Cloudflare, etc.), create a CNAME record:

```
Type:  CNAME
Name:  amazontechspace.com   (or @ for root)
Value: <ALB_DNS from above>
TTL:   300
```

If using **Route 53**:
```bash
# Get your hosted zone ID
export ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='amazontechspace.com.'].Id" \
  --output text | cut -d'/' -f3)

# Create the record
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

## Step 10 – Verify Everything

```bash
# All pods in the blog namespace
kubectl get pods -n blog

# All services
kubectl get services -n blog

# Ingress with ALB address
kubectl get ingress -n blog

# HPA status
kubectl get hpa -n blog

# Test each endpoint
curl http://$APP_DOMAIN/api/auth/health
curl http://$APP_DOMAIN/api/posts/health
# (Open browser) http://amazontechspace.com
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

## Updating a Service (After Code Changes)

```bash
# 1. Rebuild the image
docker build -t blog-post-service ./services/post-service

# 2. Tag with a new version (use git SHA for traceability)
export GIT_SHA=$(git rev-parse --short HEAD)
docker tag blog-post-service $ECR_REGISTRY/blog-post-service:$GIT_SHA
docker tag blog-post-service $ECR_REGISTRY/blog-post-service:latest

# 3. Push to ECR
docker push $ECR_REGISTRY/blog-post-service:$GIT_SHA
docker push $ECR_REGISTRY/blog-post-service:latest

# 4. Roll out the new image (triggers a rolling update)
kubectl set image deployment/post-service \
  post-service=$ECR_REGISTRY/blog-post-service:$GIT_SHA \
  -n blog

# 5. Watch the rollout
kubectl rollout status deployment/post-service -n blog
```

---

## Useful Debugging Commands

```bash
# Describe a pod (see Events if something fails)
kubectl describe pod <pod-name> -n blog

# View logs
kubectl logs -l app=post-service -n blog --tail=50

# Follow live logs from all post-service pods
kubectl logs -f -l app=post-service -n blog

# Exec into a running pod
kubectl exec -it <pod-name> -n blog -- sh

# Check HPA scaling decisions
kubectl describe hpa post-service-hpa -n blog

# Restart all pods of a service (rolling restart)
kubectl rollout restart deployment/post-service -n blog

# Delete and recreate a stuck pod
kubectl delete pod <pod-name> -n blog
```

---

## Local Development (docker-compose)

For local testing without AWS, use docker-compose which runs MySQL locally:

```bash
# Start all services
docker-compose up --build

# Stop (keeps data)
docker-compose down

# Stop AND delete all data
docker-compose down -v
```

Services will be available at:
- Frontend:       http://localhost
- Auth service:   http://localhost:3001
- Post service:   http://localhost:3002
- Comment service: http://localhost:3003

> `prisma db push` runs automatically on startup in docker-compose (safe for single-instance local dev).
> In production (k8s), schema is applied once manually (Step 5) — NOT on pod startup.

---

## Key Design Decisions

| Decision | Reason |
|---|---|
| `prisma db push` removed from k8s pod startup | With `replicas: 2`, both pods run it simultaneously causing RDS table drops and data loss |
| Schema initialized once via a temp pod (Step 5) | Safe single-run ensures no race conditions |
| All services use `ClusterIP` | Internal-only; ALB is the single public entry point |
| HPA on all services (2–5 replicas, 70% CPU) | Handles traffic spikes without manual scaling |
| Separate RDS databases per service | Follows microservice principle of isolated data stores |
