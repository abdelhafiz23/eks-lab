#!/usr/bin/env bash
set -euo pipefail

kubectl delete -f 10-externaldns/ --ignore-not-found=true
kubectl delete -f 08-autoscaling/ --ignore-not-found=true
kubectl delete -f 07-security/ --ignore-not-found=true
kubectl delete -f 06-networking/ --ignore-not-found=true
kubectl delete -f 05-storage-ebs/ --ignore-not-found=true
kubectl delete -f 04-scheduling/ --ignore-not-found=true
kubectl delete -f 03-apps/ --ignore-not-found=true
kubectl delete -f 02-rbac/ --ignore-not-found=true
kubectl delete -f 01-addons/ --ignore-not-found=true
kubectl delete -f 00-prereqs/namespaces.yaml --ignore-not-found=true
