# AWS 查询费用

核对日期：2026-10-18。下表区分应用新增查询的费用与账号本来承担的资源费用。价格示例为 USD、不含税；实际取决于 Region、账户额度与现有配置，不作为账单报价。

| 功能／实际 API | 查询费用 | 资源本身及实现边界 |
| --- | --- | --- |
| EC2／Lambda／RDS 指标：CloudWatch `GetMetricData` | 有查询费用，不适用普通 API 每月 100 万次免费额度；按请求的指标数量计量，不按界面点击次数或数据点数计费。 | 仅手动读取既有指标，不自动轮询，不启用 Enhanced Monitoring／Database Insights 等。 |
| RDS 事件：`DescribeEvents` | 当前 RDS 定价未单独列此 API 的查询费。 | 不创建事件订阅。 |
| RDS 快照：`DescribeDBSnapshots`／`DescribeDBClusterSnapshots` | 当前 RDS 定价未单独列元数据查询费。 | 已有备份／快照存储仍可能收费；页面不创建、复制或恢复快照。 |
| CloudWatch 日志：`DescribeLogGroups`／`DescribeLogStreams`／`FilterLogEvents` | 当前 CloudWatch 费用对照表未列这些 API 的独立读取费。 | 只浏览已上送的日志，保留脱敏；不调用按扫描量计费的 Logs Insights `StartQuery`，也不调用 Live Tail。日志写入、存储等原有费用照常。 |
| CodeCommit：仓库目录／文件／差异／PR 的读取 | SDK 只读访问仍可能使 AWS 身份成为当月活跃用户；超过用户、Git 请求或存储额度，以及相关 KMS 请求可能收费。 | 不创建／修改／合并 PR，不推送代码。并非每个 List 请求都按 Git 请求计费；官方未提供完整逐 API 计量映射，不承诺文件读取单次免费。 |
| S3 历史版本：`ListObjectVersions` | 属于 LIST 请求，按请求／分页计费；实际价格按 Region 和存储类别。 | 历史版本存储费用原本存在。页面不启用 Versioning，不下载、恢复或删除历史版本；Region 未知时只读 `GetBucketLocation`，该操作归请求计费规则。 |
| ASG 模板／刷新记录：EC2 `DescribeLaunchTemplateVersions`、ASG `DescribeInstanceRefreshes` | 当前服务定价未单独列这两个 API 的查询费。 | 不发起刷新／扩缩容，原有 EC2、EBS、告警等费用继续。 |
| 收藏／最近访问 | 本地保存本身无 AWS 请求费用。 | 打开保存资源及成员跳转仍按实际调用的服务规则计费。 |

## 示例与现有费用入口

- us-east-1 的 `GetMetricData` 当前公开价格示例为 $0.01／1,000 个请求指标。一次查询 10 个指标约 $0.0001；10,000 次同样的加载约 $1。额外分页、统计量和重试会影响实际用量。
- S3 Standard us-east-1 的 LIST 价格示例为 $0.005／1,000 次请求。版本页面逐页加载，不自动枚举全部历史。
- CodeCommit 当前前 5 个活跃用户免费，超过后通常 $1／活跃用户／月，并包含相应存储与 Git 请求额度；超额 Git 请求当前示例为 $0.001／次。KMS 合资格请求的免费额度与账号其他服务共用，不能视为应用专属。
- 既有 Cost Explorer 面板的主 billing view API 当前按 $0.01／请求收费，每次分页也是新请求；其他 billing view 的计费规则可能不同。本轮不改变费用面板查询方式。

## 官方来源

- [CloudWatch 定价](https://aws.amazon.com/cloudwatch/pricing/) 与 [收费项目／API 对照](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch_billing.html) 。
- [CloudWatch us-east-1 当前公开价格表](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudWatch/current/us-east-1/index.json) 。
- [RDS 定价](https://aws.amazon.com/rds/pricing/) 。
- [S3 定价](https://aws.amazon.com/s3/pricing/) 。
- [CodeCommit 定价](https://aws.amazon.com/codecommit/pricing/) 、[FAQ](https://aws.amazon.com/codecommit/faqs/) 、[加密说明](https://docs.aws.amazon.com/codecommit/latest/userguide/encryption.html) 与 [KMS 定价](https://aws.amazon.com/kms/pricing/) 。
- [EC2 Auto Scaling 定价](https://aws.amazon.com/ec2/autoscaling/pricing/) 。
- [Cost Explorer 定价](https://aws.amazon.com/aws-cost-management/aws-cost-explorer/pricing/) 。
