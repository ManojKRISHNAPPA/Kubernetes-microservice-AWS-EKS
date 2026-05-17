#!/usr/bin/env bash
set -euo pipefail

CLUSTER="quantam-cluster"
REGION="ap-south-1"
NAMESPACE="blog"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Updating kubeconfig"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

echo "==> Namespace"
kubectl apply -f "$DIR/k8s/namespace.yaml"

echo "==> Secrets"
kubectl apply -f "$DIR/k8s/secrets.yaml"

echo "==> NGINX Ingress Controller"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/aws/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo "==> cert-manager"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=180s

echo "==> ClusterIssuer"
kubectl apply -f "$DIR/k8s/cluster-issuer.yaml"

echo "==> auth-service"
kubectl apply -f "$DIR/k8s/auth-service/deployment.yaml"
kubectl apply -f "$DIR/k8s/auth-service/service.yaml"
kubectl apply -f "$DIR/k8s/auth-service/hpa.yaml"

echo "==> post-service"
kubectl apply -f "$DIR/k8s/post-service/deployment.yaml"
kubectl apply -f "$DIR/k8s/post-service/service.yaml"
kubectl apply -f "$DIR/k8s/post-service/hpa.yaml"

echo "==> comment-service"
kubectl apply -f "$DIR/k8s/comment-service/deployment.yaml"
kubectl apply -f "$DIR/k8s/comment-service/service.yaml"
kubectl apply -f "$DIR/k8s/comment-service/hpa.yaml"

echo "==> frontend"
kubectl apply -f "$DIR/frontend/deployment.yaml"
kubectl apply -f "$DIR/frontend/service.yaml"

echo "==> Ingress"
kubectl apply -f "$DIR/k8s/ingress.yaml"

echo ""
echo "==> Waiting for rollouts"
for dep in auth-service post-service comment-service frontend; do
  kubectl rollout status deployment/"$dep" -n "$NAMESPACE" --timeout=180s
done

echo ""
echo "==> All pods"
kubectl get pods -n "$NAMESPACE"

echo ""
echo "==> Ingress"
kubectl get ingress -n "$NAMESPACE"
