#!/usr/bin/env bash
# MySocialSpace — Full EKS Deploy Script
#
# Usage:
#   ./deploy.sh [OPTIONS]
#
# Options:
#   --skip-build      Skip Docker build & push (reuse existing ECR images)
#   --skip-cluster    Skip EKS cluster creation check (cluster already exists)
#   --skip-infra      Skip NGINX Ingress + cert-manager installation
#   --tag TAG         Image tag to deploy (default: current git SHA)
#   --cluster NAME    EKS cluster name (default: project-k8s-cluster)
#   --region REGION   AWS region (default: us-west-2)
#
# Examples:
#   ./deploy.sh                              # Full fresh deploy
#   ./deploy.sh --skip-cluster --skip-infra  # Redeploy services only
#   ./deploy.sh --skip-build --tag abc123    # Deploy a specific existing image tag

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# DEFAULT CONFIGURATION  (edit these or override via CLI flags)
# ─────────────────────────────────────────────────────────────────────────────
AWS_ACCOUNT_ID="053160386547"
AWS_REGION="ap-northeast-1"
EKS_CLUSTER="quantam-cluster"
NAMESPACE="blog"
IMAGE_TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")

# ─────────────────────────────────────────────────────────────────────────────
# FLAGS
# ─────────────────────────────────────────────────────────────────────────────
SKIP_BUILD=false
SKIP_CLUSTER=false
SKIP_INFRA=false

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-build)   SKIP_BUILD=true;        shift ;;
    --skip-cluster) SKIP_CLUSTER=true;      shift ;;
    --skip-infra)   SKIP_INFRA=true;        shift ;;
    --tag)          IMAGE_TAG="$2";         shift 2 ;;
    --cluster)      EKS_CLUSTER="$2";       shift 2 ;;
    --region)       AWS_REGION="$2";        shift 2 ;;
    --help|-h)
      head -25 "$0" | grep '^#' | sed 's/^# *//'
      exit 0 ;;
    *)
      echo "Unknown option: $1  (use --help for usage)" >&2
      exit 1 ;;
  esac
done

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING HELPERS
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — PREREQUISITES
# ─────────────────────────────────────────────────────────────────────────────
section "Step 1 — Checking Prerequisites"

REQUIRED_TOOLS=(aws kubectl docker)
for tool in "${REQUIRED_TOOLS[@]}"; do
  if command -v "$tool" &>/dev/null; then
    ok "$tool  →  $(command -v "$tool")"
  else
    fail "$tool is not installed or not in \$PATH"
  fi
done

if ! command -v eksctl &>/dev/null; then
  warn "eksctl not found — EKS cluster creation will be skipped (--skip-cluster forced)"
  SKIP_CLUSTER=true
else
  ok "eksctl  →  $(command -v eksctl)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — AWS CREDENTIALS
# ─────────────────────────────────────────────────────────────────────────────
section "Step 2 — AWS Credentials"

CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null) \
  || fail "AWS credentials not configured. Run: aws configure  (or set AWS_PROFILE)"
ok "Authenticated as: ${CALLER_ARN}"

ACTUAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
if [[ "$ACTUAL_ACCOUNT" != "$AWS_ACCOUNT_ID" ]]; then
  warn "Active AWS account (${ACTUAL_ACCOUNT}) differs from configured AWS_ACCOUNT_ID (${AWS_ACCOUNT_ID})"
  warn "ECR images will be pushed to account ${ACTUAL_ACCOUNT}"
  AWS_ACCOUNT_ID="$ACTUAL_ACCOUNT"
  ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — EKS CLUSTER
# ─────────────────────────────────────────────────────────────────────────────
section "Step 3 — EKS Cluster"

if [[ "$SKIP_CLUSTER" == "false" ]]; then
  if aws eks describe-cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" &>/dev/null; then
    ok "Cluster '${EKS_CLUSTER}' already exists — skipping creation"
  else
    log "Cluster '${EKS_CLUSTER}' not found — creating via eksctl (~15 min)..."
    # eks-cluster.yaml has name: blog-cluster; override with --name flag
    eksctl create cluster \
      --name "$EKS_CLUSTER" \
      --region "$AWS_REGION" \
      --node-type t3.medium \
      --nodes 3 \
      --nodes-min 3 \
      --nodes-max 3 \
      --node-volume-size 20 \
      --managed \
      --asg-access \
      --alb-ingress-access \
      --full-ecr-access
    ok "Cluster '${EKS_CLUSTER}' created"
  fi
else
  log "Skipping cluster creation (--skip-cluster)"
fi

