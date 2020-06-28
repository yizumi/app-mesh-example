#!/bin/bash -e

export AWS_PAGER=""

if [ -z $PROJECT_NAME ]; then
  echo "PROJECT_NAME environment variable is not set."
  exit 1
fi

if [ -z $SERVICE_NAME ]; then
  echo "SERVICE_NAME environment variable is not set."
  exit 1
fi

ECS_SERVICE_NAME=$(aws ecs list-services --cluster $PROJECT_NAME| jq '.serviceArns[] | select(index("'$SERVICE_NAME'") > -1)' | sed -e 's/.*\/\(.*\)"$/\1/g')
VPC_CONFIG=$(aws ecs describe-services --cluster $PROJECT_NAME --services $ECS_SERVICE_NAME | jq '.services[0].taskSets[0].networkConfiguration.awsvpcConfiguration')
PRIVATE_SUBNET_1=$(echo $VPC_CONFIG | jq ".subnets[0]" | sed 's/\"//g')
PRIVATE_SUBNET_2=$(echo $VPC_CONFIG | jq ".subnets[1]" | sed 's/\"//g')
SECURITY_GROUP=$(echo $VPC_CONFIG | jq ".securityGroups[0]" | sed 's/\"//g')

echo ECS_SERVICE_NAME: ${ECS_SERVICE_NAME}

if [ -z $PRIVATE_SUBNET_1 ] || [ -z $PRIVATE_SUBNET_2 ] || [ "$PRIVATE_SUBNET_1" == "null" ] || [ "$PRIVATE_SUBNET_2" == "null" ]; then
  echo "Could not resolve PrivateSubnets"
  echo "Exiting..."
  exit 1
fi
echo "Detected PrivateSubnet1: ${PRIVATE_SUBNET_1}"
echo "Detected PrivateSubnet2: ${PRIVATE_SUBNET_2}"

if [ -z $SECURITY_GROUP ] || [ "$SECURITY_GROUP" == "null" ]; then
  echo "Could not resolve Security Group"
  echo "Exiting..."
  exit 1
fi
echo "Using Security Group: ${SECURITY_GROUP}"

# Desired number of Tasks to run on ECS
DESIRED_COUNT=2
CLUSTER_NAME=$PROJECT_NAME
MESH_NAME=${PROJECT_NAME}-mesh
NAMESPACE=${PROJECT_NAME}.local
SERVICE_NAME=${PROJECT_NAME}_server
VIRTUAL_ROUTER_NAME=virtual-router
ROUTE_NAME=route
VERSION=$(date +%Y%m%d%H%M%S)

VIRTUAL_NODE_NAME=${SERVICE_NAME}-${VERSION}

create_virtual_node() {
  echo "Creating Virtual Node: $VIRTUAL_NODE_NAME"
  SPEC=$(cat <<-EOF
{
    "serviceDiscovery": {
        "awsCloudMap": {
            "namespaceName": "$NAMESPACE",
            "serviceName": "$SERVICE_NAME",
            "attributes": [
                {
                    "key": "ECS_TASK_SET_EXTERNAL_ID",
                    "value": "${VIRTUAL_NODE_NAME}-task-set"
                }
            ]
        }
    },
    "listeners": [
        {
            "healthCheck": {
                "healthyThreshold": 2,
                "intervalMillis": 5000,
                "port": 8080,
                "protocol": "grpc",
                "timeoutMillis": 2000,
                "unhealthyThreshold": 3
            },
            "portMapping": {
                "port": 8080,
                "protocol": "grpc"
            }
        }
    ]
}
EOF
)
  # Create app mesh virtual node #
  aws appmesh create-virtual-node \
    --mesh-name $MESH_NAME \ --virtual-node-name $VIRTUAL_NODE_NAME \
    --spec "$SPEC"
}

# based on the existing route definition, we'll add the newly created virtual node to the list, but not forwarding any traffic
init_traffic_route() {
  echo "Updating the traffic route definition"
  SPEC=$(aws appmesh describe-route --mesh-name $MESH_NAME --virtual-router-name $VIRTUAL_ROUTER_NAME --route-name $ROUTE_NAME \
         | jq ".route.spec" | jq '.grpcRoute.action.weightedTargets += [{"virtualNode":"'$VIRTUAL_NODE_NAME'", "weight": 0}]')
  aws appmesh update-route --mesh-name $MESH_NAME --virtual-router-name $VIRTUAL_ROUTER_NAME --route-name $ROUTE_NAME --spec "$SPEC"
}

