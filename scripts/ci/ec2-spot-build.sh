#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ec2-spot-build.sh launch
  ec2-spot-build.sh launch-fleet
  ec2-spot-build.sh wait-ssm <instance-id>
  ec2-spot-build.sh run-build <instance-id> <log-group>
  ec2-spot-build.sh salvage-cache <instance-id> [window-minutes]
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

wait_for_ssm_agent_update() {
  local instance_id="${1:?instance-id is required}"
  local deadline update_in_progress

  deadline=$((SECONDS + 300))
  while (( SECONDS < deadline )); do
    update_in_progress="$(aws ssm list-command-invocations \
      --region "${AWS_REGION}" \
      --details \
      --filters "Key=InstanceId,Values=${instance_id}" \
      --query "length(CommandInvocations[?DocumentName=='AWS-UpdateSSMAgent' && (Status=='Pending' || Status=='InProgress' || Status=='Delayed')])" \
      --output text 2>/dev/null || echo 0)"

    if [[ -z "${update_in_progress}" || "${update_in_progress}" == "0" ]]; then
      return 0
    fi

    log "waiting for AWS-UpdateSSMAgent to settle on ${instance_id}"
    sleep 10
  done

  log "timed out waiting for AWS-UpdateSSMAgent to settle on ${instance_id}; continuing anyway"
  return 0
}

fetch_remote_log_delta() {
  local instance_id="${1:?instance-id is required}"
  local start_offset="${2:?start-offset is required}"
  local tmp_commands tmp_params tmp_status command_id status

  tmp_commands="$(mktemp)"
  tmp_params="$(mktemp)"
  tmp_status="$(mktemp)"

  {
    echo "set -euo pipefail"
    printf 'START_OFFSET=%q\n' "${start_offset}"
    cat <<'EOF'
LOGFILE=/var/tmp/nixos-khadas-vim1s-build/remote-build.log
if [[ -f "${LOGFILE}" ]]; then
  LOG_SIZE="$(wc -c < "${LOGFILE}")"
  echo "__REMOTE_LOG_SIZE__=${LOG_SIZE}"
  if (( START_OFFSET <= LOG_SIZE )); then
    tail -c "+${START_OFFSET}" "${LOGFILE}"
  fi
else
  echo "__REMOTE_LOG_SIZE__=0"
fi
EOF
  } > "${tmp_commands}"

  jq -n --rawfile lines "${tmp_commands}" '{commands: ($lines | split("\n") | map(select(length > 0)))}' > "${tmp_params}"

  if ! command_id="$(aws ssm send-command \
    --region "${AWS_REGION}" \
    --instance-ids "${instance_id}" \
    --document-name 'AWS-RunShellScript' \
    --comment 'Read remote build log tail' \
    --parameters "file://${tmp_params}" \
    --query 'Command.CommandId' \
    --output text)"; then
    rm -f "${tmp_commands}" "${tmp_params}" "${tmp_status}"
    return 1
  fi

  for _ in $(seq 1 20); do
    if aws ssm get-command-invocation \
      --region "${AWS_REGION}" \
      --command-id "${command_id}" \
      --instance-id "${instance_id}" \
      --output json > "${tmp_status}" 2>/dev/null; then
      status="$(jq -r '.Status // empty' "${tmp_status}")"
      case "${status}" in
        Success|Cancelled|Cancelling|Failed|TimedOut|DeliveryTimedOut|ExecutionTimedOut)
          break
          ;;
      esac
    fi
    sleep 1
  done

  jq -r '.StandardOutputContent // ""' "${tmp_status}"
  rm -f "${tmp_commands}" "${tmp_params}" "${tmp_status}"
}

