#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-nau}"
AWS_REGION="${AWS_REGION:-eu-west-3}"
GITHUB_OWNER="${GITHUB_OWNER:?GITHUB_OWNER is required}"
GITHUB_REPO="${GITHUB_REPO:?GITHUB_REPO is required}"

CONTROL_PLANE_ROLE_NAME="${CONTROL_PLANE_ROLE_NAME:-github-actions-spot-builder-control-plane}"
CONTROL_PLANE_POLICY_NAME="${CONTROL_PLANE_POLICY_NAME:-github-actions-spot-builder-control-plane}"
BUILDER_INSTANCE_ROLE_NAME="${BUILDER_INSTANCE_ROLE_NAME:-github-actions-spot-builder-instance}"
BUILDER_INSTANCE_PROFILE_NAME="${BUILDER_INSTANCE_PROFILE_NAME:-github-actions-spot-builder-instance-profile}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRUST_TEMPLATE="${SCRIPT_DIR}/github-actions-spot-builder-trust-policy.json"
CONTROL_PLANE_TEMPLATE="${SCRIPT_DIR}/github-actions-spot-builder-control-plane-policy.json"

log() {
  printf '[aws-bootstrap] %s\n' "$*"
}

aws_cli() {
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" "$@"
}

render_template() {
  local input="${1:?input is required}"
  local output="${2:?output is required}"

  sed \
    -e "s|<ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
    -e "s|<OWNER>|${GITHUB_OWNER}|g" \
    -e "s|<REPO>|${GITHUB_REPO}|g" \
    -e "s|<REGION>|${AWS_REGION}|g" \
    -e "s|<BUILDER_INSTANCE_ROLE_NAME>|${BUILDER_INSTANCE_ROLE_NAME}|g" \
    "${input}" > "${output}"
}

ensure_oidc_provider() {
  OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

  if aws_cli iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" >/dev/null 2>&1; then
    log "GitHub OIDC provider already exists"
    return
  fi

  log "creating GitHub OIDC provider"
  aws_cli iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" >/dev/null
}

ensure_control_plane_role() {
  local trust_json policy_json
  trust_json="$(mktemp)"
  policy_json="$(mktemp)"

  render_template "${TRUST_TEMPLATE}" "${trust_json}"
  render_template "${CONTROL_PLANE_TEMPLATE}" "${policy_json}"

  if aws_cli iam get-role --role-name "${CONTROL_PLANE_ROLE_NAME}" >/dev/null 2>&1; then
    log "updating assume-role policy for ${CONTROL_PLANE_ROLE_NAME}"
    aws_cli iam update-assume-role-policy \
      --role-name "${CONTROL_PLANE_ROLE_NAME}" \
      --policy-document "file://${trust_json}"
  else
    log "creating control-plane role ${CONTROL_PLANE_ROLE_NAME}"
    aws_cli iam create-role \
      --role-name "${CONTROL_PLANE_ROLE_NAME}" \
      --assume-role-policy-document "file://${trust_json}" \
      --description "GitHub Actions OIDC role for ephemeral EC2 Spot/Fleet builders" >/dev/null
  fi

  log "putting inline policy ${CONTROL_PLANE_POLICY_NAME} on ${CONTROL_PLANE_ROLE_NAME}"
  aws_cli iam put-role-policy \
    --role-name "${CONTROL_PLANE_ROLE_NAME}" \
    --policy-name "${CONTROL_PLANE_POLICY_NAME}" \
    --policy-document "file://${policy_json}"
}

ensure_builder_instance_role() {
  local ec2_trust_json
  ec2_trust_json="$(mktemp)"

  cat > "${ec2_trust_json}" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  if aws_cli iam get-role --role-name "${BUILDER_INSTANCE_ROLE_NAME}" >/dev/null 2>&1; then
    log "builder instance role ${BUILDER_INSTANCE_ROLE_NAME} already exists"
  else
    log "creating builder instance role ${BUILDER_INSTANCE_ROLE_NAME}"
    aws_cli iam create-role \
      --role-name "${BUILDER_INSTANCE_ROLE_NAME}" \
      --assume-role-policy-document "file://${ec2_trust_json}" \
      --description "EC2 instance role for ephemeral Nix builders over SSM" >/dev/null
  fi

  log "attaching AmazonSSMManagedInstanceCore to ${BUILDER_INSTANCE_ROLE_NAME}"
  aws_cli iam attach-role-policy \
    --role-name "${BUILDER_INSTANCE_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" >/dev/null || true

  if aws_cli iam get-instance-profile --instance-profile-name "${BUILDER_INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then
    log "instance profile ${BUILDER_INSTANCE_PROFILE_NAME} already exists"
  else
    log "creating instance profile ${BUILDER_INSTANCE_PROFILE_NAME}"
    aws_cli iam create-instance-profile \
      --instance-profile-name "${BUILDER_INSTANCE_PROFILE_NAME}" >/dev/null
  fi

  if aws_cli iam get-instance-profile --instance-profile-name "${BUILDER_INSTANCE_PROFILE_NAME}" \
      --query "InstanceProfile.Roles[?RoleName=='${BUILDER_INSTANCE_ROLE_NAME}'] | length(@)" \
      --output text | grep -qx '1'; then
    log "instance role already attached to profile"
  else
    log "adding ${BUILDER_INSTANCE_ROLE_NAME} to ${BUILDER_INSTANCE_PROFILE_NAME}"
    aws_cli iam add-role-to-instance-profile \
      --instance-profile-name "${BUILDER_INSTANCE_PROFILE_NAME}" \
      --role-name "${BUILDER_INSTANCE_ROLE_NAME}"
    sleep 10
  fi
}

print_outputs() {
  cat <<EOF

GitHub configuration:
  secret AWS_ROLE_TO_ASSUME=arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CONTROL_PLANE_ROLE_NAME}
  var AWS_REGION=${AWS_REGION}
  var AWS_INSTANCE_PROFILE_NAME=${BUILDER_INSTANCE_PROFILE_NAME}

Still needed from your VPC:
  var AWS_SUBNET_ID=<subnet with outbound internet/NAT>
  var AWS_SECURITY_GROUP_ID=<security group with outbound internet>

Attic:
  secret ATTIC_TOKEN=<token>
  var ATTIC_ENDPOINT=<endpoint>
  var ATTIC_CACHE=<cache name>

AWS profile used:
  ${AWS_PROFILE}
EOF
}

AWS_ACCOUNT_ID="$(aws_cli sts get-caller-identity --query 'Account' --output text)"

ensure_oidc_provider
ensure_control_plane_role
ensure_builder_instance_role
print_outputs
