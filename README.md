# EKS Lab (kubectl-first)

A hands-on lab repo for EKS that focuses on **apply-and-observe**:
- YAML manifests are pre-written so you can run `kubectl apply -f <path>`
- A few steps require AWS-side actions (IAM, EKS associations, Karpenter infra). These are called out explicitly.

## Assumptions
- EKS cluster already exists and your kubeconfig works
- `kubectl` and `aws` CLI installed and configured
- Amazon VPC CNI is used (default on EKS)

---

## 0) Set variables

```bash
export AWS_REGION="eu-west-1"
export CLUSTER_NAME="eks-workshop-foundations"
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
```

Sanity checks:
```bash
kubectl get nodes
aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.version" --output text
```

---

## 1) Namespaces

```bash
kubectl apply -f 00-prereqs/namespaces.yaml
kubectl get ns | egrep 'lab-|ingress-nginx'
```

---

## 2) Add-ons (kubectl-first)

### 2.1 Metrics Server (for HPA)
```bash
kubectl apply -f 01-addons/metrics-server.yaml
kubectl -n kube-system rollout status deploy/metrics-server
kubectl top nodes || true
kubectl top pods -n lab-app || true
```

### 2.2 Gateway API CRDs
```bash
kubectl apply -f 01-addons/gateway-api-crds.yaml
kubectl get crd | grep gateway.networking.k8s.io
```

### 2.3 VPA (Vertical Pod Autoscaler)
```bash
kubectl apply -f 01-addons/vpa-install.yaml
kubectl -n kube-system get deploy | egrep 'vpa-(recommender|updater|admission-controller)'
```

### 2.4 EBS CSI Driver (recommended as EKS add-on)
If you already installed it, skip. Otherwise:

```bash
aws eks create-addon \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --addon-name aws-ebs-csi-driver
```

Verify:
```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-ebs-csi-driver
```

### 2.5 AWS Load Balancer Controller (ALB/NLB + Gateway API support)
This typically requires an IAM role and installation (commonly Helm). Follow AWS docs:
- https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html

> Once installed, the Networking steps (ALB Ingress, Gateway) will work.

### 2.6 ExternalDNS (Route53)
ExternalDNS also needs IAM + installation. This repo includes manifests, but you must:
1) Have a Route53 hosted zone
2) Provide an IAM role/policy
3) Decide if you want IRSA or Pod Identity (recommended: Pod Identity)

See section **10) ExternalDNS**.

---

## 3) RBAC (least privilege examples)

```bash
kubectl apply -f 02-rbac/readonly-role.yaml
kubectl apply -f 02-rbac/namespace-admin-role.yaml
```

---

## 4) Deploy apps (config + API + frontend + jobs)

Config:
```bash
kubectl apply -f 03-apps/00-config/
```

API:
```bash
kubectl apply -f 03-apps/01-api/
kubectl -n lab-app get deploy,svc
```

Frontend:
```bash
kubectl apply -f 03-apps/02-frontend/
kubectl -n lab-app get deploy,svc
```

Jobs:
```bash
kubectl apply -f 03-apps/03-jobs/
kubectl -n lab-jobs get jobs,cronjobs
```

---

## 5) Scheduling patterns (EKS-friendly)

Apply recommended scheduling patterns:
- Spread frontend across AZs (topology spread)
- Prefer API pods on different nodes (anti-affinity)
- Example nodeSelector for nodegroup pinning

```bash
kubectl apply -f 04-scheduling/zone-spread-frontend.yaml
kubectl apply -f 04-scheduling/pod-antiaffinity-api.yaml
kubectl apply -f 04-scheduling/node-selector-example.yaml
kubectl -n lab-app get pods -o wide
```

---

## 6) Storage with EBS CSI (gp3 + StatefulSet)

```bash
kubectl apply -f 05-storage-ebs/storageclass-gp3.yaml
kubectl apply -f 05-storage-ebs/statefulset.yaml
kubectl apply -f 05-storage-ebs/service.yaml
kubectl -n lab-storage get pvc,pv,sts,pods
```

---

## 7) Networking

### 7.1 ALB Ingress (requires AWS Load Balancer Controller)
```bash
kubectl apply -f 06-networking/01-alb-ingress/ingress.yaml
kubectl -n lab-app get ingress frontend-alb -o wide
```

### 7.2 NLB Service
```bash
kubectl apply -f 06-networking/02-nlb-service/service-nlb.yaml
kubectl -n lab-app get svc frontend-nlb -o wide
```

### 7.3 NGINX Ingress Controller + Ingress
```bash
kubectl apply -f 06-networking/03-nginx-ingress/nginx-ingress-controller.yaml
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller

kubectl apply -f 06-networking/03-nginx-ingress/ingress.yaml
kubectl -n lab-app get ingress frontend-nginx -o wide
```

