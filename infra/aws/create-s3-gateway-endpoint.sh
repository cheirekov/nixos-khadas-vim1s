#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-nau}"
AWS_REGION="${AWS_REGION:-eu-west-3}"
AWS_SUBNET_ID="${AWS_SUBNET_ID:-}"
AWS_VPC_ID="${AWS_VPC_ID:-}"
ROUTE_TABLE_IDS="${ROUTE_TABLE_IDS:-}"

log() {
  printf '[s3-gateway-endpoint] %s\n' "$*"
}

aws_cli() {
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" "$@"
}

require_env() {
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      echo "Required environment variable ${var} is not set" >&2
      exit 1
    fi
  done
}

discover_vpc_id() {
  if [[ -n "${AWS_VPC_ID}" ]]; then
    printf '%s\n' "${AWS_VPC_ID}"
    return
  fi

  require_env AWS_SUBNET_ID
  aws_cli ec2 describe-subnets \
    --subnet-ids "${AWS_SUBNET_ID}" \
    --query 'Subnets[0].VpcId' \
    --output text
}

discover_route_table_ids() {
  local vpc_id="${1:?vpc-id is required}"
  local route_table_ids

  if [[ -n "${ROUTE_TABLE_IDS}" ]]; then
    printf '%s\n' "${ROUTE_TABLE_IDS}"
    return
  fi

  if [[ -n "${AWS_SUBNET_ID}" ]]; then
    route_table_ids="$(aws_cli ec2 describe-route-tables \
      --filters "Name=association.subnet-id,Values=${AWS_SUBNET_ID}" "Name=vpc-id,Values=${vpc_id}" \
      --query 'RouteTables[].RouteTableId' \
      --output text)"
    if [[ -n "${route_table_ids//[$'\t\r\n ']}" ]]; then
      printf '%s\n' "${route_table_ids}" | tr '\t ' ',' | sed 's/,,*/,/g; s/^,//; s/,$//'
      return
    fi
  fi

  route_table_ids="$(aws_cli ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=association.main,Values=true" \
    --query 'RouteTables[].RouteTableId' \
    --output text)"
  if [[ -z "${route_table_ids//[$'\t\r\n ']}" ]]; then
    echo "Could not discover route table IDs for VPC ${vpc_id}" >&2
    exit 1
  fi
  printf '%s\n' "${route_table_ids}" | tr '\t ' ',' | sed 's/,,*/,/g; s/^,//; s/,$//'
}

main() {
  local vpc_id route_table_ids existing_endpoint_id endpoint_id service_name endpoint_state
  local -a route_table_args

  vpc_id="$(discover_vpc_id)"
  route_table_ids="$(discover_route_table_ids "${vpc_id}")"
  service_name="com.amazonaws.${AWS_REGION}.s3"

  existing_endpoint_id="$(aws_cli ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=service-name,Values=${service_name}" \
    --query 'VpcEndpoints[0].VpcEndpointId' \
    --output text)"

  IFS=',' read -r -a route_table_args <<<"${route_table_ids}"

  if [[ -n "${existing_endpoint_id}" && "${existing_endpoint_id}" != "None" ]]; then
    log "S3 gateway endpoint already exists: ${existing_endpoint_id}"
    log "ensuring route tables are associated: ${route_table_ids}"
    aws_cli ec2 modify-vpc-endpoint \
      --vpc-endpoint-id "${existing_endpoint_id}" \
      --add-route-table-ids "${route_table_args[@]}" >/dev/null
    endpoint_id="${existing_endpoint_id}"
  else
    log "creating S3 gateway endpoint in ${vpc_id} for route tables ${route_table_ids}"
    endpoint_id="$(aws_cli ec2 create-vpc-endpoint \
      --vpc-id "${vpc_id}" \
      --service-name "${service_name}" \
      --vpc-endpoint-type Gateway \
      --route-table-ids "${route_table_args[@]}" \
      --query 'VpcEndpoint.VpcEndpointId' \
      --output text)"
  fi

  for _ in $(seq 1 30); do
    endpoint_state="$(aws_cli ec2 describe-vpc-endpoints \
      --vpc-endpoint-ids "${endpoint_id}" \
      --query 'VpcEndpoints[0].State' \
      --output text)"
    if [[ "${endpoint_state}" == "available" ]]; then
      break
    fi
    sleep 2
  done

  if [[ "${endpoint_state:-}" != "available" ]]; then
    echo "VPC endpoint ${endpoint_id} did not become available; current state: ${endpoint_state:-unknown}" >&2
    exit 1
  fi

  cat <<EOF
VPC_ENDPOINT_ID=${endpoint_id}
AWS_REGION=${AWS_REGION}
AWS_VPC_ID=${vpc_id}
ROUTE_TABLE_IDS=${route_table_ids}
SERVICE_NAME=${service_name}
EOF
}

main "$@"