register_new_task() {
  echo "Creating a new task definition pointing at the new virtual node"
  TASK_DEF_ARN=$(aws ecs list-task-definitions | \
    jq -r ' .taskDefinitionArns[] | select( . | contains("'$SERVICE_NAME'"))' | tail -1)  TASK_DEF_OLD=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN)
  TASK_DEF_NEW=$(echo $TASK_DEF_OLD \
    | jq ' .taskDefinition' \
    | jq ' .containerDefinitions[].environment |= map(
          if .name=="APPMESH_VIRTUAL_NODE_NAME" then
            .value="mesh/'$MESH_NAME'/virtualNode/'$VIRTUAL_NODE_NAME'"
          else . end) ' \
    | jq ' del(.status, .compatibilities, .taskDefinitionArn, .requiresAttributes, .revision) '
  )
  TASK_DEF_FAMILY=$(echo $TASK_DEF_ARN | cut -d"/" -f2 | cut -d":" -f1)
  echo $TASK_DEF_NEW > /tmp/$TASK_DEF_FAMILY.json &&
    aws ecs register-task-definition --cli-input-json file:///tmp/$TASK_DEF_FAMILY.json
}

create_task_set() {
  echo "Creating a new task set"
  SERVICE_ARN=$(aws ecs list-services --cluster $CLUSTER_NAME | \
    jq -r ' .serviceArns[] | select( . | contains("'$ECS_SERVICE_NAME'"))' | tail -1)
  TASK_DEF_ARN=$(aws ecs list-task-definitions | \
    jq -r ' .taskDefinitionArns[] | select( . | contains("'$SERVICE_NAME'"))' | tail -1)
  CMAP_SVC_ARN=$(aws servicediscovery list-services | \
    jq -r '.Services[] | select(.Name == "'$SERVICE_NAME'") | .Arn');

  echo Service ARN: ${SERVICE_ARN}
  echo Task Def ARN: ${TASK_DEF_ARN}
  echo CloudMap Service ARN: {$CMAP_SVC_ARN}

  # Create ecs task set #
  aws ecs create-task-set \
    --service $SERVICE_ARN \
    --cluster $CLUSTER_NAME \
    --external-id $VIRTUAL_NODE_NAME-task-set \
    --task-definition "$(echo $TASK_DEF_ARN)" \
    --service-registries "registryArn=$CMAP_SVC_ARN" \
    --scale value=100,unit=PERCENT \
    --launch-type FARGATE \
    --network-configuration \
        "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2],
          securityGroups=[$SECURITY_GROUP],
          assignPublicIp=DISABLED}"
}

wait_for_ecs_service() {
  CMAP_SVC_ID=$(aws servicediscovery list-services | \
    jq -r '.Services[] | select(.Name == "'$SERVICE_NAME'") | .Id');

  # Get number of running tasks #
  _count_unhealthy_tasks() {
    aws ecs list-tasks --cluster $CLUSTER_NAME --service $ECS_SERVICE_NAME | \
      jq -r '.taskArns | @text' | while read taskArns; do aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $taskArns; done | \
      jq -r '[.tasks[] | select(.lastStatus != "RUNNING")] | length'
  }

  # Get count of instances with unhealth status #
  _count_unhealthy_instances() {
    aws servicediscovery get-instances-health-status --service-id $CMAP_SVC_ID | \
      jq ' [.Status | to_entries[] | select( .value != "HEALTHY")] | length'
  }

  while [ "$(_count_unhealthy_tasks)" -eq 0 ]; do
    echo "Waiting for new tasks to appear"
    sleep 5s 
  done
  while [ "$(_count_unhealthy_tasks)" -gt 0 ]; do
    echo "Waiting for All Tasks to be in RUNNING state (Waiting for $(_count_unhealthy_tasks) tasks)..."
    sleep 5s
  done
  while [ "$(_count_unhealthy_instances)" -eq 0 ]; do
    echo "Waiting for new instances to appear in the list"
    sleep 5s
  done
  while [ "$(_count_unhealthy_instances)" -gt 0 ]; do
    echo "Waiting for All Instances to be in HEALTHY state (Waiting for $(_count_unhealthy_instances) instances)..."
    sleep 5s
  done
}

switch_traffic_route() {
  echo "Updating traffic route"
  SPEC=$(aws appmesh describe-route --mesh-name $MESH_NAME --virtual-router-name $VIRTUAL_ROUTER_NAME --route-name $ROUTE_NAME \
    | jq ".route.spec" | jq '.grpcRoute.action.weightedTargets |= map({"virtualNode":.virtualNode, "weight": 1})' | jq '.grpcRoute.action.weightedTargets |= [.[-1]]')
  echo $SPEC
  aws appmesh update-route --mesh-name $MESH_NAME --virtual-router-name $VIRTUAL_ROUTER_NAME --route-name $ROUTE_NAME --spec "$SPEC"
}

create_virtual_node
init_traffic_route 
register_new_task
create_task_set
wait_for_ecs_service
switch_traffic_route

echo New Virtual Node: $VIRTUAL_NODE_NAME
