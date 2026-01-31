# Karpenter (IRSA) in this lab

This repo includes a mostly automated Karpenter setup script:

```bash
bash scripts/karpenter/aws-setup-irsa.sh
```

It will:
- Tag subnets/security groups for discovery (`karpenter.sh/discovery=$CLUSTER_NAME`)
- Create an SQS interruption queue
- Create EventBridge rules to send interruption/rebalance events to SQS
- Create an IAM policy for the Karpenter controller
- Create the Karpenter node IAM role + instance profile
- Create the IRSA service account using eksctl
- Install Karpenter with Helm
- Apply EC2NodeClass + NodePool + a trigger workload

Production note: IAM in this lab is intentionally broader for learning. Tighten permissions before using in production.
