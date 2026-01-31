#!/usr/bin/env bash
set -euo pipefail

# Bootstrap AWS-side prerequisites for this lab.
# Requires: aws, kubectl, eksctl, helm

: "${AWS_REGION:=eu-west-1}"
: "${CLUSTER_NAME:=eks-workshop-foundations}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Using:"
echo "  AWS_REGION=$AWS_REGION"
echo "  CLUSTER_NAME=$CLUSTER_NAME"
echo "  ACCOUNT_ID=$ACCOUNT_ID"

echo ""
echo "==> Update kubeconfig"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null

echo ""
echo "==> Install/ensure EKS add-ons"
# Pod Identity agent (required for EKS Pod Identity associations)
aws eks create-addon --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --addon-name eks-pod-identity-agent >/dev/null 2>&1 || true
# EBS CSI
aws eks create-addon --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --addon-name aws-ebs-csi-driver >/dev/null 2>&1 || true

echo ""
echo "==> Create namespaces (idempotent)"
kubectl apply -f 00-prereqs/namespaces.yaml >/dev/null

echo ""
echo "==> Install Metrics Server + Gateway API CRDs + VPA (kubectl)"
kubectl apply -f 01-addons/metrics-server.yaml >/dev/null
kubectl apply -f 01-addons/gateway-api-crds.yaml >/dev/null
kubectl apply -f 01-addons/vpa-install.yaml >/dev/null
kubectl apply -f 01-addons/karpenter-namespace.yaml >/dev/null

echo ""
echo "==> Install AWS Load Balancer Controller (Helm + IRSA via eksctl)"
# Official AWS docs: https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html
# The IAM policy JSON is stored in scripts/iam/aws-load-balancer-controller-policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://scripts/iam/aws-load-balancer-controller-policy.json \
  >/dev/null 2>&1 || true

LBC_POLICY_ARN="$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn | [0]" --output text)"
echo "  LBC_POLICY_ARN=$LBC_POLICY_ARN"

eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn "$LBC_POLICY_ARN" \
  --override-existing-serviceaccounts \
  --approve

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null 2>&1 || true

# Discover VPC ID (needed by LBC)
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.resourcesVpcConfig.vpcId" --output text)"
echo "  VPC_ID=$VPC_ID"

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID"

echo ""
echo "==> Karpenter (IRSA) guided install"
echo "Run: bash scripts/karpenter/aws-setup-irsa.sh
This will create SQS interruption queue + EventBridge rules, create IAM roles/policies, install Karpenter via Helm, and apply NodePool/EC2NodeClass/workload.

Note: IAM policies here are lab-friendly (broad). Tighten for production."
echo "We generate helper IAM policies + a minimal install, but you still must:"
echo "  - create an SQS interruption queue"
echo "  - create a KarpenterControllerRole and KarpenterNodeRole"
echo "  - tag subnets and security groups with karpenter.sh/discovery=$CLUSTER_NAME"
echo ""
echo "See scripts/karpenter/README.md for guided commands."

echo ""
echo "==> Done. Next:"
echo "  kubectl apply -f 03-apps/00-config/"
echo "  kubectl apply -f 03-apps/01-api/"
echo "  kubectl apply -f 03-apps/02-frontend/"
echo "  kubectl apply -f 06-networking/01-alb-ingress/"