run_build() {
  local instance_id="${1:?instance-id is required}"
  local log_group="${2:?log-group is required}"
  local command_id status stdout stderr tail_pid="" tmp_commands tmp_params tmp_status tmp_stdout tmp_stderr
  local build_exit_code=0 final_status=""
  local last_stdout_size=0 last_stderr_size=0 current_stdout_size current_stderr_size
  local last_remote_log_offset=1 remote_log_output remote_log_size remote_log_payload

  require_env AWS_REGION RAW_BUILD_SCRIPT_URL REPO_URL REPO_SHA TARGET_ATTR

  aws logs create-log-group --region "${AWS_REGION}" --log-group-name "${log_group}" 2>/dev/null || true
  aws logs put-retention-policy --region "${AWS_REGION}" --log-group-name "${log_group}" --retention-in-days 7 >/dev/null

  tmp_commands="$(mktemp)"
  tmp_params="$(mktemp)"
  tmp_status="$(mktemp)"
  tmp_stdout="$(mktemp)"
  tmp_stderr="$(mktemp)"

  {
    echo "set -euo pipefail"
    printf 'export TARGET_ATTR=%q\n' "${TARGET_ATTR}"
    printf 'export REPO_URL=%q\n' "${REPO_URL}"
    printf 'export REPO_SHA=%q\n' "${REPO_SHA}"
    printf 'export AWS_REGION=%q\n' "${AWS_REGION}"
    printf 'export NIX_CACHE_REGION=%q\n' "${NIX_CACHE_REGION:-${AWS_REGION}}"
    printf 'export NIX_CACHE_BUCKET_NAME=%q\n' "${NIX_CACHE_BUCKET_NAME:-nix-cache-vim1s-${AWS_REGION}}"
    printf 'export NIX_BINARY_CACHE_SECRET_KEY=%q\n' "${NIX_BINARY_CACHE_SECRET_KEY:-}"
    printf 'curl --fail --location --progress-bar %q -o /tmp/build-on-builder.sh\n' "${RAW_BUILD_SCRIPT_URL}"
    echo "chmod +x /tmp/build-on-builder.sh"
    echo "mkdir -p /var/tmp/nixos-khadas-vim1s-build"
    echo 'LOGFILE=/var/tmp/nixos-khadas-vim1s-build/remote-build.log'
    echo 'echo "[ssm] streaming remote build to ${LOGFILE}"'
    echo 'if command -v stdbuf >/dev/null 2>&1; then'
    echo '  stdbuf -oL -eL /tmp/build-on-builder.sh 2>&1 | tee "${LOGFILE}"'
    echo 'else'
    echo '  /tmp/build-on-builder.sh 2>&1 | tee "${LOGFILE}"'
    echo 'fi'
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
  trap '[[ -n "${tail_pid:-}" ]] && kill "${tail_pid}" 2>/dev/null || true; rm -f "${tmp_commands:-}" "${tmp_params:-}" "${tmp_status:-}" "${tmp_stdout:-}" "${tmp_stderr:-}"' EXIT

  while true; do
    if ! aws ssm get-command-invocation \
      --region "${AWS_REGION}" \
      --command-id "${command_id}" \
      --instance-id "${instance_id}" \
      --output json > "${tmp_status}" 2>/dev/null; then
      sleep 15
      continue
    fi

    status="$(jq -r '.Status // empty' "${tmp_status}")"

    jq -r '.StandardOutputContent // ""' "${tmp_status}" > "${tmp_stdout}"
    current_stdout_size="$(wc -c < "${tmp_stdout}")"
    if (( current_stdout_size > last_stdout_size )) && (( last_remote_log_offset == 1 )); then
      tail -c "+$((last_stdout_size + 1))" "${tmp_stdout}"
    fi
    last_stdout_size=${current_stdout_size}

    jq -r '.StandardErrorContent // ""' "${tmp_status}" > "${tmp_stderr}"
    current_stderr_size="$(wc -c < "${tmp_stderr}")"
    if (( current_stderr_size > last_stderr_size )) && (( last_remote_log_offset == 1 )); then
      tail -c "+$((last_stderr_size + 1))" "${tmp_stderr}" >&2
    fi
    last_stderr_size=${current_stderr_size}

    if remote_log_output="$(fetch_remote_log_delta "${instance_id}" "${last_remote_log_offset}" 2>/dev/null)"; then
      remote_log_size="$(sed -n '1s/^__REMOTE_LOG_SIZE__=//p' <<<"${remote_log_output}")"
      remote_log_payload="$(sed '1{/^__REMOTE_LOG_SIZE__=/d;}' <<<"${remote_log_output}")"
      if [[ -n "${remote_log_payload}" ]]; then
        printf '%s' "${remote_log_payload}"
        [[ "${remote_log_payload}" == *$'\n' ]] || printf '\n'
      fi
      if [[ "${remote_log_size}" =~ ^[0-9]+$ ]]; then
        last_remote_log_offset=$((remote_log_size + 1))
      fi
    fi

    case "${status}" in
      Pending|InProgress|Delayed|"")
        sleep 15
        ;;
      Success)
        final_status="Success"
        break
        ;;
      Cancelled|Cancelling|Failed|TimedOut|DeliveryTimedOut|ExecutionTimedOut)
        final_status="${status}"
        build_exit_code=1
        break
        ;;
      *)
        sleep 15
        ;;
    esac
  done

  if remote_log_output="$(fetch_remote_log_delta "${instance_id}" "${last_remote_log_offset}" 2>/dev/null)"; then
    remote_log_size="$(sed -n '1s/^__REMOTE_LOG_SIZE__=//p' <<<"${remote_log_output}")"
    remote_log_payload="$(sed '1{/^__REMOTE_LOG_SIZE__=/d;}' <<<"${remote_log_output}")"
    if [[ -n "${remote_log_payload}" ]]; then
      printf '%s' "${remote_log_payload}"
      [[ "${remote_log_payload}" == *$'\n' ]] || printf '\n'
    fi
    if [[ "${remote_log_size}" =~ ^[0-9]+$ ]]; then
      last_remote_log_offset=$((remote_log_size + 1))
    fi
  fi

  kill "${tail_pid}" 2>/dev/null || true
  trap - EXIT
  stdout="$(cat "${tmp_stdout}")"
  if [[ "${build_exit_code}" -eq 0 ]]; then
    grep -E '^(BUILD_RESULT|CACHE_PUSH)=' <<<"${stdout}" || true
  else
    echo "Remote build failed with SSM status ${final_status:-unknown}" >&2
  fi
  rm -f "${tmp_commands}" "${tmp_params}" "${tmp_status}" "${tmp_stdout}" "${tmp_stderr}"
  return "${build_exit_code}"
}

