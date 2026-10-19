# AWS Platform

**English** | [简体中文](README.zh-CN.md)

A native macOS app for browsing AWS resources and costs, with explicit S3 file transfers and external EC2 SSM connections, built with SwiftUI.

## Download

[Version 0.4.1](https://github.com/maydaychen/aws-platform/releases/tag/v0.4.1) requires **macOS 13 or later**. Choose the package for your Mac:

| Mac | Installer | Archive |
| --- | --- | --- |
| Apple Silicon (M-series, `arm64`) | [DMG](https://github.com/maydaychen/aws-platform/releases/download/v0.4.1/AWSPlatform-0.4.1-arm64.dmg) | [ZIP](https://github.com/maydaychen/aws-platform/releases/download/v0.4.1/AWSPlatform-0.4.1-arm64.zip) |
| Intel (`x86_64`) | [DMG](https://github.com/maydaychen/aws-platform/releases/download/v0.4.1/AWSPlatform-0.4.1-x86_64.dmg) | [ZIP](https://github.com/maydaychen/aws-platform/releases/download/v0.4.1/AWSPlatform-0.4.1-x86_64.zip) |

Open the DMG and drag AWSPlatform to Applications, or extract the ZIP. Both builds are Developer ID signed and notarized by Apple. [SHA-256 checksums](https://github.com/maydaychen/aws-platform/releases/download/v0.4.1/SHA256SUMS.txt) are available with the release. AWS CLI v2 is required for SSO sign-in; see [Prerequisites](#prerequisites).

## Features

- **EC2 instances** - View instance state, networking, AMIs, and tags; open an SSM session in an external terminal with Connect
- **EC2 resource group** - Expand or collapse instances, Auto Scaling groups, EBS volumes, snapshots, load balancers, Target Groups, and security groups; browse current-account EBS volumes and owned snapshots with search, state filters, favorites, and recent visits
- **Lambda functions** - View function configuration and source code from deployment packages
- **Metrics and logs** - Manually query CloudWatch metrics for EC2, Lambda, and RDS, and logs for the current Lambda function, with time ranges, log filters, and pagination
- **S3 buckets** - Browse bucket security settings, objects, and folders with clickable breadcrumbs and on-demand pagination; inspect an object's versions and delete markers; upload or download individual files with progress and cancellation
- **CloudWatch** - Browse Alarms and Logs in an expandable sidebar group, with Metric/Composite Alarms, log groups and streams, and manually paginated log events in the current Region
- **SNS topics** - Browse Standard and FIFO Topics, attributes, policies, tags, and subscriptions, with subscription endpoints hidden by default
- **CodeCommit** - Inspect repositories, branches, and branch-head commits; manually browse files at a fixed commit SHA, changed paths with before/after previews, and pull requests
- **RDS** - Browse DB instances and clusters, metadata, and members; manually load applicable metrics, the last 14 days of database events, and owned snapshots
- **EC2 Auto Scaling** - Inspect groups, capacity, members, policies, and scaling activities; manually read referenced launch template versions and instance refresh history, and open member EC2 instances
- **Route 53** - Browse public and private Hosted Zones, DNS record sets, delegation name servers, VPC associations, and tags for the current account
- **Load balancing** - Browse ALB, NLB, GWLB, listeners, ALB rules, Target Groups, and target health; follow resource links and manually find an EC2 instance's registered Target Groups
- **Security groups** - Browse visible groups, owners, VPCs, tags, and inbound/outbound rules in the current Profile and Region
- **Resource relationships** - Explore Route 53 records, load balancers, Target Groups, EC2 instances, and security groups one hop at a time, with explicit reverse queries and precise resource navigation
- **AWS Health events** - Switch between current-account and organization events using the current Profile, with account filtering, event descriptions, and affected resources
- **Separate Session and Profile selection** - Sign in to a session, then manually choose an associated Profile and Region; resource views stay empty until a Profile is selected
- **On-demand resource loading** - After Profile verification, only the visible module loads, including EC2, Lambda, and S3. Other modules load when selected; returning within the same scope reuses results. Use Refresh to retry empty, failed, or cancelled loads; changing Profile or Region clears the previous regional results
- **Searchable Profiles** - Search Profile names, account IDs, and roles within the selected session
- **SSO login** - Click `SSO Login` in the app to authorize a session through your browser, or reuse a login cached by the CLI
- **Cost dashboard** - View current-month and previous-month costs, daily trends, and service breakdowns for the current Profile's account, with independent date and billing Region filters, in-memory caching, and manual refresh
- **Resource favorites** - Save EC2 instances, Auto Scaling groups, EBS volumes/snapshots, Lambda functions, S3 Buckets, CloudWatch Alarms, SNS Topics, CodeCommit repositories, RDS databases, Route 53 Hosted Zones, load balancers, Target Groups, and security groups locally; reopen them within the current Profile, restoring the saved Region for regional resources
- **Recent resources** - Reopen recently viewed resources in the current Profile and account, with local history, search, and scoped deletion
- **Interface language** - Follow the system language, or choose Simplified Chinese or English; switch instantly without reloading AWS data
- **Native desktop layout** - A full-width Session/Profile/Region bar gives extra space to Profile and moves Region to a second row when space is limited; Region names include codes, with a shared scrolling workspace/service sidebar, aligned EC2 overview fields, and system-aware light and dark themes

The app does not create, modify, or delete resources, or invoke Lambda functions.

Read queries can still incur AWS charges. See [AWS query costs](docs/aws-query-costs.md) for CloudWatch metrics, S3 LIST requests, CodeCommit access, and the distinction between ordinary log reads and Logs Insights.

The following component previews use mock resources:

![EC2 overview in light mode](docs/ui-overview-light.png)

![Lambda code view in dark mode](docs/ui-code-dark.png)

The following header previews use mock profiles and show the wide and narrow window layouts:

![Full-width Session/Profile bar](docs/ui-profile-header-wide-dark.png)

![Region moves to a second row in a narrow window](docs/ui-profile-header-narrow-dark.png)

## Technology Stack

- Swift 6.2+ / SwiftUI (toolchain required to build from source)
- macOS 13+, supporting Intel (x86_64) and Apple Silicon (arm64)
- [Soto](https://github.com/soto-project/soto) - AWS SDK for Swift
- [Sparkle 2](https://sparkle-project.org/) - Signed application updates

## Quick Start

### Prerequisites

- macOS 13.0+ to run the app
- A full Xcode installation with Swift 6.2+ to build from source; the build machine must meet that Xcode version's macOS requirements
- AWS CLI configuration (`~/.aws/config` and `~/.aws/credentials`)
- For SSO, configure a named `sso-session` and install AWS CLI v2. Click `SSO Login` in the app or run `aws sso login --sso-session <name>` in a terminal. Browsing resources also requires a Profile that references the session
- AssumeRole Profiles with `role_arn` also require AWS CLI v2. The role and `source_profile` can be declared only in config, with credentials stored only under the source Profile. The app exports temporary credentials through a bounded memory pipe, then verifies the target account and role; it does not write credentials or duplicate Profile sections

On Apple Silicon, use an AWS CLI version that runs natively. Starting with version 2.30.0, AWS CLI v2 provides an [official Universal installer](https://aws.amazon.com/blogs/devops/introducing-universal-installers-for-aws-cli-v2-on-macos/) for both Intel and Apple Silicon; older Intel-only versions cannot run on Apple Silicon without Rosetta.

### Build and Run

```bash
# Clone the repository
git clone https://github.com/maydaychen/aws-platform.git
cd aws-platform

# Build
swift build

# Run
swift run

# Test
swift test
```

### Xcode

```bash
open Package.swift
```

Press Cmd+R in Xcode to run the app.

The package manifest declares Swift tools 5.9, but some dependencies currently pinned in `Package.resolved` require Swift 6.2+. Use a toolchain that meets this requirement.

### Package a Universal App

Select a full Xcode toolchain with Swift 6.2+, then run this command from the repository root:

```bash
./scripts/build-universal.sh
```

The script uses the dependencies pinned in `Package.resolved`, builds Release versions for Intel and Apple Silicon, and combines them into a Universal app. It produces:

- `dist/AWSPlatform.app`: an app for both architectures on macOS 13 or later, ready to copy to the Applications folder.
- `dist/AWSPlatform-universal.zip`: an archive containing the app.

Packaged apps include the cloud resource icon from `Assets/AppIcon/AppIcon.icns`. To update the PNG master and regenerate its macOS icon sizes, see the [App Icon instructions](Assets/AppIcon/README.md).

These local builds use ad-hoc signing. Both packaging scripts accept `--architecture arm64` for Apple Silicon, `--architecture x86_64` for Intel, or `--architecture universal` (the default) for both. Single-architecture builds contain only that architecture, including embedded Swift runtime libraries. Use separate `--output-dir` directories when keeping multiple local builds. Version and build number can be set with `--version` and `--build-number`.

For distribution, use `scripts/package-distribution.py` with the same architecture/version options to sign with a local Developer ID Application identity, notarize with Apple, and staple the tickets. It produces versioned ZIP and DMG files named `AWSPlatform-<version>-<architecture>`, checksums, and notarization records. A valid signing identity and configured `asc` authentication are required; see the [distribution packaging instructions (Chinese)](scripts/README.md#正式签名与公证). A regular `swift build` still builds only for the current machine's architecture.

### Application Updates

Installers from `v0.3.1` onward provide **AWSPlatform → Check for Updates…** and an **Updates** section in Settings. Automatic checks are off by default; enabling them checks for new releases without automatically downloading or installing them. Installation requires confirmation and waits for S3 transfers across the app's windows to actually finish, including tasks whose cancellation was requested. New transfers are paused while a restart is pending. Close any separately launched app instances before updating.

Apple Silicon and Intel use separate HTTPS feeds selected by the running app architecture. Updates require an Ed25519-signed feed and verify the final ZIP before extraction, retaining the existing bundle identity and local preferences. Feed verification failures stop the update; signatures authenticate content but do not guarantee that the server provides the newest release. If the signing key is lost, recovery requires a manually installed release with a reviewed new key. Version `v0.3.0` and earlier predate this updater. Install `v0.3.1` manually to enable future in-app updates. Release packaging and feed generation are described in the [packaging guide](scripts/README.md#应用更新与发布清单).

### Window Controls

`Cmd+W` closes the current window while the app keeps running. Click the Dock icon or reopen the app to restore a window when all windows are closed. Use **File → New Window** (`Cmd+N`) to open another resource window.

### Interface Language

The sidebar footer displays the running application's version and build number, using the same bundle information as Settings.

Open `Settings` at the bottom of the sidebar or press `Cmd+,`. Choose `Follow System`, `简体中文`, or `English`. The choice is saved locally and applies immediately to every open app window. Unsupported system languages fall back to English.

Changing the language preserves the selected Session, Profile, Region, filters, resources, and loaded results. It does not log in, validate credentials, or send AWS requests. Service names, resource names, IDs, ARNs, AWS tags, logs, and event descriptions retain their original content. Native macOS menu labels follow the system language.

For contributor guidance on display strings and resource packaging, see [Localization](docs/localization.md).

### EC2 Status Checks

The basic instance list appears before AMI names and status checks finish. Names and checks load independently, and checks cover all listed instances without requiring selection. The app reads every status page in the selected Profile and Region, then makes one bounded follow-up pass for missing instances while retaining successful results. A green check means checks passed, an orange triangle needs attention, and an orange question mark means the checks could not be read; the row tooltip and list warning show the reason. Refresh retries the checks. A gray minus means checks are not applicable. Running state remains a separate indicator.

### EC2 and Lambda Detail Loading

Selecting a resource first loads its basic configuration. EC2 Storage, Security, and Status details load on first entry to those tabs; the overview retains networking and applicable CPU Credit information. Lambda policy, triggers, and versions load when their respective Configuration, Triggers, and Versions tabs are opened. Returning to a loaded tab reuses its result; a failed read can be retried without clearing the overview. Partial Lambda permissions preserve readable components and identify failed components separately. Changing the resource, Profile, or Region invalidates old responses. Metrics, logs, registered Target Groups, and source downloads retain their explicit query controls.

### EC2 CPU Credit Mode

The `Compute and capacity` section of a T-series instance's overview shows its current `Standard` or `Unlimited` CPU Credit mode. This requires `ec2:DescribeInstanceCreditSpecifications` in the selected Profile and Region. Permission denial and read failure are shown separately from an unknown or missing response; other instance families do not query or display this field. The app only reads the mode. See the [AWS API reference](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_DescribeInstanceCreditSpecifications.html).

### EC2 SSM Connect

Select and verify a Profile, select its Region, then open a running EC2 instance and click `Connect` in the detail header. AWSPlatform opens a private, one-time `.command` script using the system's default file association; use a terminal application as the default opener for `.command` files. There is no embedded terminal or terminal preference page. The external terminal owns the session, and changing the Profile or closing AWSPlatform does not end an already handed-off session.

Install AWS CLI v2 in `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`, and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-macos-overview.html) in `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/local/sessionmanagerplugin/bin`. Connect checks for executable files; installation and runtime failures remain visible in the terminal. The instance needs a working SSM Agent, instance permissions, and connectivity to Systems Manager; the selected role needs [Session Manager permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-restrict-access-quickstart.html). A running EC2 instance alone does not prove SSM availability.

The script resolves credentials once through AWS CLI using the selected Profile and configuration paths. It checks the account and normalized principal ARN, then starts SSM with the same in-memory credentials and selected Region. These two calls do not reread the Profile or shared configuration. Credentials are never written to the script, disk, command arguments, logs, or terminal history. Expired login, missing permissions, and offline SSM targets are reported by the CLI. Scripts are removed when execution exits or handoff fails; if the associated app never executes a script, it can remain in the private system temporary directory. The app does not install agents or change IAM/SSM configuration. See [start-session](https://docs.aws.amazon.com/cli/latest/reference/ssm/start-session.html).

### EC2 Navigation, EBS Volumes, and Snapshots

The EC2 sidebar group contains `Instances`, `Auto Scaling`, `EBS Volumes`, `Snapshots`, `Load balancers`, `Target groups`, and `Security groups`. Its expansion preference is saved locally. Collapsing the group keeps the current page and shows its name beneath EC2; opening a saved or related resource reveals its child entry. Existing EC2 favorites and startup service preferences retain their original identifiers.

After selecting and verifying a Profile, EBS pages query that Profile's current Region. Volumes include attached and unattached volumes; details show size, type, state, encryption, KMS key, source snapshot, attachments, and tags when returned. Snapshot requests always use `OwnerIds=self`; the page lists only snapshots owned by the current account, including archived snapshots, and shows source volume, progress, storage tier, description, and tags. Shared and public snapshots are excluded. Both lists use complete pagination, local search and state filters, manual refresh/cancel, favorites, and recent visits. Scope changes clear old data; a failed refresh labels a retained list as potentially out of date.

Required read permissions are `ec2:DescribeVolumes` and `ec2:DescribeSnapshots`. Permission, expired credentials, network, and incomplete-pagination errors produce explicit messages. The app does not create, attach, detach, restore, modify, share, or delete volumes or snapshots. See [DescribeVolumes](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_DescribeVolumes.html) and [DescribeSnapshots](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_DescribeSnapshots.html).

### CodeCommit Queries

Select and verify a Profile, choose a Region, then open **CodeCommit** in the sidebar. The repository list loads all pages and supports local name/ID search, refresh, and cancellation. Select a repository to read its metadata and branches independently; a permission failure in one section leaves the other available. The default branch is selected only when returned by repository metadata and present in the branch list. Empty repositories do not trigger commit queries.

The overview includes repository metadata, clone URLs, and the selected branch's last queried head commit with SHA, message, author, committer, raw Git timestamps, and parent SHAs. Refresh the branch head to check for changes. Repositories support favorites and recent visits using their repository UUID within the verified Profile/account/Region.

Use `Source files` to enter a full 40-character commit SHA and repository folder path, then load folders and select files. Previews are fixed to that commit and limited to 512 KiB and 5,000 lines; binary and non-UTF-8 content is not previewed. `Commit differences` manually compares fixed before/after SHAs, listing added, deleted, or modified paths with separate before/after content previews rather than a line diff. Leave the before SHA empty to list files at the after commit. `Pull requests` loads open, closed, or all request IDs; click an ID to read its metadata, description, and source/destination references and commits. Content is never executed or saved as local files. Switching scope or repository invalidates previous content requests; each query is initiated manually, without polling.

Required permissions are `codecommit:ListRepositories` on `"*"`, plus `codecommit:GetRepository`, `codecommit:ListBranches`, `codecommit:GetBranch`, `codecommit:GetCommit`, `codecommit:GetFolder`, `codecommit:GetFile`, `codecommit:GetDifferences`, `codecommit:ListPullRequests`, and `codecommit:GetPullRequest` for the allowed repositories. Encrypted repositories also depend on the relevant KMS key permissions/status. CodeCommit remains read-only, without clone/push, file editing, or pull request creation/merge. Repository access may incur active-user, request, or KMS charges; see [AWS query costs](docs/aws-query-costs.md) and the [AWS CodeCommit permissions reference](https://docs.aws.amazon.com/codecommit/latest/userguide/auth-and-access-control-permissions-reference.html).

### RDS Queries

Open **RDS** after selecting and verifying a Profile and choosing a Region. DB instances and clusters load independently with complete pagination; a failed instance or cluster query leaves the other list available. Search identifiers, ARNs, engines, and endpoints locally, or filter by resource type. Select a database to view the returned metadata. Refresh reloads both lists; cancellation preserves already completed results. Scope changes clear old data and reject late responses. Instances and clusters support favorites and recent visits by ARN.

The overview uses `rds:DescribeDBInstances` and `rds:DescribeDBClusters`, including their returned tags, and excludes shared clusters, Neptune, and DocumentDB. Details include engine/version/status, instance class, endpoints/port, availability, subnet group/security groups, storage/encryption, backup retention, deletion protection, cluster members, and Serverless v2 capacity when returned. Instance responses can include VPC/subnet IDs; cluster responses supply the subnet group name without VPC/subnet details. Missing values remain unknown. An engine mode of `provisioned` does not rule out Serverless v2.

The detail tabs load only when requested. `Metrics` reads instance CPU utilization, connections, freeable memory, read/write latency, and non-Aurora instance free storage space. Aurora cluster metrics show volume bytes used and read/write I/O operations; CPU, memory, and connections belong to member instances. Other clusters, including Multi-AZ DB clusters, direct you to member-instance metrics. `Events` reads the selected instance or cluster's last 14 days. `Snapshots` lists automatic/manual snapshots owned by the current account for that database, excluding shared/public snapshots; listing does not create a backup or verify restoration.

These tabs additionally require `cloudwatch:GetMetricData`, `rds:DescribeEvents`, and the applicable `rds:DescribeDBSnapshots` or `rds:DescribeDBClusterSnapshots`. Metrics queries can incur charges; see [AWS query costs](docs/aws-query-costs.md). The app does not connect to databases, execute SQL, enable monitoring/log export, create/restore snapshots, or modify RDS resources. See [DescribeDBInstances](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_DescribeDBInstances.html), [DescribeDBClusters](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_DescribeDBClusters.html), and the [RDS IAM action reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_rds.html).

### EC2 Auto Scaling

Open **EC2 → Auto Scaling** after selecting and verifying a Profile and choosing a Region. The group list loads all pages and supports local search, refresh, and cancellation without automatically selecting a group. Details include capacity values and type, regular member count, AZs/subnets, launch configuration/template and mixed-instance summaries, health settings, suspended processes, load-balancer associations, members, and tags. Capacity values may represent weighted, vCPU, or memory units rather than instance counts. Missing values remain unknown; template aliases such as `$Latest` are preserved, and group operation status is not interpreted as health.

Selecting a group independently loads scaling policy summaries and activities from the last six weeks. The detail refresh button reloads these two sections; use list refresh to reload group metadata. One section's failure leaves the other readable. Manually load launch template versions referenced by the group, including mixed-instance/override references, while preserving aliases such as `$Latest` and `$Default`. The app displays returned configuration fields without resolving SSM AMI aliases or exposing UserData. Separately load instance refresh records from the last six weeks; records with an unknown start time remain visible. There is no polling, and the app does not initiate or cancel an AWS instance refresh. Member links open the exact EC2 instance within the same verified scope. Groups support favorites and recent visits by ARN.

Profile, identity, Region, or group changes invalidate old responses. The app does not query warm-pool members, ASG metrics, or full advanced metric/predictive policy configurations, and does not change capacity or execute scaling actions. Required permissions are `autoscaling:DescribeAutoScalingGroups`, `autoscaling:DescribePolicies`, and `autoscaling:DescribeScalingActivities` on `"*"`; the new detail queries additionally use `ec2:DescribeLaunchTemplateVersions` and `autoscaling:DescribeInstanceRefreshes`. Member navigation uses the existing `ec2:DescribeInstances` read permission. See [DescribeAutoScalingGroups](https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_DescribeAutoScalingGroups.html), [DescribePolicies](https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_DescribePolicies.html), [DescribeScalingActivities](https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_DescribeScalingActivities.html), and the [Auto Scaling IAM action reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_autoscaling.html).

### S3 Object Browsing

The Bucket list loads all pages for the current account, including accounts with an increased Bucket quota. It is not filtered by the selected browsing Region. A failed page does not produce a partial successful list.

Open a Bucket to load the first page of objects and folders (up to 1,000 entries per request). Click `Load more` to request the next page; the app does not automatically enumerate the whole directory. The footer counts loaded entries, and search only filters those entries in the current directory, not unloaded pages or subdirectories. A page with no visible entries can still have more pages.

Click `Root` or an ancestor in the breadcrumb bar to return to that directory; long paths scroll horizontally. Prefixes keep their literal slashes, spaces, Unicode, and percent characters. A failed next page keeps the existing list and offers `Retry`, except that access denial or a missing Bucket clears the old rows. Bucket browsing, details, and location requests require the current verified account to remain the Bucket owner. Refreshing, including after an upload, starts again at the first page; an uploaded key may be on a later page. Switching directory, Bucket, or Profile discards the previous pagination state and late results. Browsing uses `s3:ListBucket` and the existing Bucket Region lookup; LIST requests can incur S3 request charges. See [ListObjectsV2](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html).

### S3 Object Versions

Select an object and use `Object versions` in the toolbar or its context menu, then click `Load versions`. The sheet reads versions and delete markers for that exact key, up to 100 entries per requested page. Click `Load more` to continue; search covers loaded version IDs only, and partial lists are labeled. Version ID, latest flag, modification time, size, ETag, and storage class remain unknown when not returned. This is a version listing, without historical-version download, restore, deletion, or changes to versioning. Directory Buckets are not supported.

Queries use the verified Profile/account, the Bucket's actual Region, and the expected Bucket owner. They require `s3:ListBucketVersions`; an unknown Bucket Region additionally requires `s3:GetBucketLocation`. Scope, Bucket, prefix, or selected-object changes invalidate old pages. Each `ListObjectVersions` page can incur S3 LIST charges; existing version storage is billed separately. See [AWS query costs](docs/aws-query-costs.md).

### S3 File Transfers

When a download replaces an existing local file, an atomic exchange preserves the displaced file at a same-directory `AWSPlatform Recovery <UUID>` path. The completion status shows that path for copying; the app does not automatically delete recovery files. This also preserves edits made between the final file check and replacement. New destinations use an exclusive commit, and failure before commit leaves the original file intact. A filesystem that cannot perform the exchange rejects the overwrite.

Select and verify a Profile, open a Bucket, and browse its objects. `Upload File` selects one local file and uploads it under the current prefix using its filename. The app prepares a private temporary copy before showing confirmation; the upload uses that copy and its SHA-256 checksum. Preparation requires space for the file plus a 64 MiB reserve. Before any write, a confirmation shows the Profile, account, Bucket, complete key, local path, and size. A same-key object requires a separate `Overwrite` confirmation. New objects use `If-None-Match: *`; confirmed overwrites use the existing object's ETag with `If-Match`, so a concurrent change fails instead of silently replacing a newer object. Upload success refreshes the current prefix. Overwriting does not copy existing object metadata, tags, or ACLs; the new object uses this upload's parameters and Bucket defaults. Existing Bucket versioning, default encryption, and policies continue to apply; the app does not change that configuration.

You can also drag one local file from Finder into the object list, including an empty list. The highlighted drop target shows the current Bucket/prefix; dropping on a folder row still targets the directory currently being browsed. Dropping opens the same upload confirmation without a file picker. Multiple files, folders, symbolic links, and web links are not supported. A drop is disabled during another transfer or confirmation. Changing Profile or leaving the directory while the file URL is resolving discards that pending drop.

Download an object from its detail button or right-click menu, then choose a local destination in the macOS Save panel. The request uses the listed ETag with `If-Match`; changed or incomplete object metadata requires a list refresh. The app checks the response ETag and size, limits writes to that size, and preserves a 64 MiB disk reserve. It streams into a temporary file anchored to the selected destination directory and commits it only after the transfer completes; a replaced directory causes the save to fail. An interrupted or failed download removes the temporary file and preserves an existing local file; cancelling after completion cannot undo the saved file. Empty objects are supported; folders are not downloaded. S3 keys are never used as local filesystem paths.

Transfers use only the current verified Profile and the Bucket's actual Region. Switching or clearing the Profile, revalidating it, changing Region, or leaving the Bucket/prefix cancels pending work and invalidates old dialogs and results. Upload cancellation cannot undo a write AWS has already accepted; refresh to check the object. Files are streamed in bounded chunks, with progress and `Cancel`; single-file uploads are limited to 5 GiB. Each window runs one transfer at a time, without automatic retries.

Uploads require `s3:PutObject`; downloads and the ETag check for an overwrite require `s3:GetObject`. Bucket location lookup requires `s3:GetBucketLocation` when the actual Region is not already known. KMS-encrypted objects also require the appropriate key permissions. See [PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html), [GetObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html), and [SSE-KMS permissions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingKMSEncryption.html). Other services remain read-only, apart from explicitly initiated external EC2 SSM sessions. There are no separate object deletion, archive restore, ACL/tag editing, or Bucket configuration actions.

### Resource Favorites

Click `Add Favorite` at the top of a resource's details to save it, or `Remove Favorite` to remove it. The sidebar's `Favorites` view (`Cmd+Shift+F`) collects your favorites and supports searching by resource name, ID, service, Profile, account, or Region. Click an entry to open the resource; click its star or use the context menu to remove it.

Supported targets are EC2 instances, Auto Scaling groups, EBS volumes and snapshots, Lambda functions, S3 Buckets, CloudWatch Alarms, SNS Topics, CodeCommit repositories, RDS instances/clusters, Route 53 Hosted Zones, load balancers, Target Groups, and security groups. RDS and Auto Scaling use ARNs; CodeCommit uses the repository UUID. Log groups, object versions, repository files/commits/pull requests, and RDS snapshots are not separate saved targets.

Favorites appear only after you manually select a Profile. When opening a favorite, the app requires the current Profile to match the saved one, then restores the saved Region, verifies the account, and locates the resource. Opening a favorite never selects another Profile automatically. A missing or mismatched Profile, an account mismatch, a deleted resource, or an access failure produces a message without removing the favorite. S3 favorites store the browsing Region at the time they were saved; the existing loading flow resolves the bucket's actual location separately.

Favorites are stored locally in UserDefaults, restored after restart, and shared by windows within the same app process. Only the Profile name, account ID, Region, service, resource ID, and display name are saved. Credentials, resource details, and environment variables are not stored, and favorites are not synced to the cloud. The same resource is saved separately for different Profiles, accounts, or browsing Regions.

Route 53 Hosted Zones use a fixed `global` scope and the canonical Zone ID. Opening one leaves the resource Region unchanged and still reverifies the current Profile's account.

### Recent Resources

Open `Recent` in the sidebar (`Cmd+Shift+R`) after selecting and verifying a Profile. It shows only that Profile's current account, across browsing Regions, ordered by the most recent visit. The app keeps up to 50 entries per Profile/account for the same resource types supported by favorites, including EBS volumes/snapshots, CodeCommit repositories, RDS instances/clusters, and Auto Scaling groups. Entries are identified by service, resource ID, and saved Region (`global` for Route 53). Viewing the same entry again moves it to the top and updates its name and visit time. A resource counts as visited when its details are shown, including the visible first selection on a service page; background-loaded selections, S3 objects, log groups, individual DNS records, listeners, and rules are not recorded.

Search by name, resource ID, service, Profile, account, or Region. Click a row to reverify the account and locate the resource using the same navigation as favorites. Regional resources restore their saved Region; Route 53 keeps your resource Region unchanged. This never selects another Profile or adds a favorite. Missing resources, changed accounts, and access failures produce a message while preserving the history entry. You can remove individual entries or confirm `Clear history` to clear only the current Profile/account.

History persists locally in UserDefaults and is shared across app windows, while each window filters by its own verified Profile/account. No history is displayed without one. Only resource location metadata, display names, and visit times are saved; credentials, resource contents, and logs are excluded. Recording, searching, and deleting history do not call AWS; reopening a resource performs the normal read queries. Unreadable stored history is preserved and editing is disabled with a message.

The following component previews use mock recent resources:

![Recent resources in light mode](docs/ui-recents-light.png)

![Recent resources in dark mode](docs/ui-recents-dark.png)

### Security Groups and Resource Relationships

Open `Security Groups` to search by group ID, name, VPC, owner, tags, or rule content and filter by VPC. Select a group to read its metadata, tags, and inbound/outbound rules, including protocols, ports or ICMP type/code, CIDRs, Prefix Lists, and security-group references. The list uses complete pagination, supports refresh/cancel, and labels retained data after a failed refresh. Groups are queried through the current Profile and Region; a visible shared group's owner is shown separately. Groups support favorites and recent history.

Use `View relationships` in an EC2, LB, Target Group, security group, or Hosted Zone detail. Alias and CNAME record rows also provide a record-specific entry. The sheet starts with names and labeled direct relationships; expand a card for its fields, choose `Explore` to follow the next hop, or `Open` to navigate to the exact resource. `Back` restores a previously loaded snapshot; `Refresh` reads it again. Closing the sheet or changing the outer Profile, Region, or resource clears its state. SNS retains its existing relationship viewer.

The view connects LB associations to Target Groups, target registrations to EC2/Lambda/ALB, and EC2/LB bindings to security groups. Security-group references are permission rules, not proof of connectivity. IP targets are not guessed to be EC2. Lambda qualifiers stay visible, while `Open` displays function-level details. Only confirmed same-account security-group references are navigable; shared or unknown owners remain informational.

For Route 53, choose the LB query Region explicitly. A direct Alias match requires both the LB DNS name and its canonical Hosted Zone ID; a CNAME match requires an exact direct DNS target. Matching handles case, a trailing dot, and the ALB `dualstack.` variant without guessing from a suffix or resolving DNS chains. Weighted/failover records keep their routing identifiers. An unmatched target is shown as unmatched in that query scope, not as a nonexistent resource. Opening a matched regional resource changes the workspace Region explicitly and revalidates the current Profile's identity; opening a global Route 53 record preserves the workspace Region and places the exact record at the top of Records, expanded, with other records below.

Reverse queries run only when requested: EC2 scans instance-type Target Groups, a security group finds attached EC2 instances (including secondary network interfaces) and LBs, and an LB scans Hosted Zones for direct DNS references. Zone scans use at most four concurrent record queries and report successful/total checks plus failed zones; incomplete results are never presented as a complete absence of relationships. No other Profile or every-Region inventory is queried automatically. These are configuration relationships, not observed traffic or DNS propagation checks.

Security groups and instance relationships require `ec2:DescribeSecurityGroups` and `ec2:DescribeInstances` with `Resource: "*"`; ELBv2 and Route 53 relations reuse the read permissions documented below. See the [EC2 IAM reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html), [security-group rules](https://docs.aws.amazon.com/vpc/latest/userguide/security-group-rules.html), and [Route 53 Alias targets](https://docs.aws.amazon.com/Route53/latest/APIReference/API_AliasTarget.html). No security-group rules or DNS records are changed.

Component previews use simulated data:

![Security group configuration in light mode](docs/ui-security-group-light.png)

![Load balancer resource relationships in light mode](docs/ui-relations-light.png)

![Route 53 relationship query in an explicit Region](docs/ui-relations-dns-dark.png)

### Load Balancers and Target Groups

Select and verify a Profile and Region, then open `Load Balancers` or `Target Groups` in the sidebar. These ELBv2 pages cover Application, Network, and Gateway Load Balancers for that account and Region. Lists support local search and type filters; select a resource explicitly to read its details. No Profile means no queries. Load balancers and Target Groups can be saved in favorites and recent history by ARN and Region.

A load balancer shows its DNS name, scheme, state, network configuration, listeners, and associated Target Groups. Listeners show protocol, port, TLS configuration, and default actions. Selecting an ALB listener loads its rules, including priority, conditions, transformations, and ordered actions. Forward actions expose every weighted Target Group; redirects, fixed responses, and authentication actions remain distinct. Authentication secrets and extra authentication parameters are excluded from the app's models. These links describe configuration, not observed traffic.

Target Groups show their protocol, target type, health-check configuration, and associated load balancers. Registered targets include their port, availability zone, health state, reason, and description when returned. `Open` follows an exact resource in the same Profile, account, and Region: an instance target opens EC2, a Lambda target opens the function, and an ALB target opens the load balancer. IP targets are displayed without guessing an EC2 association. A Lambda alias/version remains visible in the target ARN; the link opens function-level details rather than a qualified invocation view. Missing resources and failed requests show an error without selecting a substitute.

In EC2 details, the `Target Groups` tab offers an explicit membership query. It lists Target Groups in the current Region, reads health for instance-type groups with up to four concurrent requests, and matches the exact registered instance ID, preserving multiple registered ports. It excludes `Target.NotRegistered` results. Results show successful checks and per-group failures; an incomplete scan is not treated as proof that the instance has no memberships. This scan runs only when requested and does not alter the main Target Group list or favorites.

Lists and dependent data load on demand, paginate completely, and support manual refresh and cancellation without polling. Failed list refreshes mark retained data as potentially stale; listeners, rules, and target health have separate failure states. Profile, account, or Region changes clear old state and invalidate in-flight results. Opening a related resource stays in the current scope, and never selects another Profile automatically.

The role needs `elasticloadbalancing:DescribeLoadBalancers`, `elasticloadbalancing:DescribeTargetGroups`, `elasticloadbalancing:DescribeListeners`, `elasticloadbalancing:DescribeRules`, and `elasticloadbalancing:DescribeTargetHealth` with `Resource: "*"`. See the [ELBv2 IAM reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_elbv2.html), [listener actions](https://docs.aws.amazon.com/elasticloadbalancing/latest/APIReference/API_Action.html), and [target health](https://docs.aws.amazon.com/elasticloadbalancing/latest/APIReference/API_TargetHealth.html). The app performs read operations only.

Component previews use simulated data:

![ALB listeners and routing rules in light mode](docs/ui-elb-listeners-light.png)

![Target Group health states in dark mode](docs/ui-elb-targets-dark.png)

![EC2 Target Group query with partial results](docs/ui-elb-membership-light.png)

### Route 53

After selecting and verifying a Profile, open `Route 53` in the sidebar to browse that account's public and private Hosted Zones. Route 53 is global within the Profile's AWS partition: this page hides the resource Region selector, and changing resource Regions elsewhere does not reload its data. The commercial, China, and GovCloud partitions use their corresponding SDK endpoints. No Profile means no queries or displayed resources.

Search by zone name or ID, filter by public/private, and select a zone to open `Overview`, `Records`, and `Tags`. Overview shows the Zone ID, comment, record count, caller reference, delegation name servers for public zones, and returned VPC associations for private zones. Name servers and VPC associations describe AWS configuration, not a live DNS test or an inventory of VPC resources. Tags, metadata, and records load independently; a failure in one does not hide the others.

Records support local search and type filtering. Expand a record to read its original values, TTL, Alias target and target health evaluation, routing identifier, and applicable weighted, latency, failover, geolocation, geoproximity, multivalue, or IP-based routing settings. Health check and traffic policy identifiers are displayed without querying those resources. Alias records can omit TTL. Values, including TXT quoting and escapes, are preserved. This is the latest API configuration and can include pending DNS changes; it does not verify propagation.

Lists load on first entry, with complete pagination and no scheduled polling. Use `Refresh` to reload and `Cancel` to stop waiting. A failed zone-list refresh labels retained data as stale; incomplete record pagination is not displayed as a complete result. Profile/session changes, signing in again, and connection retries clear the old state and invalidate in-flight requests. Hosted Zones support favorites and recent history using `global` plus the Zone ID, without changing your selected resource Region. Individual records are not saved as separate favorites or history entries.

The role needs `route53:ListHostedZones` on `Resource: "*"`, plus `route53:GetHostedZone`, `route53:ListResourceRecordSets`, and `route53:ListTagsForResource` for the permitted Hosted Zone resources. See the [Route 53 IAM reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_route53.html), [record-set API](https://docs.aws.amazon.com/Route53/latest/APIReference/API_ListResourceRecordSets.html), and [service endpoints](https://docs.aws.amazon.com/general/latest/gr/r53.html). The app does not edit DNS records, register domains, or run Resolver queries.

The following component previews use mock Route 53 data:

![Route 53 Hosted Zone overview in light mode](docs/ui-route53-light.png)

![Route 53 DNS records in dark mode](docs/ui-route53-dark.png)

### Cost Dashboard

After manually selecting and verifying a Profile, open `Costs` in the sidebar (`Cmd+Shift+B`) to load costs for the first time. The dashboard shows month-to-date costs, the previous full month's costs, daily trends, and a service breakdown for the selected period. It uses `UnblendedCost` and preserves AWS's currency, negative refunds, and `Estimated` status. Missing data is displayed separately from an actual zero cost.

Every cost request is restricted to the current Profile's STS-verified account through a `LINKED_ACCOUNT` filter. Management accounts also show only their own costs, without automatically aggregating organization members. The Profile's role must still have billing access. No requests are made without a selected Profile. Changing the Profile or session, signing in again, or retrying the connection clears the cost cache.

Date options include the current month, previous month, last 30 days, and a custom range. Queries use complete UTC days and exclude the unfinished current day; the current month and the preceding 12 months are available. At the start of a month, before any complete day is available, month-to-date costs remain blank while the previous month is still available. Daily trends and service breakdowns use the selected dates; the two summary cards always show the current and previous months as of the query time. The billing Region filter is independent of the resource Region and defaults to all regions. Its options come from AWS billing dimensions, and it applies to summaries, trends, and service breakdowns. The standard AWS partition uses the global Cost Explorer endpoint, `ce.us-east-1.amazonaws.com`; the China partition uses the SDK's corresponding China endpoint. Other partitions are shown as unsupported.

Click `Apply` after changing filters to run a query. `Refresh` forces a reload using the applied filters. The eight most recent successful result sets for the current Profile are cached only in memory. Returning to an already loaded page does not repeat requests; failures and cancellations require a manual retry. The cache has no scheduled refresh and is not written to disk. The page displays the retrieval time, and a failed refresh keeps the previous results for the same query while showing an error. `Cancel` stops waiting and prevents further pagination; requests already completed may still incur charges.

Before use, enable Cost Explorer in the AWS console and grant the current role `ce:GetCostAndUsage`, `ce:GetDimensionValues`, and the corresponding billing access. Cost data is delayed and may be revised; it is neither real-time spending nor a final invoice. The app does not enable the service automatically. Missing permissions, unavailable data, throttling, expired login sessions, and incomplete responses produce messages. A pagination failure never presents partial amounts as a complete total.

**Cost Explorer API calls incur charges.** A single load usually makes multiple calls for summaries, daily details, and Region dimensions, and may include pagination or automatic SDK retries. The page counts logical calls and pagination requests, excludes SDK retries, and does not estimate your bill. For current prices and activation rules, see [AWS Cost Explorer pricing](https://aws.amazon.com/aws-cost-management/aws-cost-explorer/pricing/), the [activation guide](https://docs.aws.amazon.com/cost-management/latest/userguide/ce-enable.html), and the [API documentation](https://docs.aws.amazon.com/cost-management/latest/userguide/ce-api.html).

The following component preview uses mock cost data:

![Cost dashboard](docs/ui-costs-light.png)

### AWS Health Events

After manually selecting and verifying a Profile, open `Health` in the sidebar. `Current account` is the default and loads that account's events across all regions, including upcoming scheduled changes. Switch explicitly to `Entire organization` to query organization events through the same Profile's permissions. No queries run without a selected Profile, and public events are excluded. The resource Region selector is hidden on this page; changing a resource Region elsewhere does not reload Health. The commercial, China, and GovCloud partitions use their respective Health endpoints.

Organization mode requires a management or delegated administrator role, an organization with all features enabled, AWS Health organizational view enabled, and an eligible Support plan for API access. The app only reads data; it does not enable organization access or change your Support plan. Organization events are retained for up to 90 days. See [organizational view prerequisites](https://docs.aws.amazon.com/health/latest/ug/aggregate-events.html) and [organization queries](https://docs.aws.amazon.com/health/latest/APIReference/API_DescribeEventsForOrganization.html).

Enter a 12-digit account ID and apply it to filter organization events at AWS, or leave it empty for all accounts. Select an event to load its affected account IDs, then explicitly select one account to read its description and resources. The caller Profile stays unchanged. The role needs `health:DescribeEventsForOrganization`, `health:DescribeAffectedAccountsForOrganization`, `health:DescribeEventDetailsForOrganization`, and `health:DescribeAffectedEntitiesForOrganization`; allow these organization read actions with `Resource: "*"`. Account, description, and resource failures show separate actionable errors. Switching query mode or applying an account filter clears old results; changing or clearing the Profile also resets to current-account mode. In-flight requests are cancelled and late results are ignored.

Search by event type, ARN, service, or Region, and filter locally by status, category, service, and event Region. Select an event to read its latest description, metadata, times in UTC, and affected resources. Details and affected resources load independently and show separate errors. Missing values remain explicitly unavailable. This is a list of AWS Health events and their latest state, not a history of every update to each event.

The list loads on first entry and stays in memory when you return. Use `Refresh` to reload or `Cancel` to stop waiting; there is no scheduled polling. Changing or clearing the Profile, changing the session, signing in again, or retrying the connection clears the old results and invalidates old requests. Pagination failures do not present partial lists as complete results; a failed refresh labels the previous list as potentially out of date.

AWS Health API access requires an eligible AWS Support plan. Accounts without access receive a specific message and can still check events in the AWS Health console. The role needs `health:DescribeEvents`, `health:DescribeEventDetails`, and `health:DescribeAffectedEntities`; access failures identify the relevant permission. See the [Health API access requirements](https://docs.aws.amazon.com/health/latest/ug/health-api.html) and [event query API](https://docs.aws.amazon.com/health/latest/APIReference/API_DescribeEvents.html).

The following component previews use mock Health data:

![AWS Health events in light mode](docs/ui-health-light.png)

![AWS Health events in dark mode](docs/ui-health-dark.png)

![Organization Health events with member-account details](docs/ui-health-organization-dark.png)

### CloudWatch Alarms

After manually selecting a Profile and Region, open **CloudWatch → Alarms** in the sidebar to view Metric and Composite Alarms for the current account and Region. The list loads on first entry and supports searching by name, ARN, or metric, filtering by state and type, manual refresh, and cancellation. Returning to the same loaded page does not repeat requests, and there is no scheduled polling. No queries run without a selected Profile. Changing the Profile, Region, or session clears the old list and details.

The first alarm is not selected automatically. Select an alarm to view:

- `Overview`: state, reason, update time, most recent state transition, description, and tags.
- `Configuration`: a single metric, dimensions, Metric Math or Metrics Insights expressions, thresholds, and evaluation settings, or a Composite Alarm's rule and action suppression settings.
- `Actions`: target ARNs for ALARM, OK, and INSUFFICIENT_DATA, and whether actions are enabled. For an SNS Topic in the same account and Region, click `Open SNS topic` to open its details in the app. Other targets remain available as configuration text.
- `History`: the last 30 days of history in reverse chronological order, including state changes, configuration changes, and action records, with expandable returned details.

Tags and history are fetched only for the selected alarm. Each shows its own error if loading fails, while the base configuration remains available. Use the refresh button at the top right of the details to retry. Pagination failures do not present partial lists or history as complete results. Alarms can be saved in local favorites and are identified by ARN. You must still manually select the matching Profile and verify the account; deleted alarms or permission failures leave the favorite intact and display a message.

The role needs `cloudwatch:DescribeAlarms`; history and tags additionally require `cloudwatch:DescribeAlarmHistory` and `cloudwatch:ListTagsForResource`, respectively. To retrieve Composite Alarms, the first two permissions must allow `Resource: "*"` rather than being restricted to individual alarm ARNs. Visibility remains subject to the current role's permissions. See [DescribeAlarms](https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/API_DescribeAlarms.html), [DescribeAlarmHistory](https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/API_DescribeAlarmHistory.html), and [ListTagsForResource](https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/API_ListTagsForResource.html).

The alarm page reads only Metric and Composite Alarm configuration and history; Log Alarms are not supported. Metric charts are available in the `Metrics` tab of EC2, Lambda, and applicable RDS details. The app does not create, delete, enable, disable, or change the state of alarms, or publish messages to SNS.

The following component preview uses mock alarm data:

![CloudWatch alarms](docs/ui-alarms-light.png)

### CloudWatch Logs

Open **CloudWatch → Logs** to browse log groups in the selected Profile/account/Region; linked-account groups are excluded. Selecting a group reads its log streams and available metadata, including retention, stored bytes, log class, and KMS key. Choose all streams or one stream, select the last 1, 6, or 24 hours, optionally enter an AWS filter pattern, then click `Search`. This uses ordinary `FilterLogEvents`, without Logs Insights queries or Live Tail, and preserves AWS data masking.

Each requested event page contains up to 500 events. Use `Load more` to continue; incomplete results remain labeled, with loaded events shown newest first. Display is bounded at 5,000 events or 4 MiB of UTF-8 message text; message previews show up to 2,000 characters. Narrow the range or filter when limits are reached. Changing the stream/range/filter clears the old search; switching scope/group invalidates old requests. Results stay in memory, and there is no automatic search or polling.

Required permissions are `logs:DescribeLogGroups`, `logs:DescribeLogStreams`, and `logs:FilterLogEvents`. This view does not create groups, enable log exports, or change retention. Existing log collection/storage remains separately billed; see [AWS query costs](docs/aws-query-costs.md) for log-read pricing boundaries.

### SNS Topics

After manually selecting and verifying a Profile, open `SNS` in the sidebar to view Topics for the current account and Region. The view supports searching by name or ARN, filtering Standard and FIFO Topics, manual refresh, and cancellation. The list loads only on first entry, has no scheduled polling, and does not automatically select the first item. No queries run without a selected Profile. Changing the Profile, Region, or session clears old data. Topics can be saved in local favorites and located by ARN, following the same manual Profile selection and account verification rules.

Selecting a Topic loads its attributes, tags, and subscriptions independently; a failure affects only the corresponding section:

- `Overview`: Topic identity, display name, owner, subscription counts, and tags.
- `Configuration`: encryption, FIFO, tracing, and other settings returned by AWS, plus expandable access, delivery, and archive policies. Missing fields are explicitly shown as not returned, rather than assumed to be disabled or zero.
- `Subscriptions`: protocol, status, owner, ARN, and endpoint. Confirmed, Pending confirmation, Deleted, and Unknown states are distinguished. Valid cross-account subscriptions retain owner information without switching to or querying the subscriber's account.

Endpoints are hidden by default. Reveal an endpoint manually to copy it; switching Topics hides endpoints again. Tags, attributes, and subscriptions remain only in the current window's memory and are not stored in favorites. Pagination failures do not display partial Topic or subscription lists. The refresh button at the top right retries all three detail groups; switching tabs does not repeat requests.

Required permissions are `sns:ListTopics` with `Resource: "*"`, plus `sns:GetTopicAttributes`, `sns:ListTagsForResource`, and `sns:ListSubscriptionsByTopic` for the relevant Topic. Returned attributes may vary with permissions. The list is queried for the current Profile's account and does not automatically include Topics shared by other accounts. See the [SNS permissions table](https://docs.aws.amazon.com/service-authorization/latest/reference/list_sns.html), [Topic attributes](https://docs.aws.amazon.com/sns/latest/api/API_GetTopicAttributes.html), and [Topic subscriptions](https://docs.aws.amazon.com/sns/latest/api/API_ListSubscriptionsByTopic.html).

This module does not publish messages, create or delete Topics, subscribe, unsubscribe, confirm subscriptions, or modify configuration. Navigation from CloudWatch actions locates Topics only within the current Profile and Region; it never switches accounts or Regions. Missing targets and access failures produce messages.

Click the relationship-view button (「调用链查看」) in Topic details to open a dialog showing configured relationships as **CloudWatch alarms → current SNS Topic → subscription targets**:

- Initially, resource nodes show only their names. Click a name to expand its configuration details, then click `Open alarm` or `Open Lambda function` to navigate to that service. Nodes expand and collapse independently. Longer scope explanations are under the collapsed `About this view` section. Navigable Lambda subscriptions show the function name; other subscriptions use their protocol name, keeping email addresses, phone numbers, and URLs out of node titles.
- Upstream discovery reads Metric and Composite Alarms for the current Profile and Region, matching ALARM, OK, and INSUFFICIENT_DATA actions exactly. It shows whether actions are enabled and any returned suppression settings. Each dialog opening performs one complete paginated check, which can also be refreshed separately. This requires `cloudwatch:DescribeAlarms`, with `Resource: "*"` for Composite Alarms. Permission or query failures are marked as an incomplete check, rather than treated as no sources.
- Downstream nodes reuse subscriptions already loaded in Topic details and show their confirmation status when expanded. To update subscriptions, close the dialog and refresh Topic details. Raw endpoints remain hidden by default and must be revealed before copying. Valid Lambda nodes can open function details immediately after expansion without revealing the endpoint.
- Alarms and confirmed Lambda subscriptions can open their details in the app, but only within the same verified Profile, account, Region, and partition. Navigation does not save favorites, select a Profile automatically, or change the Region. Targets outside this scope, unconfirmed subscriptions, and services without a detail view are displayed as information only. Lambda aliases and versions remain visible, but navigation opens the function's details rather than a dedicated alias or version view.

This view shows configured relationships. It does not prove that messages were sent or delivered successfully, and it is not a complete list of publishers. S3 notifications, Lambda asynchronous destinations, and `Publish` calls in application code are outside the current scan. Topic policies are not treated as evidence of a publisher. Actual SNS publish records require separately enabling and querying CloudTrail data events; the default event history does not include them. See [CloudWatch alarm queries](https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/API_DescribeAlarms.html) and [SNS CloudTrail documentation](https://docs.aws.amazon.com/sns/latest/dg/logging-using-cloudtrail.html).

The following component previews use mock SNS data:

![SNS Topic](docs/ui-sns-light.png)

![Configured SNS relationships with mock data and resource nodes collapsed by default](docs/ui-sns-relationships-light.png)

### Resource Metrics and Lambda Logs

Open `Metrics` in EC2, Lambda, or applicable RDS details, select the last 1, 6, or 24 hours, then click `Load metrics`. Each query batches the applicable metrics with five-minute aggregation. The window ends at the most recent complete five-minute boundary, and all times are displayed in UTC. `Refresh` reloads data manually; there is no polling. Empty samples remain empty, gaps in data break the chart lines, and partial data and permission failures are labeled separately.

| Resource | Metric | Aggregation and unit |
| --- | --- | --- |
| EC2 | CPUUtilization | Average, percent |
| EC2 | NetworkIn / NetworkOut | Sum, bytes per five minutes |
| EC2 | StatusCheckFailed | Maximum, status check failure value |
| Lambda | Invocations / Errors / Throttles | Sum, count per five minutes |
| Lambda | Duration | Average, milliseconds |
| RDS instance | CPUUtilization / DatabaseConnections | Average, percent / count |
| RDS instance | FreeableMemory / ReadLatency / WriteLatency | Average, bytes / seconds / seconds |
| Non-Aurora RDS instance | FreeStorageSpace | Average, bytes |
| Aurora cluster | VolumeBytesUsed | Average, bytes |
| Aurora cluster | VolumeReadIOPs / VolumeWriteIOPs | Sum, count per five minutes |

Lambda metrics use the function-name dimension and include that function's versions and aliases. Metrics require `cloudwatch:GetMetricData`; missing data is not assumed to be zero. See [EC2 metrics](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/viewing_metrics_with_cloudwatch.html), [Lambda metrics](https://docs.aws.amazon.com/lambda/latest/dg/monitoring-metrics-types.html), and [GetMetricData](https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/API_GetMetricData.html).

The Lambda `Logs` tab becomes available after the function configuration loads successfully. Select a time range, optionally enter a CloudWatch filter pattern using AWS syntax, then click `Search`. Results show the event time, log stream, ingestion time, and selectable multiline message text. Long messages initially show a preview and can be expanded in full. Changing the time range or filter clears the previous search and requires another click on `Search`.

The log group comes from the function's `LoggingConfig.LogGroup`, falling back to `/aws/lambda/<functionName>` if no custom group is configured. For custom groups, the app first enumerates all log streams, strictly matches the current function name, then reads matching streams in batches. Failed enumeration never falls back to reading the entire shared group. Required permissions are `logs:FilterLogEvents`, plus `logs:DescribeLogStreams` for custom log groups. Reading function configuration uses `lambda:GetFunction`. See [Lambda log groups](https://docs.aws.amazon.com/lambda/latest/dg/monitoring-cloudwatchlogs-loggroups.html) and [FilterLogEvents](https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/API_FilterLogEvents.html).

Click `Load more` to continue pagination for the same query. Loaded events appear in reverse chronological order. Until pagination completes, the view explicitly marks the results as partial and does not call them the latest logs for the entire time range. It retains at most 5,000 events or 8 MiB of UTF-8 message text; a message that would exceed the limit is omitted in full. If a size or pagination safety limit is reached, narrow the time range or add a filter. AWS data masking is preserved, and the app does not request permission to unmask logs.

Metrics and logs call APIs only when explicitly loaded and may incur CloudWatch usage charges. Click `Cancel` during loading to stop waiting and prevent further requests; completed requests cannot be undone. Credentials, account, and role come from the current manually selected and verified Profile, and the Region comes from the current resource. No requests run without a selected Profile. Switching resources, Profiles, or Regions, or leaving the tab, cancels the wait and clears in-memory results; late responses are ignored. Metrics and logs are not written to favorites, disk, or application diagnostic logs.

The following component previews use mock monitoring data:

![CloudWatch metric charts](docs/ui-metrics-light.png)

![Lambda log search](docs/ui-lambda-logs-dark.png)

### In-App SSO Login

New or refreshed credentials are verified with STS using those exact credentials before any service request. Normal renewal of the same account and principal is allowed; an account or role change clears workspace data and stops pending work. Use `Retry Connection` to explicitly verify the selected Profile again.

1. Choose a configured session in `SSO Session` and click `SSO Login`. The app runs the local `aws sso login --sso-session <name>` command in the background, and AWS CLI opens the default browser for authorization. No terminal window opens, and you do not need to select a Profile first.
2. After a successful login, the Profile remains `Select profile`, resource lists and details stay empty, and no account identity verification or resource queries are sent.
3. Only after you manually select a Profile associated with that session does the app verify your identity and load resources for that Profile's account, role, and Region. Switching sessions, signing in again, or choosing `Clear profile selection` in the Profile popover clears the current selection and resource views.

Click the Profile selector to search by Profile name, role, or account ID. Space-separated search terms all need to match. Filtering stays within the selected session (or `Other profiles`) and never selects a Profile automatically. Results show the configured Profile name, with the role and known account ID underneath; press Return to choose a single matching result. SSO account IDs come from the local configuration, and other Profiles show an account ID only while their selected identity is verified. The app does not query or cache AWS account names.

The app remembers only the last selected named session; a Profile must be selected manually on every launch. Valid AWS CLI login caches can be reused without signing in again. A session with only one Profile still does not select it automatically. You can also sign in to a session before configuring any associated Profiles.

Profiles with regular credentials and legacy SSO Profiles without `sso_session` appear under `Other profiles` and still require manual selection. For legacy SSO, run `aws sso login --profile <name>` in a terminal, then select that Profile or click `Retry Connection`. Network, permission, and configuration errors are shown as connection failures rather than all being labeled as logged out.

Click `Cancel Login` to stop waiting. Switching sessions or closing the view also cancels the wait; Profile and Region selection are disabled during login. Login waits for at most five minutes. Cancellation or timeout terminates the CLI subprocess started for that attempt, without closing the browser, signing out, or deleting existing sessions. Cancellation cannot undo authorization already completed in the browser.

The CLI must be available at `/opt/homebrew/bin/aws`, `/usr/local/bin/aws`, or `/usr/bin/aws`. The app shows a message if it is missing. If the browser does not open, cancel, sign in from a terminal, and then select a Profile manually. Login and credential loading use the same configuration paths. The login subprocess does not inherit `AWS_PROFILE` or `AWS_DEFAULT_PROFILE`, preventing a terminal's preselected account from affecting session login. The app does not display, log, or save the login command's raw output. AWS CLI manages the login cache.

The following component preview simulates a successful login with no Profile selected:

![Empty resource view after session login](docs/ui-sso-login.png)

## Project Structure

```
Sources/AWSPlatform/
├── App.swift                    # App entry point
├── ContentView.swift            # Main view
├── Models/                      # Data models
│   ├── AWSProfile.swift
│   ├── AWSSOSession.swift
│   ├── AWSService.swift
│   ├── CloudWatchAlarm.swift
│   ├── SNSTopic.swift
│   ├── CostModels.swift
│   ├── HealthModels.swift
│   ├── Route53Models.swift
│   ├── ELBModels.swift
│   ├── SecurityGroupModels.swift
│   ├── ResourceRelationModels.swift
│   ├── WorkspaceDestination.swift
│   ├── ResourceFavorite.swift
│   ├── RecentResource.swift
│   ├── EC2Instance.swift
│   ├── LambdaFunction.swift
│   ├── S3Bucket.swift
│   ├── S3ObjectPage.swift
│   └── S3Transfer.swift
├── Services/                    # AWS service layer
│   ├── AWSServiceProvider.swift
│   ├── AWSS3TransferService.swift
│   ├── S3ObjectListing.swift
│   ├── AWSAlarmService.swift     # CloudWatch alarms, tags, and history
│   ├── AWSSNSService.swift       # SNS Topics, configuration, tags, and subscriptions
│   ├── AWSCostService.swift       # Cost Explorer queries and complete pagination
│   ├── AWSHealthService.swift    # Account-specific Health events, details, and affected resources
│   ├── AWSRoute53Service.swift   # Hosted Zones, DNS records, metadata, and tags
│   ├── AWSELBService.swift       # Load balancers, Target Groups, routing, and target health
│   ├── AWSSecurityGroupService.swift
│   ├── AWSResourceRelationshipService.swift
│   ├── AWSCLICredentialProvider.swift # SSO credential bridge for custom configuration paths
│   └── AWSSSOLoginService.swift  # CLI login process and shared invocation configuration
├── Utilities/                   # Utilities
│   ├── ConfigReader.swift
│   ├── S3FileDrop.swift
│   ├── S3TransferFiles.swift
│   ├── Route53LoadBalancerMatcher.swift
│   └── UserFacingError.swift
├── ViewModels/                  # View models
│   ├── AlarmViewModel.swift
│   ├── SNSViewModel.swift
│   ├── CostViewModel.swift
│   ├── HealthViewModel.swift
│   ├── Route53ViewModel.swift
│   ├── ELBViewModel.swift
│   ├── SecurityGroupsViewModel.swift
│   ├── ResourceRelationshipsViewModel.swift
│   ├── EC2TargetGroupsViewModel.swift
│   ├── ELBResourceNavigation.swift
│   ├── EC2ViewModel.swift
│   ├── FavoriteNavigation.swift
│   ├── FavoritesViewModel.swift
│   ├── RecentResourcesViewModel.swift
│   ├── LambdaViewModel.swift
│   ├── ProfileViewModel.swift
│   ├── S3ViewModel.swift
│   └── S3TransferViewModel.swift
└── Views/                       # UI views
    ├── CloudWatch/
    ├── SNS/
    ├── Cost/
    ├── Health/
    ├── Route53/
    ├── ELB/
    ├── SecurityGroups/
    ├── Relationships/
    ├── EC2/
    ├── Lambda/
    ├── S3/
    ├── FavoritesListView.swift
    ├── RecentResourcesListView.swift
    ├── ProfileBarView.swift
    ├── ServiceSidebarView.swift
    └── SharedViews.swift

Tests/AWSPlatformTests/           # Configuration parsing and ViewModel unit tests
```

## AWS Configuration

Ensure that `~/.aws/config` is correctly formatted:

```ini
[default]
region = us-east-1
output = json

[profile my-profile]
region = ap-northeast-1
output = json
```

AWS CLI `[sso-session ...]` sections appear in the separate `SSO Session` selector, not in the Profile list. Auxiliary sections such as `[services ...]` are not offered as Profiles.

The Profile list merges names from `config` and `credentials`, using settings such as Region from `config` when names match. Profiles found only in `credentials` use the default Region, `us-east-1`. The app supports the process environment variables `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE`, using the same paths to discover configuration and create AWS clients. Processes launched from Finder do not automatically inherit temporary environment variables set in a terminal. To use custom paths, you can run `swift run` from a terminal with those variables set.

SSO with the default configuration paths uses Soto's credential provider. SSO with a custom `AWS_CONFIG_FILE` uses the local AWS CLI v2 `configure export-credentials` command. The CLI must be installed at `/opt/homebrew/bin/aws` or `/usr/local/bin/aws` (with `/usr/bin/aws` also supported) and support that command. Credentials are parsed only through an in-memory pipe; command output is not displayed or saved. In-app login automatically receives the same configuration paths. If you log in from a terminal, use the same configuration paths and session, then manually select a Profile. If a Profile is already selected, click `Retry Connection`.

Multiple Profiles can share one named SSO session:

```ini
[profile development]
sso_session = company
sso_account_id = 111122223333
sso_role_name = DeveloperAccess
region = eu-west-1

[profile production]
sso_session = company
sso_account_id = 444455556666
sso_role_name = ReadOnlyAccess
region = ap-southeast-1

[sso-session company]
sso_start_url = https://example.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

Replace the example values with your configuration, then run `aws sso login --sso-session company` to sign in to the shared `company` session. Selecting `company` in the app makes `development` and `production` available in the Profile list, but you must still choose one manually. Both Profiles can reuse the login while the session is valid and you have access to the corresponding accounts and roles. Each Profile independently determines the account, role, and resource Region; `sso_region` is the IAM Identity Center Region. In the standard format, each Profile references one session. Different sessions require separate logins, and the app does not automatically discover or create Profiles for other accounts. See the [AWS CLI SSO documentation](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html).

The Region list includes commonly used regions known to the SDK and regions found in your configuration. Known regions show a localized location and the unchanged code, for example `Singapore · ap-southeast-1`; unknown codes remain visible verbatim. You can also enter another Region code using the edit button beside the Region selector. Region activation, partition membership, and service permissions remain governed by AWS.

The Lambda list appears as soon as basic functions are available, then uses `GetFunction` in batches of at most four concurrent reads to supplement state and tags. The selected function stays selected as summaries arrive. During this stage, state filters and tag searches use summaries loaded so far, as indicated in the list. If some functions cannot be read or access is denied, the list remains available with a message. State filters exclude functions with unknown state. Required permissions include at least `lambda:ListFunctions` and `lambda:GetFunction` for the additional information.

When you manually load Lambda source code, the app streams the ZIP into a private system temporary directory, reads its contents in memory, and attempts to remove the temporary directory on success, failure, or cancellation. Archive entries are never extracted to filesystem paths. Viewing source code still creates a temporary ZIP on the local machine.

Source preview is limited to a 50 MiB download, 250 MiB of expanded data, 10,000 file/directory entries, and 10 MiB of cumulative text preview. Each text file retains the existing 200,000-byte preview limit; binary and larger files remain listed without content. Hidden entries are not displayed but still count toward archive limits. Downloads time out after 60 seconds; ZIP processing has a 30-second limit. Use `Cancel` while loading to stop the operation. Switching functions or clearing/changing the Profile invalidates old requests.

Only the current function's source is retained. Switching to another function releases the previous source; load it manually again when returning. Highlighting is reused for the current file, and changing the appearance reuses the parsed content without downloading source again.

Preview supports ordinary, unencrypted, single-disk ZIPs using Store or Deflate. ZIP64, symbolic links, special file entries, alternate path/link metadata, unsafe or duplicate paths, paths over 1,024 bytes or 32 components, and inconsistent sizes or CRCs are rejected with an error. These are local preview limits, not AWS deployment quotas. Container-image functions continue to display image information rather than ZIP source.

References: [AWS CLI credential export](https://docs.aws.amazon.com/cli/latest/reference/configure/export-credentials.html), [AWS CLI environment variables](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html), and [fields returned by the Lambda list API](https://docs.aws.amazon.com/lambda/latest/api/API_ListFunctions.html).

## Project Status

See [`ROADMAP.md`](ROADMAP.md) for the current stage, verification records, and planned work.

## License

Original code in this project is licensed under the [MIT License](LICENSE). Third-party dependencies retain their respective licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for versions and upstream licenses.

## 工程规范入口

项目约定见 [AGENTS.md](AGENTS.md)，视觉规则见 [DESIGN.md](DESIGN.md)，当前进度见 [ROADMAP.md](ROADMAP.md)。静态检查：`python3 scripts/harness/verify.py --mode task`；推送检查：`scripts/verify-before-push.sh`。设计 lint 使用固定版本 `@google/design.md@0.4.0`，需要 Node.js／npm，工具缓存保存在已忽略的 `.tmp/`。
