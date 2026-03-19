#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ec2-spot-build.sh launch
  ec2-spot-build.sh launch-fleet
  ec2-spot-build.sh wait-ssm <instance-id>
  ec2-spot-build.sh run-build <instance-id> <log-group>
  ec2-spot-build.sh terminate <instance-id>
  ec2-spot-build.sh terminate-fleet <fleet-id> <launch-template-id> [instance-id]
EOF
}

log() {
  printf '[ec2-spot-build] %s\n' "$*" >&2
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

resolve_ami_id() {
  require_env AWS_REGION EC2_AMI_SSM_PARAMETER

  aws ssm get-parameter \
    --region "${AWS_REGION}" \
    --name "${EC2_AMI_SSM_PARAMETER}" \
    --query 'Parameter.Value' \
    --output text
}

launch() {
  local ami_id instance_id instance_output instance_type launch_name status
  local -a candidates

  require_env AWS_REGION EC2_AMI_SSM_PARAMETER INSTANCE_TYPES SUBNET_ID SECURITY_GROUP_ID INSTANCE_PROFILE_NAME

  ami_id="$(resolve_ami_id)"

  launch_name="gha-khadas-${GITHUB_RUN_ID:-manual}"
  IFS=',' read -r -a candidates <<<"${INSTANCE_TYPES}"

  for instance_type in "${candidates[@]}"; do
    instance_type="${instance_type// /}"
    [[ -z "${instance_type}" ]] && continue

    log "trying Spot launch with ${instance_type} in ${AWS_REGION}"
    set +e
    instance_output="$(
      aws ec2 run-instances \
        --region "${AWS_REGION}" \
        --image-id "${ami_id}" \
        --instance-type "${instance_type}" \
        --instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}' \
        --instance-initiated-shutdown-behavior terminate \
        --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
        --subnet-id "${SUBNET_ID}" \
        --security-group-ids "${SECURITY_GROUP_ID}" \
        --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
        --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"DeleteOnTermination\":true,\"VolumeSize\":${ROOT_VOLUME_GB:-250},\"VolumeType\":\"gp3\"}}]" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${launch_name}},{Key=Repository,Value=${GITHUB_REPOSITORY:-unknown}},{Key=GitHubRunId,Value=${GITHUB_RUN_ID:-manual}}]" \
        --query '{InstanceId: Instances[0].InstanceId, PrivateIp: Instances[0].PrivateIpAddress}' \
        --output json 2>&1
    )"
    status=$?
    set -e

    if [[ ${status} -eq 0 ]]; then
      instance_id="$(jq -r '.InstanceId' <<<"${instance_output}")"
      aws ec2 wait instance-running --region "${AWS_REGION}" --instance-ids "${instance_id}"
      {
        echo "INSTANCE_ID=${instance_id}"
        echo "INSTANCE_TYPE=${instance_type}"
        echo "INSTANCE_AMI=${ami_id}"
      }
      return 0
    fi

    log "launch failed for ${instance_type}: ${instance_output}"
  done

  echo "Unable to launch any requested Spot instance type: ${INSTANCE_TYPES}" >&2
  return 1
}