log "Updating kubeconfig for cluster: ${EKS_CLUSTER}"
aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION"
ok "kubeconfig updated"

# Quick connectivity check
kubectl cluster-info --request-timeout=10s &>/dev/null || fail "Cannot reach Kubernetes API — check kubeconfig"
ok "Kubernetes API reachable"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — ECR LOGIN & REPOSITORY SETUP
# ─────────────────────────────────────────────────────────────────────────────
section "Step 4 — ECR Login & Repository Setup"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
ok "Docker authenticated with ECR (${ECR_REGISTRY})"

ECR_REPOS=(blog-auth-service blog-post-service blog-comment-service blog-frontend)

for repo in "${ECR_REPOS[@]}"; do
  if aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" &>/dev/null; then
    ok "ECR repo exists:  ${repo}"
  else
    log "Creating ECR repo: ${repo}"
    aws ecr create-repository \
      --repository-name  "$repo" \
      --region           "$AWS_REGION" \
      --image-scanning-configuration  scanOnPush=true \
      --encryption-configuration      encryptionType=AES256 \
      > /dev/null
    ok "Created ECR repo: ${repo}"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — BUILD & PUSH DOCKER IMAGES
# ─────────────────────────────────────────────────────────────────────────────
section "Step 5 — Docker Build & Push  (tag: ${IMAGE_TAG})"

if [[ "$SKIP_BUILD" == "false" ]]; then

  build_push() {
    local repo_name="$1"
    local build_context="${SCRIPT_DIR}/$2"
    local tagged_image="${ECR_REGISTRY}/${repo_name}:${IMAGE_TAG}"
    local latest_image="${ECR_REGISTRY}/${repo_name}:latest"

    log "Building  ${repo_name} ..."
    docker build --platform linux/amd64 -t "$tagged_image" "$build_context"
    docker tag "$tagged_image" "$latest_image"

    log "Pushing   ${repo_name}:${IMAGE_TAG} ..."
    docker push "$tagged_image"
    docker push "$latest_image"
    ok "Pushed    ${repo_name}:${IMAGE_TAG}"
  }

  build_push "blog-auth-service"    "services/auth-service"
  build_push "blog-post-service"    "services/post-service"
  build_push "blog-comment-service" "services/comment-service"
  build_push "blog-frontend"        "frontend"

else
  log "Skipping Docker build (--skip-build)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — KUBERNETES NAMESPACE & SECRETS
# ─────────────────────────────────────────────────────────────────────────────
section "Step 6 — Namespace & Secrets"

kubectl apply -f "${SCRIPT_DIR}/k8s/namespace.yaml"
ok "Namespace '${NAMESPACE}' applied"

kubectl apply -f "${SCRIPT_DIR}/k8s/secrets.yaml"
ok "Secret 'blog-secrets' applied"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — NGINX INGRESS CONTROLLER + CERT-MANAGER
# ─────────────────────────────────────────────────────────────────────────────
section "Step 7 — Infrastructure  (NGINX Ingress + cert-manager)"

if [[ "$SKIP_INFRA" == "false" ]]; then

  # ── NGINX Ingress Controller ──────────────────────────────────────────────
  if kubectl get ingressclass nginx &>/dev/null 2>&1; then
    ok "NGINX IngressClass already present — skipping"
  else
    log "Installing NGINX Ingress Controller (AWS NLB variant)..."
    kubectl apply -f \
      https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/aws/deploy.yaml

    log "Waiting for NGINX Ingress Controller pod to be Ready (up to 3 min)..."
    kubectl wait --namespace ingress-nginx \
      --for=condition=ready pod \
      --selector=app.kubernetes.io/component=controller \
      --timeout=180s
    ok "NGINX Ingress Controller is Ready"
  fi

  # ── cert-manager ─────────────────────────────────────────────────────────
  if kubectl get namespace cert-manager &>/dev/null 2>&1; then
    ok "cert-manager namespace exists — skipping install"
  else
    log "Installing cert-manager v1.14.4..."
    kubectl apply -f \
      https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml

    log "Waiting for cert-manager pods to be Ready (up to 3 min)..."
    kubectl wait --namespace cert-manager \
      --for=condition=ready pod \
      --selector=app.kubernetes.io/instance=cert-manager \
      --timeout=180s
    ok "cert-manager is Ready"
  fi

  # ── ClusterIssuer (Let's Encrypt prod) ───────────────────────────────────
  log "Applying ClusterIssuer (letsencrypt-prod)..."
  kubectl apply -f "${SCRIPT_DIR}/k8s/cluster-issuer.yaml"
  ok "ClusterIssuer applied"

