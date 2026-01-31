#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:=eu-west-1}"
: "${CLUSTER_NAME:=eks-workshop-foundations}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Using:"
echo "  AWS_REGION=$AWS_REGION"
echo "  CLUSTER_NAME=$CLUSTER_NAME"
echo "  ACCOUNT_ID=$ACCOUNT_ID"

aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null

# Ensure namespace exists
kubectl apply -f 01-addons/karpenter-namespace.yaml >/dev/null

echo ""
echo "==> Discover cluster/VPC resources"
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.resourcesVpcConfig.vpcId" --output text)"
CLUSTER_SG="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)"
OIDC_ISSUER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.identity.oidc.issuer" --output text)"
OIDC_PROVIDER="${OIDC_ISSUER#https://}"
echo "  VPC_ID=$VPC_ID"
echo "  CLUSTER_SG=$CLUSTER_SG"
echo "  OIDC_PROVIDER=$OIDC_PROVIDER"

echo ""
echo "==> Tag subnets + security groups for discovery (best effort)"
SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" --filters Name=vpc-id,Values="$VPC_ID" --query "Subnets[].SubnetId" --output text)
for s in $SUBNETS; do
  aws ec2 create-tags --region "$AWS_REGION" --resources "$s" --tags Key=karpenter.sh/discovery,Value="$CLUSTER_NAME" >/dev/null || true
done
aws ec2 create-tags --region "$AWS_REGION" --resources "$CLUSTER_SG" --tags Key=karpenter.sh/discovery,Value="$CLUSTER_NAME" >/dev/null || true

echo ""
echo "==> Create SQS interruption queue"
QUEUE_NAME="karpenter-${CLUSTER_NAME}"
QUEUE_URL="$(aws sqs create-queue --region "$AWS_REGION" --queue-name "$QUEUE_NAME" --query 'QueueUrl' --output text 2>/dev/null || true)"
if [[ -z "$QUEUE_URL" || "$QUEUE_URL" == "None" ]]; then
  QUEUE_URL="$(aws sqs get-queue-url --region "$AWS_REGION" --queue-name "$QUEUE_NAME" --query 'QueueUrl' --output text)"
fi
QUEUE_ARN="$(aws sqs get-queue-attributes --region "$AWS_REGION" --queue-url "$QUEUE_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"
echo "  QUEUE_URL=$QUEUE_URL"
echo "  QUEUE_ARN=$QUEUE_ARN"

echo ""
echo "==> Allow EventBridge to send messages to the queue"
POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowEventBridgeSendMessage",
      "Effect": "Allow",
      "Principal": {"Service": "events.amazonaws.com"},
      "Action": "sqs:SendMessage",
      "Resource": "${QUEUE_ARN}"
    }
  ]
}
EOF
)
aws sqs set-queue-attributes --region "$AWS_REGION" --queue-url "$QUEUE_URL" --attributes Policy="$POLICY" >/dev/null

echo ""
echo "==> Create EventBridge rules -> SQS (best effort idempotent)"
# Spot interruption warning
aws events put-rule --region "$AWS_REGION" --name "karpenter-spot-interruption-${CLUSTER_NAME}" \
  --event-pattern '{"source":["aws.ec2"],"detail-type":["EC2 Spot Instance Interruption Warning"]}' >/dev/null
aws events put-targets --region "$AWS_REGION" --rule "karpenter-spot-interruption-${CLUSTER_NAME}" \
  --targets "Id"="1","Arn"="${QUEUE_ARN}" >/dev/null

# Rebalance recommendation
aws events put-rule --region "$AWS_REGION" --name "karpenter-rebalance-${CLUSTER_NAME}" \
  --event-pattern '{"source":["aws.ec2"],"detail-type":["EC2 Instance Rebalance Recommendation"]}' >/dev/null
aws events put-targets --region "$AWS_REGION" --rule "karpenter-rebalance-${CLUSTER_NAME}" \
  --targets "Id"="1","Arn"="${QUEUE_ARN}" >/dev/null

# Scheduled change (maintenance/retirement)
aws events put-rule --region "$AWS_REGION" --name "karpenter-scheduled-change-${CLUSTER_NAME}" \
  --event-pattern '{"source":["aws.health"],"detail-type":["AWS Health Event"]}' >/dev/null 2>&1 || true
# (AWS Health events may require permissions and are optional for the lab.)

echo ""
echo "==> Create IAM policy for Karpenter Controller (lab-friendly)"
POLICY_NAME="KarpenterControllerPolicy-${CLUSTER_NAME}"
aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document file://scripts/iam/karpenter-controller-policy.json \
  >/dev/null 2>&1 || true
CTRL_POLICY_ARN="$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" --output text)"
echo "  CTRL_POLICY_ARN=$CTRL_POLICY_ARN"

echo ""
echo "==> Create IAM role for Karpenter nodes (instance role) + instance profile"
NODE_ROLE_NAME="KarpenterNodeRole-${CLUSTER_NAME}"
TRUST_NODE=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)
aws iam create-role --role-name "$NODE_ROLE_NAME" --assume-role-policy-document "$TRUST_NODE" >/dev/null 2>&1 || true

# Attach commonly required managed policies for EKS worker nodes
for pol in \
  arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy \
  arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
  arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
  arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
do
  aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" --policy-arn "$pol" >/dev/null 2>&1 || true
done

PROFILE_NAME="KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1 || true
aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$NODE_ROLE_NAME" >/dev/null 2>&1 || true

echo "  NODE_ROLE_NAME=$NODE_ROLE_NAME"
echo "  INSTANCE_PROFILE=$PROFILE_NAME"

echo ""
echo "==> Create IRSA service account for Karpenter controller (eksctl)"
# Karpenter SA is typically named 'karpenter'
eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace karpenter \
  --name karpenter \
  --attach-policy-arn "$CTRL_POLICY_ARN" \
  --override-existing-serviceaccounts \
  --approve

echo ""
echo "==> Install/Upgrade Karpenter (Helm)"
helm repo add karpenter https://charts.karpenter.sh >/dev/null 2>&1 || true
helm repo update karpenter >/dev/null 2>&1 || true

helm upgrade --install karpenter karpenter/karpenter \
  -n karpenter \
  --set settings.clusterName="$CLUSTER_NAME" \
  --set settings.interruptionQueue="$QUEUE_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=karpenter \
  --set settings.aws.defaultInstanceProfile="$PROFILE_NAME" \
  --set settings.aws.clusterEndpoint="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.endpoint" --output text)" \
  --set settings.aws.clusterCABundle="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.certificateAuthority.data" --output text)"

echo ""
echo "==> Patch Karpenter manifests placeholders for this cluster (best effort)"
# Update EC2NodeClass placeholders
sed -i.bak "s/<KarpenterNodeRoleName>/${NODE_ROLE_NAME}/g" 08-autoscaling/karpenter/ec2nodeclass.yaml || true
sed -i.bak "s/<CLUSTER_NAME>/${CLUSTER_NAME}/g" 08-autoscaling/karpenter/ec2nodeclass.yaml || true

echo ""
echo "==> Apply Karpenter NodePool + EC2NodeClass + trigger workload"
kubectl apply -f 08-autoscaling/karpenter/ec2nodeclass.yaml
kubectl apply -f 08-autoscaling/karpenter/nodepool.yaml
kubectl apply -f 08-autoscaling/karpenter/workload-to-trigger.yaml

echo ""
echo "==> Observe"
echo "  kubectl -n karpenter get pods"
echo "  kubectl get nodeclaims || true"
echo "  kubectl get nodes"
