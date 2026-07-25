# CircleMUD single-instance EC2 deployment plan

## Outcome

Deploy the container in `week0_explore/infrastructure` as a small public
CircleMUD server on one EC2 instance. CloudFormation will provision the host
and its supporting AWS resources, while a repository script will validate and
deploy the stack through the AWS CLI.

The implementation will add:

- `week0_explore/infrastructure/cloudformation.yml`
- `week0_explore/infrastructure/bin/deploy`
- deployment and operations instructions in
  `week0_explore/infrastructure/README.md`

This plan intentionally stops short of implementing those files until it has
been reviewed.

## Current state

The existing infrastructure directory contains:

- a multi-stage Debian image that builds tbaMUD and listens on TCP port 4000;
- an entrypoint that seeds `/opt/circlemud/lib` on first startup;
- a Compose service with `restart: unless-stopped`;
- a host bind mount from `./lib` to `/opt/circlemud/lib`;
- a reset script that edits that host-side game data.

The `lib` directory is deliberately gitignored. A remote server must therefore
create its own persistent data directory and allow the container entrypoint to
seed it.

## Proposed architecture

```text
MUD client
    |
    | TCP 4000
    v
Elastic IP
    |
EC2 security group
    |
Amazon Linux 2023 EC2 instance
    |
Docker container: circlemud
    |
/srv/circlemud/lib (host data)
```

CloudFormation will create:

1. **EC2 security group**
   - Allow inbound TCP 4000 from a configurable CIDR.
   - Default the CIDR to `0.0.0.0/0` because this is a public game server.
   - Do not open SSH.
   - Allow normal outbound traffic so the host can install Docker and clone the
     repository.

2. **IAM role and instance profile**
   - Attach `AmazonSSMManagedInstanceCore` so the instance can be administered
     with AWS Systems Manager Session Manager instead of an SSH key.
   - Add no application-specific permissions.

3. **EC2 instance**
   - Use the current Amazon Linux 2023 x86-64 AMI through the AWS-owned SSM
     public parameter, avoiding a region-specific hard-coded AMI.
   - Default to a low-cost `t3.micro`, with the instance type exposed as a
     parameter.
   - Require a VPC and public subnet as parameters. This keeps the template
     compatible with the account's default VPC or a user-selected VPC and
     avoids creating an entire network for one server.
   - Enable detailed resource tags and IMDSv2.
   - Use an encrypted gp3 root disk with a configurable size.
   - Bootstrap Docker and Git in `UserData`, enable Docker at boot, and prepare
     `/srv/circlemud/lib`. The deploy script will then install the requested
     application revision through SSM and run it with:
     - port `4000:4000`;
     - restart policy `unless-stopped`;
     - `/srv/circlemud/lib:/opt/circlemud/lib`;
     - a stable container and image name.
   - Write bootstrap output to the normal cloud-init log and fail early on
     errors.

4. **Elastic IP**
   - Associate a stable public IPv4 address with the instance.
   - Output both the address and a ready-to-use `telnet` command.

The server will persist game data across container rebuilds, host reboots, and
repeated in-place stack deployments. Because it uses the instance's root EBS
volume, replacing or deleting the EC2 instance is not a durable backup
strategy. See “Data durability” below.

## CloudFormation interface

The template will expose these parameters:

| Parameter | Purpose | Proposed default |
| --- | --- | --- |
| `VpcId` | VPC containing the server | no default |
| `SubnetId` | public subnet with an internet route | no default |
| `AllowedCidr` | clients allowed to reach TCP 4000 | `0.0.0.0/0` |
| `InstanceType` | EC2 size | `t3.micro` |
| `RootVolumeSize` | encrypted gp3 disk size in GiB | `12` |

The template will output:

- stack name;
- instance ID;
- Elastic IP;
- public game endpoint;
- Session Manager command;
- CloudWatch console/log troubleshooting hint if practical without adding a
  log agent.

The template will use standard parameter types such as
`AWS::EC2::VPC::Id` and `AWS::EC2::Subnet::Id`, parameter validation where
available, and `AWS::CloudFormation::Init`/resource signaling only if bootstrap
reliability cannot be kept clear with a compact `UserData` script. The
implementation should prefer the least complex mechanism that still lets stack
creation report a failed bootstrap instead of claiming success.

## Deployment script

`week0_explore/infrastructure/bin/deploy` will be a Bash script using
`set -euo pipefail`. It will:

1. Resolve the repository root independently of the caller's working
   directory.
2. Verify required commands (`aws`, `git`) and that AWS credentials work.
3. Refuse to deploy an uncommitted infrastructure change, because the EC2 host
   deploys a Git commit and cannot see uncommitted local files.
4. Resolve the current commit SHA and pass it to the remote deployment command
   as the immutable repository ref.
5. Accept configuration through explicit environment variables:
   - `AWS_REGION` (or the AWS CLI configured region);
   - `STACK_NAME`, default `circlemud`;
   - `VPC_ID`;
   - `SUBNET_ID`;
   - optional `ALLOWED_CIDR`;
   - optional `INSTANCE_TYPE`;
   - optional `ROOT_VOLUME_SIZE`;
   - optional `REPOSITORY_URL`.
6. Validate that the selected subnet belongs to the selected VPC and that a
   region is available before starting a deployment.