else
  log "Skipping infra install (--skip-infra)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# HELPER: apply a deployment YAML with the correct image tag substituted
# ─────────────────────────────────────────────────────────────────────────────
apply_deployment() {
  local file="$1"
  # Replace the account ID as well in case the file still has the old one
  sed \
    -e "s|${AWS_ACCOUNT_ID}\.dkr\.ecr\.[a-z0-9-]*\.amazonaws\.com/\([^:]*\):latest|${ECR_REGISTRY}/\1:${IMAGE_TAG}|g" \
    -e "s|508262720940\.dkr\.ecr\.[a-z0-9-]*\.amazonaws\.com/\([^:]*\):latest|${ECR_REGISTRY}/\1:${IMAGE_TAG}|g" \
    "$file" | kubectl apply -f -
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — DEPLOY SERVICES
# ─────────────────────────────────────────────────────────────────────────────
section "Step 8 — Deploying Services  (tag: ${IMAGE_TAG})"

# ── Auth Service ──────────────────────────────────────────────────────────────
log "auth-service ..."
apply_deployment "${SCRIPT_DIR}/k8s/auth-service/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/auth-service/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/auth-service/hpa.yaml"
ok "auth-service manifests applied"

# ── Post Service ──────────────────────────────────────────────────────────────
log "post-service ..."
apply_deployment "${SCRIPT_DIR}/k8s/post-service/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/post-service/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/post-service/hpa.yaml"
ok "post-service manifests applied"

# ── Comment Service ───────────────────────────────────────────────────────────
log "comment-service ..."
apply_deployment "${SCRIPT_DIR}/k8s/comment-service/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/comment-service/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/comment-service/hpa.yaml"
ok "comment-service manifests applied"

# ── Frontend ──────────────────────────────────────────────────────────────────
log "frontend ..."
apply_deployment "${SCRIPT_DIR}/frontend/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/frontend/service.yaml"
ok "frontend manifests applied"

# ── Ingress ───────────────────────────────────────────────────────────────────
log "ingress ..."
kubectl apply -f "${SCRIPT_DIR}/k8s/ingress.yaml"
ok "Ingress applied"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — WAIT FOR ROLLOUTS
# ─────────────────────────────────────────────────────────────────────────────
section "Step 9 — Waiting for Rollouts (timeout: 3 min each)"

DEPLOYMENTS=(auth-service post-service comment-service frontend)
for dep in "${DEPLOYMENTS[@]}"; do
  log "Rollout: ${dep} ..."
  kubectl rollout status deployment/"${dep}" \
    --namespace "$NAMESPACE" \
    --timeout=180s
  ok "${dep} rollout complete"
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10 — STATUS SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
section "Step 10 — Status Summary"

echo ""
echo -e "${BOLD}Pods:${NC}"
kubectl get pods -n "$NAMESPACE" -o wide

echo ""
echo -e "${BOLD}Services:${NC}"
kubectl get services -n "$NAMESPACE"

echo ""
echo -e "${BOLD}Ingress:${NC}"
kubectl get ingress -n "$NAMESPACE"

echo ""
echo -e "${BOLD}HPA:${NC}"
kubectl get hpa -n "$NAMESPACE"

echo ""
LB_HOST=$(kubectl get svc ingress-nginx-controller \
  --namespace ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")

echo -e "${GREEN}${BOLD}"
echo "┌─────────────────────────────────────────────────────────┐"
echo "│           MySocialSpace — Deploy Complete!              │"
echo "├─────────────────────────────────────────────────────────┤"
printf "│  Image Tag   : %-42s│\n" "${IMAGE_TAG}"
printf "│  Cluster     : %-42s│\n" "${EKS_CLUSTER}"
printf "│  Namespace   : %-42s│\n" "${NAMESPACE}"
printf "│  LB Hostname : %-42s│\n" "${LB_HOST}"
printf "│  App URL     : %-42s│\n" "https://amazontechspace.com"
echo "└─────────────────────────────────────────────────────────┘"
echo -e "${NC}"

if [[ "$LB_HOST" != "<pending>" ]]; then
  echo -e "  ${YELLOW}Next step:${NC} Create a DNS CNAME record:"
  echo -e "    amazontechspace.com  →  ${LB_HOST}"
  echo -e "    www.amazontechspace.com  →  ${LB_HOST}"
else
  echo -e "  ${YELLOW}Note:${NC} Load Balancer is still provisioning."
  echo -e "  Run this once it's ready:"
  echo -e "    kubectl get svc ingress-nginx-controller -n ingress-nginx"
fi

echo ""