salvage_cache() {
  local instance_id="${1:?instance-id is required}"
  local window_minutes="${2:-240}"
  local tmp_commands tmp_params

  require_env AWS_REGION

  tmp_commands="$(mktemp)"
  tmp_params="$(mktemp)"

  {
    echo "set -euo pipefail"
    printf 'export AWS_REGION=%q\n' "${AWS_REGION}"
    printf 'export NIX_CACHE_REGION=%q\n' "${NIX_CACHE_REGION:-${AWS_REGION}}"
    printf 'export NIX_CACHE_BUCKET_NAME=%q\n' "${NIX_CACHE_BUCKET_NAME:-nix-cache-vim1s-${AWS_REGION}}"
    printf 'export NIX_BINARY_CACHE_SECRET_KEY=%q\n' "${NIX_BINARY_CACHE_SECRET_KEY:-}"
    printf 'WINDOW_MINUTES=%q\n' "${window_minutes}"
    cat <<'EOF'
NIX_BIN="$(command -v nix)"
if [[ -z "${NIX_BIN}" ]]; then
  NIX_BIN=/nix/var/nix/profiles/default/bin/nix
fi

CACHE_URI="s3://${NIX_CACHE_BUCKET_NAME}?scheme=https&region=${NIX_CACHE_REGION}&secret-key=${NIX_BINARY_CACHE_SECRET_KEY}"
TMP_PATHS=/tmp/nixos-khadas-salvage-paths.txt

find /nix/store -maxdepth 1 -mindepth 1 -mmin "-${WINDOW_MINUTES}" ! -name '*.drv' | sort -u > "${TMP_PATHS}"
echo "SALVAGE_PATH_COUNT=$(wc -l < "${TMP_PATHS}")"
sed -n '1,20p' "${TMP_PATHS}"

if [[ -s "${TMP_PATHS}" ]]; then
  xargs -r -n 64 "${NIX_BIN}" --extra-experimental-features 'nix-command flakes' copy -L --to "${CACHE_URI}" < "${TMP_PATHS}"
fi
EOF
  } > "${tmp_commands}"

  jq -n --rawfile lines "${tmp_commands}" '{commands: ($lines | split("\n") | map(select(length > 0)))}' > "${tmp_params}"

  aws ssm send-command \
    --region "${AWS_REGION}" \
    --instance-ids "${instance_id}" \
    --document-name 'AWS-RunShellScript' \
    --comment "Salvage recent store paths to S3 cache" \
    --parameters "file://${tmp_params}" \
    --query 'Command.CommandId' \
    --output text

  rm -f "${tmp_commands}" "${tmp_params}"
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
    wait_for_ssm_agent_update "$@"
    ;;
  run-build)
    run_build "$@"
    ;;
  salvage-cache)
    salvage_cache "$@"
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
