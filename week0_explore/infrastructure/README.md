# CircleMUD infrastructure

This setup builds tbaMUD, CircleMUD's official successor, and runs it on port
4000. It supports local Docker Compose development and a public single-instance
AWS deployment.

## Run locally

```sh
docker compose up --build
```

Connect with a MUD client, telnet, or netcat:

```sh
telnet localhost 4000
```

The local `lib` directory stores persistent game data, including player files
and world state.

## Deploy to AWS

The CloudFormation deployment creates:

- one Amazon Linux 2023 EC2 instance with Docker;
- an encrypted gp3 root volume;
- an Elastic IP;
- a security group exposing only TCP port 4000;
- an IAM role for Systems Manager Session Manager and Run Command.

SSH is not exposed. The instance needs a public subnet with a route to an
internet gateway so it can install packages, reach Systems Manager, and clone
the public Git repository.

AWS charges apply to the EC2 instance, EBS volume, and public IPv4 address.

### Prerequisites

- AWS CLI v2 installed and authenticated
- [`cfn-toml`](https://github.com/teacherseat/cfn-toml), installed with
  `gem install cfn-toml`
- permission to manage CloudFormation, EC2, IAM, and Systems Manager resources
- an existing VPC and public subnet
- the deployment commit pushed to the public Git repository
- `telnet`, `nc`, or a MUD client for testing

The deploy script intentionally rejects uncommitted changes under this
directory because the server checks out an exact Git commit.

### Configure the deployment

Copy the sample configuration:

```sh
cp week0_explore/infrastructure/conf.toml.example \
  week0_explore/infrastructure/conf.toml
```

Edit `conf.toml` and fill in the AWS profile, region, VPC ID, and public subnet
ID. The local file is ignored by Git. `cfn-toml` converts its `[parameters]`
table into CloudFormation parameter overrides.

The configuration has these fields:

| TOML key | Sample | Purpose |
| --- | --- | --- |
| `deploy.profile` | `default` | AWS CLI profile |
| `deploy.region` | `ca-central-1` | AWS region |
| `deploy.stack_name` | `circlemud` | CloudFormation stack name |
| `deploy.repository_url` | repository HTTPS URL | Source repository |
| `parameters.VpcId` | `vpc-...` | Existing VPC |
| `parameters.SubnetId` | `subnet-...` | Existing public subnet |
| `parameters.AllowedCidr` | `0.0.0.0/0` | Clients allowed on port 4000 |
| `parameters.InstanceType` | `t3.micro` | EC2 size |
| `parameters.RootVolumeSize` | `12` | Root disk size in GiB |

You can keep multiple configurations outside the repository and select one
with `CFN_CONFIG`:

```sh
CFN_CONFIG=/path/to/circlemud.production.toml \
  week0_explore/infrastructure/bin/deploy
```

### Deploy

```sh
week0_explore/infrastructure/bin/deploy
```

The script validates the template and subnet/VPC relationship, deploys the
stack, waits for Systems Manager, and deploys the current Git commit using Run
Command. Repeat the same command after pushing another commit. Application
updates rebuild and replace only the container; they do not replace the EC2
instance.

### Connect

The successful deployment prints the public endpoint and a telnet command. You
can retrieve them later with:

```sh
config=week0_explore/infrastructure/conf.toml
aws_profile="$(cfn-toml key deploy.profile --toml "$config")"
aws_region="$(cfn-toml key deploy.region --toml "$config")"
stack_name="$(cfn-toml key deploy.stack_name --toml "$config")"

aws cloudformation describe-stacks \
  --profile "$aws_profile" \
  --region "$aws_region" \
  --stack-name "$stack_name" \
  --query 'Stacks[0].Outputs' \
  --output table
```

Connect using the `ElasticIp` output:

```sh
telnet ELASTIC_IP 4000
```

CircleMUD uses classic telnet. Traffic, including game passwords, is not
encrypted. Do not reuse a sensitive password.

## Operations

Start an administrative shell without opening SSH:

```sh
instance_id="$(aws cloudformation describe-stacks \
  --profile "$aws_profile" \
  --region "$aws_region" \
  --stack-name "$stack_name" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue | [0]" \
  --output text)"

aws ssm start-session \
  --profile "$aws_profile" \
  --target "$instance_id" \
  --region "$aws_region"
```

Useful commands on the instance:

```sh
sudo docker logs --tail 200 circlemud
sudo docker restart circlemud
sudo docker inspect circlemud
sudo tail -n 200 /var/log/circlemud-bootstrap.log
sudo tail -n 200 /var/log/cloud-init-output.log
```

Mutable game data lives at `/srv/circlemud/lib` on the host and is bind-mounted
at `/opt/circlemud/lib` in the container. It survives container replacements
and normal instance reboots.

### Troubleshooting a failed stack

```sh
aws cloudformation describe-stack-events \
  --profile "$aws_profile" \
  --region "$aws_region" \
  --stack-name "$stack_name" \
  --query 'StackEvents[].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
  --output table
```

If stack creation times out while creating `CircleMudInstance`, verify that the
subnet has an internet-gateway route and permits outbound HTTPS. The instance
must download Amazon Linux packages and communicate with CloudFormation and
Systems Manager.

### Snapshot game data

Game data is stored on the instance's root EBS volume. Take a snapshot before
an infrastructure change that could replace the instance:

```sh
instance_id="$(aws cloudformation describe-stacks \
  --profile "$aws_profile" \
  --region "$aws_region" \
  --stack-name "$stack_name" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue | [0]" \
  --output text)"

volume_id="$(aws ec2 describe-instances \
  --profile "$aws_profile" \
  --region "$aws_region" \
  --instance-ids "$instance_id" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text)"

aws ec2 create-snapshot \
  --profile "$aws_profile" \
  --region "$aws_region" \
  --volume-id "$volume_id" \
  --description "CircleMUD data before maintenance"
```

Snapshots are point-in-time disk backups and incur storage charges. Stop the
container first if a fully application-consistent snapshot is required. For a
long-lived server, move `/srv/circlemud` to a separate EBS volume or configure
AWS Backup.

### Delete the server

Deleting the stack permanently deletes its root EBS volume and game data.
Create and verify a snapshot first if the data matters.

```sh
aws cloudformation delete-stack \
  --profile "$aws_profile" \
  --stack-name "$stack_name" \
  --region "$aws_region"

aws cloudformation wait stack-delete-complete \
  --profile "$aws_profile" \
  --stack-name "$stack_name" \
  --region "$aws_region"
```