launch_fleet() {
  local ami_id fleet_id instance_id instance_type launch_name launch_template_id
  local tmp_fleet_json tmp_lt_json tmp_output lt_name
  local -a candidates

  require_env AWS_REGION EC2_AMI_SSM_PARAMETER INSTANCE_TYPES SUBNET_ID SECURITY_GROUP_ID INSTANCE_PROFILE_NAME

  ami_id="$(resolve_ami_id)"
  launch_name="gha-khadas-fleet-${GITHUB_RUN_ID:-manual}"
  lt_name="${launch_name}-$(date +%s)"
  tmp_lt_json="$(mktemp)"
  tmp_fleet_json="$(mktemp)"
  tmp_output="$(mktemp)"

  jq -n \
    --arg image_id "${ami_id}" \
    --arg instance_profile_name "${INSTANCE_PROFILE_NAME}" \
    --arg security_group_id "${SECURITY_GROUP_ID}" \
    --argjson volume_size "${ROOT_VOLUME_GB:-250}" \
    --arg launch_name "${launch_name}" \
    '{
      ImageId: $image_id,
      IamInstanceProfile: { Name: $instance_profile_name },
      SecurityGroupIds: [$security_group_id],
      MetadataOptions: {
        HttpTokens: "required",
        HttpEndpoint: "enabled"
      },
      BlockDeviceMappings: [
        {
          DeviceName: "/dev/xvda",
          Ebs: {
            DeleteOnTermination: true,
            VolumeSize: $volume_size,
            VolumeType: "gp3"
          }
        }
      ],
      InstanceInitiatedShutdownBehavior: "terminate",
      TagSpecifications: [
        {
          ResourceType: "instance",
          Tags: [
            { Key: "Name", Value: $launch_name },
            { Key: "Repository", Value: (env.GITHUB_REPOSITORY // "unknown") },
            { Key: "GitHubRunId", Value: (env.GITHUB_RUN_ID // "manual") }
          ]
        },
        {
          ResourceType: "volume",
          Tags: [
            { Key: "Name", Value: $launch_name }
          ]
        }
      ]
    }' > "${tmp_lt_json}"

  launch_template_id="$(aws ec2 create-launch-template \
    --region "${AWS_REGION}" \
    --launch-template-name "${lt_name}" \
    --version-description "github-actions-${GITHUB_RUN_ID:-manual}" \
    --launch-template-data "file://${tmp_lt_json}" \
    --query 'LaunchTemplate.LaunchTemplateId' \
    --output text)"

  IFS=',' read -r -a candidates <<<"${INSTANCE_TYPES}"
  jq -n \
    --arg launch_template_id "${launch_template_id}" \
    --arg subnet_id "${SUBNET_ID}" \
    --arg launch_name "${launch_name}" \
    --argjson overrides "$(printf '%s\n' "${candidates[@]}" | jq -R 'gsub("^\\s+|\\s+$";"") | select(length > 0) | {InstanceType: ., SubnetId: env.SUBNET_ID}' | jq -s '.')" \
    '{
      Type: "instant",
      SpotOptions: {
        AllocationStrategy: "price-capacity-optimized",
        SingleInstanceType: true,
        SingleAvailabilityZone: true,
        InstanceInterruptionBehavior: "terminate"
      },
      TargetCapacitySpecification: {
        TotalTargetCapacity: 1,
        DefaultTargetCapacityType: "spot"
      },
      LaunchTemplateConfigs: [
        {
          LaunchTemplateSpecification: {
            LaunchTemplateId: $launch_template_id,
            Version: "$Latest"
          },
          Overrides: $overrides
        }
      ],
      TagSpecifications: [
        {
          ResourceType: "fleet",
          Tags: [
            { Key: "Name", Value: $launch_name },
            { Key: "Repository", Value: (env.GITHUB_REPOSITORY // "unknown") },
            { Key: "GitHubRunId", Value: (env.GITHUB_RUN_ID // "manual") }
          ]
        }
      ]
    }' > "${tmp_fleet_json}"

  aws ec2 create-fleet \
    --region "${AWS_REGION}" \
    --cli-input-json "file://${tmp_fleet_json}" > "${tmp_output}"

  fleet_id="$(jq -r '.FleetId' "${tmp_output}")"
  # Instant Fleets return the chosen instance directly in create-fleet output.
  # describe-fleet-instances is not supported for Type=instant fleets.
  instance_id="$(jq -r '
    .Instances[0].InstanceIds[0]
    // .Instances[0].InstanceIds.item
    // .fleetInstanceSet.item.instanceIds.item
    // empty
  ' "${tmp_output}")"

  if [[ -z "${instance_id:-}" || "${instance_id}" == "null" ]]; then
    echo "EC2 Fleet ${fleet_id} did not return an instance in create-fleet output" >&2
    jq -r '.' "${tmp_output}" >&2 || true
    return 1
  fi

  aws ec2 wait instance-running --region "${AWS_REGION}" --instance-ids "${instance_id}"
  instance_type="$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0].InstanceType' \
    --output text)"

  {
    echo "FLEET_ID=${fleet_id}"
    echo "LAUNCH_TEMPLATE_ID=${launch_template_id}"
    echo "INSTANCE_ID=${instance_id}"
    echo "INSTANCE_TYPE=${instance_type}"
    echo "INSTANCE_AMI=${ami_id}"
  }
}

wait_ssm() {
  local instance_id="${1:?instance-id is required}"
  local ping_status deadline

  deadline=$((SECONDS + 900))
  while (( SECONDS < deadline )); do
    ping_status="$(aws ssm describe-instance-information \
      --region "${AWS_REGION}" \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || true)"

    if [[ "${ping_status}" == "Online" ]]; then
      return 0
    fi

    sleep 10
  done

  echo "Instance ${instance_id} did not become available in SSM within 15 minutes" >&2
  return 1
}

run_build() {
  local instance_id="${1:?instance-id is required}"
  local log_group="${2:?log-group is required}"
  local command_id status stdout stderr tail_pid="" tmp_commands tmp_params

  require_env AWS_REGION RAW_BUILD_SCRIPT_URL REPO_URL REPO_SHA TARGET_ATTR

  aws logs create-log-group --region "${AWS_REGION}" --log-group-name "${log_group}" 2>/dev/null || true
  aws logs put-retention-policy --region "${AWS_REGION}" --log-group-name "${log_group}" --retention-in-days 7 >/dev/null

  tmp_commands="$(mktemp)"
  tmp_params="$(mktemp)"

  {
    echo "set -euo pipefail"
    printf 'export TARGET_ATTR=%q\n' "${TARGET_ATTR}"
    printf 'export REPO_URL=%q\n' "${REPO_URL}"
    printf 'export REPO_SHA=%q\n' "${REPO_SHA}"
    printf 'export ATTIC_ENDPOINT=%q\n' "${ATTIC_ENDPOINT:-}"
    printf 'export ATTIC_CACHE=%q\n' "${ATTIC_CACHE:-}"
    printf 'export ATTIC_TOKEN=%q\n' "${ATTIC_TOKEN:-}"
    printf 'curl --fail --location --progress-bar %q -o /tmp/build-on-builder.sh\n' "${RAW_BUILD_SCRIPT_URL}"
    echo "chmod +x /tmp/build-on-builder.sh"
    echo "/tmp/build-on-builder.sh"
  } > "${tmp_commands}"

  jq -n --rawfile lines "${tmp_commands}" '{commands: ($lines | split("\n") | map(select(length > 0)))}' > "${tmp_params}"

  command_id="$(aws ssm send-command \
    --region "${AWS_REGION}" \
    --instance-ids "${instance_id}" \
    --document-name 'AWS-RunShellScript' \
    --comment "Build ${TARGET_ATTR} for ${GITHUB_REPOSITORY:-unknown}" \
    --parameters "file://${tmp_params}" \
    --cloud-watch-output-config "CloudWatchOutputEnabled=true,CloudWatchLogGroupName=${log_group}" \
    --query 'Command.CommandId' \
    --output text)"

  echo "COMMAND_ID=${command_id}"
  echo "INSTANCE_ID=${instance_id}"

  aws logs tail "${log_group}" --region "${AWS_REGION}" --since 1m --follow --format short &
  tail_pid=$!
  trap '[[ -n "${tail_pid:-}" ]] && kill "${tail_pid}" 2>/dev/null || true' EXIT

  while true; do
    status="$(aws ssm get-command-invocation \
      --region "${AWS_REGION}" \
      --command-id "${command_id}" \
      --instance-id "${instance_id}" \
      --query 'Status' \
      --output text 2>/dev/null || true)"

    case "${status}" in
      Pending|InProgress|Delayed|"")
        sleep 15
        ;;
      Success)
        break
        ;;
      Cancelled|Cancelling|Failed|TimedOut|DeliveryTimedOut|ExecutionTimedOut)
        stdout="$(aws ssm get-command-invocation \
          --region "${AWS_REGION}" \
          --command-id "${command_id}" \
          --instance-id "${instance_id}" \
          --query 'StandardOutputContent' \
          --output text || true)"
        stderr="$(aws ssm get-command-invocation \
          --region "${AWS_REGION}" \
          --command-id "${command_id}" \
          --instance-id "${instance_id}" \
          --query 'StandardErrorContent' \
          --output text || true)"
        [[ -n "${stdout}" ]] && printf '%s\n' "${stdout}"
        [[ -n "${stderr}" ]] && printf '%s\n' "${stderr}" >&2
        echo "Remote build failed with SSM status ${status}" >&2
        return 1
        ;;
      *)
        sleep 15
        ;;
    esac
  done

  kill "${tail_pid}" 2>/dev/null || true
  trap - EXIT

  stdout="$(aws ssm get-command-invocation \
    --region "${AWS_REGION}" \
    --command-id "${command_id}" \
    --instance-id "${instance_id}" \
    --query 'StandardOutputContent' \
    --output text || true)"
  stderr="$(aws ssm get-command-invocation \
    --region "${AWS_REGION}" \
    --command-id "${command_id}" \
    --instance-id "${instance_id}" \
    --query 'StandardErrorContent' \
    --output text || true)"

  [[ -n "${stdout}" ]] && printf '%s\n' "${stdout}"
  [[ -n "${stderr}" ]] && printf '%s\n' "${stderr}" >&2

  grep -E '^(BUILD_RESULT|ATTIC_PUSH)=' <<<"${stdout}" || true
}