7. Run `aws cloudformation validate-template`.
8. Run `aws cloudformation deploy` with IAM capability acknowledgement and
   the resolved parameters.
9. Use SSM Run Command to fetch the requested commit, rebuild the image, and
   replace the running container without replacing the host or its data.
10. Wait for completion, print useful CloudFormation events or SSM output if a
    step fails, and print the stack outputs on success.

The script will not commit or push code. Its README instructions will make the
contract explicit: the selected commit must be reachable from the configured
HTTPS repository before deployment. This also avoids introducing ECR or an S3
artifact bucket for a single experimental server.

## Bootstrap and update behavior

Cloud-init runs only when an instance is first created, so it cannot perform
repeat application deployments. The deploy script will therefore use the same
post-stack SSM deployment for both create and update:

- On initial creation, CloudFormation `UserData` installs Docker and prepares
  the host.
- After every CloudFormation create or update, the script sends a versioned
  deployment command through SSM. That command clones or fetches the repository
  at the requested commit, builds a new image, stops and replaces the old
  container only after a successful build, and keeps `/srv/circlemud/lib`
  untouched.
- The script waits for the SSM command and treats a failed or timed-out command
  as a failed deployment.

The changing Git ref will not be a CloudFormation parameter or part of
`UserData`, so routine application deployments do not alter or replace the
instance. Infrastructure changes that inherently require EC2 replacement
remain a maintenance event and require a snapshot/restore of the game data.

## Data durability

The root disk will be encrypted and configured not to be modified by routine
application deployments. `/srv/circlemud/lib` will be the only path bind
mounted into the container for mutable game state.

This protects player and world state from container replacement and reboots,
but not from EC2 replacement or stack deletion. Automated EBS snapshots and a
standalone data volume are out of scope for the initial simple template. The
README will:

- call out the limitation prominently;
- include a manual snapshot command;
- document how to restore the data to a replacement server;
- identify a separate EBS volume or AWS Backup as the production follow-up;
- warn that snapshots and retained volumes continue to incur AWS charges.

## Security and operational defaults

- Publicly expose only TCP 4000.
- Use Session Manager; do not create port 22 ingress or require an EC2 key
  pair.
- Require IMDSv2.
- Encrypt EBS storage.
- Grant the instance only SSM permissions.
- Avoid secrets in parameters, `UserData`, and stack outputs.
- Pin deployments to a full Git commit SHA rather than a mutable branch.
- Configure Docker to restart the MUD after process failure or reboot.
- Tag resources with the stack/application name.

The server speaks classic telnet rather than TLS. The README will state that
game credentials and traffic are not encrypted in transit and should not be
reused for sensitive accounts.

## Documentation changes

Update `week0_explore/infrastructure/README.md` with:

- AWS prerequisites and approximate resources created;
- public-subnet and outbound-internet requirements;
- first deployment example;
- environment-variable reference;
- how to connect on port 4000;
- how to inspect CloudFormation events and cloud-init logs;
- how to use Session Manager;
- how to view container logs and restart the service;
- how repeat deployments work;
- how data is persisted, snapshotted, retained, and eventually removed;
- how to delete the stack and separately delete any retained EBS volume;
- the unencrypted telnet warning.

## Validation

Before considering the implementation complete:

1. Run a YAML parser or `cfn-lint` when available.
2. Run `aws cloudformation validate-template`.
3. Run `shellcheck` on `bin/deploy` when available and at minimum
   `bash -n`.
4. Confirm the template contains no SSH ingress and restricts public ingress
   to the configured CIDR and TCP 4000.
5. Deploy to a test stack.
6. Confirm Docker is installed and enabled.
7. Confirm the container is healthy/running and restarts after an EC2 reboot.
8. Connect to the Elastic IP on port 4000 and reach the MUD greeting.
9. Create test player state, redeploy the same stack, and confirm the state
   remains.
10. Confirm the second deployment runs through SSM without replacing the
    instance.
11. Confirm Session Manager access works and port 22 remains closed.
12. Take a manual snapshot, then delete the test stack and verify the
    documented deletion behavior.

Steps that create AWS resources will incur charges and will only be run with
the account, region, VPC, and subnet explicitly selected by the user.

## Acceptance criteria

- One command deploys or updates the CloudFormation stack.
- The stack runs the existing CircleMUD Docker image on one EC2 instance.
- The game is reachable at a stable public IPv4 address on TCP 4000.
- Docker and the container start automatically after a reboot.
- Game data survives a normal redeploy; the exact guarantees around instance
  replacement are implemented and documented.
- No SSH port is exposed.
- The deployed code is traceable to an exact Git commit.
- The deploy script fails with actionable errors for missing configuration,
  unavailable AWS credentials, invalid networking, dirty infrastructure
  changes, or failed stack creation.

## Decisions to confirm

The defaults below will be used unless review changes them:

1. Deploy into an existing VPC and public subnet rather than creating a VPC.
2. Allow game traffic from the whole internet (`0.0.0.0/0`) by default.
3. Use Amazon Linux 2023 and a `t3.micro`.
4. Use Session Manager and expose no SSH.
5. Deploy a reachable Git commit directly on the instance rather than adding
   ECR.
6. Keep game data on the encrypted root volume and use SSM for in-place
   application updates; snapshots are required before instance replacement.
7. Allocate an Elastic IP; note that AWS public IPv4 addresses incur hourly
   charges.
