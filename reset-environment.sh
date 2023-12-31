#!/bin/bash

module=$1

# probably persistent
EKS_CLUSTER_NAME=eks-workshop
EKS_DEFAULT_MNG_DESIRED=2
EKS_DEFAULT_MNG_MAX=6
EKS_DEFAULT_MNG_MIN=2


# probably needs to be some kinda aws eks command to discover
EKS_CLUSTER_SECURITY_GROUP_ID=sg-04fa596933ab0520f
EKS_DEFAULT_MNG_NAME=managed-ondemand-20230707143113604900000024
EKS_TAINTED_MNG_NAME=managed-ondemand-tainted-20230707143113629600000026

absolute_path="$PWD/manifests"

if [ ! -z "$module" ]; then
  absolute_path="$PWD/modules/$module/base"
fi

set -Eeuo pipefail

if [[ ! -d "$absolute_path" ]]; then
  echo "Error: Manifest directory not found to reset"
  exit 1
fi

echo "Resetting the environment, please wait"

kubectl delete app -A --all > /dev/null

kubectl delete pod -n other load-generator --ignore-not-found > /dev/null

kubectl apply -k "$absolute_path" --prune --all \
  --prune-whitelist=autoscaling/v1/HorizontalPodAutoscaler \
  --prune-whitelist=core/v1/Service \
  --prune-whitelist=core/v1/ConfigMap \
  --prune-whitelist=apps/v1/Deployment \
  --prune-whitelist=apps/v1/StatefulSet \
  --prune-whitelist=core/v1/ServiceAccount \
  --prune-whitelist=core/v1/Secret \
  --prune-whitelist=core/v1/PersistentVolumeClaim \
  --prune-whitelist=karpenter.sh/v1alpha5/Provisioner \
  --prune-whitelist=scheduling.k8s.io/v1/PriorityClass \
  --prune-whitelist=opentelemetry.io/v1alpha1/OpenTelemetryCollector \
  --prune-whitelist=crd.k8s.amazonaws.com/v1alpha1/ENIConfig \
  --prune-whitelist=vpcresources.k8s.aws/v1beta1/SecurityGroupPolicy \
  --prune-whitelist=database.aws.crossplane.io/v1beta1/DBSubnetGroup \
  --prune-whitelist=rds.aws.crossplane.io/v1alpha1/DBInstance \
  --prune-whitelist=ec2.aws.crossplane.io/v1beta1/SecurityGroup \
  --prune-whitelist=apiextensions.crossplane.io/v1/Composition \
  --prune-whitelist=apiextensions.crossplane.io/v1/CompositeResourceDefinition \
  --prune-whitelist=services.k8s.aws/v1alpha1/FieldExport \
  --prune-whitelist=rds.services.k8s.aws/v1alpha1/DBSubnetGroup \
  --prune-whitelist=rds.services.k8s.aws/v1alpha1/DBInstance \
  --prune-whitelist=ec2.services.k8s.aws/v1alpha1/SecurityGroup \
  --prune-whitelist=argoproj.io/v1alpha1/Application \
  --prune-whitelist=networking.k8s.io/v1/Ingress > /dev/null

crossplane_crd=$(kubectl get crds | grep relationaldatabases.awsblueprints.io || [[ $? == 1 ]])

if [ ! -z "$crossplane_crd" ]; then
  kubectl delete relationaldatabases.awsblueprints.io -A --all > /dev/null
fi

echo "Waiting for application to become ready..."

sleep 10

kubectl wait --for=condition=available --timeout=240s deployments -l app.kubernetes.io/created-by=eks-workshop -A > /dev/null
kubectl wait --for=condition=Ready --timeout=240s pods -l app.kubernetes.io/created-by=eks-workshop -A > /dev/null

kubectl scale --replicas=0 -n kube-system deployment/cluster-autoscaler-aws-cluster-autoscaler > /dev/null

aws eks update-nodegroup-config --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$EKS_TAINTED_MNG_NAME" \
    --scaling-config desiredSize=0,minSize=0,maxSize=1 > /dev/null

expected_size_config="$EKS_DEFAULT_MNG_MIN $EKS_DEFAULT_MNG_MAX $EKS_DEFAULT_MNG_DESIRED"

mng_size_config=$(aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$EKS_DEFAULT_MNG_NAME" | jq -r '.nodegroup.scalingConfig | "\(.minSize) \(.maxSize) \(.desiredSize)"')

if [[ "$mng_size_config" != "$expected_size_config" ]]; then
  echo "Setting EKS Node Group back to initial sizing..."

  aws eks update-nodegroup-config --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$EKS_DEFAULT_MNG_NAME" \
    --scaling-config desiredSize="$EKS_DEFAULT_MNG_DESIRED,minSize=$EKS_DEFAULT_MNG_MIN,maxSize=$EKS_DEFAULT_MNG_MAX" > /dev/null
  aws eks wait nodegroup-active --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$EKS_DEFAULT_MNG_NAME"

  sleep 10
fi

asg_size_config=$(aws autoscaling describe-auto-scaling-groups --filters "Name=tag:eks:nodegroup-name,Values=$EKS_DEFAULT_MNG_NAME" | jq -r '.AutoScalingGroups[0] | "\(.MinSize) \(.MaxSize) \(.DesiredCapacity)"')

if [[ "$asg_size_config" != "$expected_size_config" ]]; then
  echo "Setting ASG back to initial sizing..."

  export ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --filters "Name=tag:eks:nodegroup-name,Values=$EKS_DEFAULT_MNG_NAME" --query "AutoScalingGroups[0].AutoScalingGroupName" --output text)
  aws autoscaling update-auto-scaling-group \
      --auto-scaling-group-name "$ASG_NAME" \
      --min-size "$EKS_DEFAULT_MNG_MIN" \
      --max-size "$EKS_DEFAULT_MNG_MAX" \
      --desired-capacity "$EKS_DEFAULT_MNG_DESIRED"
fi

EXIT_CODE=0

gtimeout -s TERM 300 bash -c \
    'while [[ $(kubectl get nodes -l workshop-default=yes -o json | jq -r ".items | length") -gt 3 ]];\
    do sleep 30;\
    done' || EXIT_CODE=$?

if [ "$EXIT_CODE" -ne 0 ]; then
  >&2 echo "Error: Nodes did not scale back to 3"
  exit 1
fi

# Recycle workload pods in case stateful pods got restarted
kubectl delete pod -l app.kubernetes.io/created-by=eks-workshop -l app.kubernetes.io/component=service -A > /dev/null

kubectl wait --for=condition=Ready --timeout=240s pods -l app.kubernetes.io/created-by=eks-workshop -A > /dev/null

echo 'Environment is reset'