terminate() {
  local instance_id="${1:?instance-id is required}"
  aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids "${instance_id}" >/dev/null
  aws ec2 wait instance-terminated --region "${AWS_REGION}" --instance-ids "${instance_id}"
}

terminate_fleet() {
  local fleet_id="${1:?fleet-id is required}"
  local launch_template_id="${2:?launch-template-id is required}"
  local instance_id="${3:-}"

  aws ec2 delete-fleets \
    --region "${AWS_REGION}" \
    --fleet-ids "${fleet_id}" \
    --terminate-instances >/dev/null || true

  if [[ -n "${instance_id}" ]]; then
    aws ec2 wait instance-terminated --region "${AWS_REGION}" --instance-ids "${instance_id}" || true
  fi

  aws ec2 delete-launch-template \
    --region "${AWS_REGION}" \
    --launch-template-id "${launch_template_id}" >/dev/null || true
}

subcommand="${1:-}"
shift || true

case "${subcommand}" in
  launch)
    launch "$@"
    ;;
  launch-fleet)
    launch_fleet "$@"
    ;;
  wait-ssm)
    wait_ssm "$@"
    ;;
  run-build)
    run_build "$@"
    ;;
  terminate)
    terminate "$@"
    ;;
  terminate-fleet)
    terminate_fleet "$@"
    ;;
  *)
    usage
    exit 1
    ;;
esac