### 7.4 Gateway API (requires Gateway CRDs + AWS LBC Gateway controller)
```bash
kubectl apply -f 06-networking/04-gateway-api/gatewayclass.yaml
kubectl apply -f 06-networking/04-gateway-api/gateway.yaml
kubectl apply -f 06-networking/04-gateway-api/httproute.yaml
kubectl -n lab-gw get gateway,httproute
```

---

## 8) Security

### 8.1 NetworkPolicies (default deny + allow rules)
```bash
kubectl apply -f 07-security/01-networkpolicies/default-deny.yaml
kubectl apply -f 07-security/01-networkpolicies/allow-dns-egress.yaml
kubectl apply -f 07-security/01-networkpolicies/allow-frontend-to-api.yaml
```

> IMPORTANT: NetworkPolicies require an enforcing implementation:
> - Amazon VPC CNI NetworkPolicy feature OR Calico.

### 8.2 Pod Identity (EKS Pod Identity)
Apply the ServiceAccount + workload:
```bash
kubectl apply -f 07-security/02-pod-identity/serviceaccount.yaml
kubectl apply -f 07-security/02-pod-identity/s3-reader-deployment.yaml
```

Now associate an IAM role to the ServiceAccount (AWS-side):
```bash
aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace lab-iam \
  --service-account s3-reader \
  --role-arn arn:aws:iam::$ACCOUNT_ID:role/<ROLE_NAME>
```

Verify:
```bash
kubectl -n lab-iam logs deploy/s3-reader --tail=100
```

### 8.3 Security Groups for Pods (SGP)
Edit the SG ID in the manifest first, then:
```bash
kubectl apply -f 07-security/03-sg-for-pods/securitygrouppolicy.yaml
kubectl -n lab-iam get securitygrouppolicy
```

---

## 9) Autoscaling

### 9.1 HPA (frontend)
```bash
kubectl apply -f 08-autoscaling/hpa-frontend.yaml
kubectl -n lab-app get hpa
```

### 9.2 VPA (api) - recommendation only
```bash
kubectl apply -f 08-autoscaling/vpa-api.yaml
kubectl -n lab-app get vpa
kubectl -n lab-app describe vpa api | sed -n '1,120p'
```

### 9.3 Load generator (push CPU so HPA + Karpenter can kick in)
This will generate CPU load against the frontend service inside the cluster.

```bash
kubectl apply -f 08-autoscaling/loadgen/
kubectl -n lab-jobs get pods -l app=loadgen -w
```

Watch HPA:
```bash
kubectl -n lab-app get hpa -w
```

### 9.4 Karpenter (node autoscaling)
Karpenter requires AWS-side infra (IAM, node role, interruption queue, discovery tags) and controller installation.

Once installed, apply:
```bash
kubectl apply -f 08-autoscaling/karpenter/ec2nodeclass.yaml
kubectl apply -f 08-autoscaling/karpenter/nodepool.yaml
kubectl apply -f 08-autoscaling/karpenter/workload-to-trigger.yaml
```

Observe nodes being created:
```bash
kubectl get nodeclaims || true
kubectl get nodes
```

---

## 10) ExternalDNS (Route53)
This repo includes a lab-ready ExternalDNS manifest, but you must:
- Pick a hosted zone and its domain (e.g. `example.com`)
- Provide IAM permissions via Pod Identity association (recommended) or IRSA

### 10.1 Apply manifests (won't manage DNS until IAM is connected)
Edit:
- `10-externaldns/externaldns.yaml` (domainFilter, zoneType, txtOwnerId)
Then:
```bash
kubectl apply -f 10-externaldns/
kubectl -n external-dns get deploy,pods
```

### 10.2 Grant IAM permissions (Pod Identity)
Create a role with Route53 change permissions, then associate it:
```bash
aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace external-dns \
  --service-account external-dns \
  --role-arn arn:aws:iam::$ACCOUNT_ID:role/<EXTERNALDNS_ROLE_NAME>
```

Verify logs:
```bash
kubectl -n external-dns logs deploy/external-dns --tail=200
```

### 10.3 Test (create a Service/Ingress with an external-dns annotation)
Apply:
```bash
kubectl apply -f 10-externaldns/test-record/
```
Check logs again and confirm records in Route53.

---

## 99) Cleanup

```bash
bash 99-cleanup/delete-all.sh
```

> Cleanup only deletes Kubernetes objects. AWS resources created by controllers (ALB/NLB/records) should disappear after.
> If you created IAM roles/policies or EKS add-ons, remove them separately.


## Notes for your eksctl config
- Your VPC CNI add-on config enables **Pod ENIs**, **Security Groups for Pods**, and **NetworkPolicy enforcement**. This is required for the NetworkPolicy + SGP parts of the lab.
- Your cluster endpoints are both public+private; if you ever flip to private-only, run kubectl from inside the VPC (VPN/bastion/SSM).


### Why the interruption SQS queue?
Karpenter uses an SQS queue as a reliable bridge from AWS interruption/maintenance events (via EventBridge) to Kubernetes node draining. This lets Karpenter cordon/drain nodes proactively (especially for Spot interruptions) instead of pods being killed abruptly.
