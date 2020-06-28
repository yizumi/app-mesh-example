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
MESH_NAME=${PROJECT_NAME}-mesh
CLUSTER_NAME=${PROJECT_NAME}
NAMESPACE=echo.local
VIRTUAL_SERVICE_NAME=$SERVICE_NAME.$NAMESPACE

find_used_nodes() {
  VIRTUAL_ROUTER_NAME=$(aws appmesh describe-virtual-service --mesh-name $MESH_NAME --virtual-service-name $VIRTUAL_SERVICE_NAME |
    jq -r '.virtualService.spec.provider.virtualRouter.virtualRouterName')
  ROUTE_NAME=$(aws appmesh list-routes --mesh-name $MESH_NAME --virtual-router-name $VIRTUAL_ROUTER_NAME | jq -r '.routes[0].routeName')
  USED_VIRTUAL_NODES=$(aws appmesh describe-route --mesh-name $MESH_NAME --virtual-router-name $VIRTUAL_ROUTER_NAME --route-name $ROUTE_NAME | \
    jq -r '.route.spec.grpcRoute.action.weightedTargets[] | select(. | .weight >= 0) | .virtualNode')
  echo $USED_VIRTUAL_NODES
}

find_unused_nodes() {
  VIRTUAL_NODES=$(aws appmesh list-virtual-nodes --mesh-name $MESH_NAME | jq -r '.virtualNodes[] | select(.virtualNodeName | contains("'$SERVICE_NAME'")) | .virtualNodeName')
  for i in $USED_VIRTUAL_NODES; do
    VIRTUAL_NODES=$(echo $VIRTUAL_NODES | sed "s/$i//g")
  done
  echo $VIRTUAL_NODES
}

find_used_task_definitions() {
  TASK_DEFINITION_ARNS=$(aws ecs list-task-definitions --family-prefix $SERVICE_NAME | jq -r '.taskDefinitionArns[] | @text')
  USED_TASK_DEFINITIONS=""
  for taskName in $TASK_DEFINITION_ARNS; do
    vNodeName=$(aws ecs describe-task-definition --task-definition $taskName | \
      jq -r '.taskDefinition.containerDefinitions[] | select(.name == "envoy") | .environment[] | select(.name == "APPMESH_VIRTUAL_NODE_NAME") | .value')
    for usedVNode in $USED_VIRTUAL_NODES; do
      if [ "$vNodeName" == "mesh/$MESH_NAME/virtualNode/${usedVNode}" ]; then
        USED_TASK_DEFINITIONS="${USED_TASK_DEFINITIONS} $taskName"
      fi
    done
  done
  echo $USED_TASK_DEFINITIONS
}

find_unused_task_definitions() {
  TASK_DEFINITION_ARNS=$(aws ecs list-task-definitions --family-prefix $SERVICE_NAME | jq -r '.taskDefinitionArns[] | @text')
  UNUSED_TASK_DEFINITIONS=""
  for taskName in $TASK_DEFINITION_ARNS; do
    vNodeName=$(aws ecs describe-task-definition --task-definition $taskName | \
      jq -r '.taskDefinition.containerDefinitions[] | select(.name == "envoy") | .environment[] | select(.name == "APPMESH_VIRTUAL_NODE_NAME") | .value')
    for unusedVNode in $UNUSED_VIRTUAL_NODES; do
      if [ "$vNodeName" == "mesh/$MESH_NAME/virtualNode/${unusedVNode}" ]; then
        UNUSED_TASK_DEFINITIONS="${UNUSED_TASK_DEFINITIONS} $taskName"
      fi
    done
  done
  echo $UNUSED_TASK_DEFINITIONS
}

promote_used_task_set() {
  echo "Promoting Used Task Set"
  TASK_SETS=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $ECS_SERVICE_NAME | jq -r '.services[0].taskSets')
  for usedTaskDef in $USED_TASK_DEFINITIONS; do
    TASK_SET_ARN=$(echo $TASK_SETS | jq -r '.[] | select(.taskDefinition == "'$usedTaskDef'") | .taskSetArn')
    if [ ! -z "$TASK_SET_ARN" ]; then
      echo "Promoting $TASK_SET_ARN"
      aws ecs update-service-primary-task-set --cluster $CLUSTER_NAME --service $ECS_SERVICE_NAME --primary-task-set $TASK_SET_ARN
      echo "Finished promoting task set"
      break
    fi
  done
}

delete_unused_ecs_services() {
  echo "Deleting unused ECS Task Sets"
  TASK_SETS=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $ECS_SERVICE_NAME | jq -r '.services[0].taskSets')
  for unusedTaskDef in $UNUSED_TASK_DEFINITIONS; do
    TASK_SET_ARN=$(echo $TASK_SETS | jq -r '.[] | select(.taskDefinition == "'$unusedTaskDef'") | .taskSetArn')
    if [ ! -z "$TASK_SET_ARN" ]; then
      echo Deleting $TASK_SET_ARN
      aws ecs delete-task-set --cluster $CLUSTER_NAME --service $ECS_SERVICE_NAME --task-set $TASK_SET_ARN
    fi
  done
}

delete_unused_virtual_nodes() {
  echo "Deleting Unused Virtual Nodes"
  for unusedVNode in $UNUSED_VIRTUAL_NODES; do
    echo "Deleting $unusedVNode"
    aws appmesh delete-virtual-node --mesh-name $MESH_NAME --virtual-node-name $unusedVNode > /dev/null
  done
}

USED_VIRTUAL_NODES=$(find_used_nodes)
echo Used Virtual Nodes:
echo $USED_VIRTUAL_NODES | tr ' ' '\n'

UNUSED_VIRTUAL_NODES=$(find_unused_nodes)
echo Unused Virtual Nodes:
echo $UNUSED_VIRTUAL_NODES | tr ' ' '\n'

USED_TASK_DEFINITIONS=$(find_used_task_definitions)
echo "Used Task Definitions:"
echo $USED_TASK_DEFINITIONS | tr ' ' '\n'

UNUSED_TASK_DEFINITIONS=$(find_unused_task_definitions)
echo Unused Task Definitions:
echo $UNUSED_TASK_DEFINITIONS | tr ' ' '\n'

promote_used_task_set
delete_unused_ecs_services
delete_unused_virtual_nodes
