# UTM Bridge FDB Guard

[English](README.md) · [技术原理](docs/technical-background.md) · [安全策略](SECURITY.md)

`utm-bridge-fdb-guard` 是一个范围严格、默认拒绝操作（fail-closed）的 macOS LaunchDaemon，用来规避某类陈旧桥接转发表（FDB）记录导致的 Mac 宿主机与 UTM 桥接虚拟机之间无法通信的问题。

守护程序每次运行都会从当前网络状态重新发现 bridge、`vmenet`、物理上联接口和宿主 MAC，**不会固定虚拟机 MAC、bridge 编号、`vmenet` 编号或宿主 MAC**。只有全部安全条件同时成立时，它才删除一条经过精确确认的动态 FDB 记录；状态不明确或格式无法识别时不会做任何修改。

本项目是针对已观测到的 Apple `vmnet`/macOS bridge 行为所做的独立规避方案，并非 Apple 或 UTM 提供的上游修复。

## 问题表现

发生故障时，物理上联接口自身的 MAC 可能作为动态记录，被错误学习到 UTM 所使用 bridge 内的同一个上联接口上。此时宿主机访问虚拟机可能持续超时，而虚拟机与局域网中其他设备之间仍能通信。

在已观测案例中，删除这一条陈旧记录可恢复连接：

```sh
/sbin/ifconfig <bridge> deladdr <uplink-mac>
```

直接自动执行这条命令并不安全。因此，本项目会先验证 bridge 成员、上联接口、真实 `vmenet` 上的 guest 学习证据、目标唯一性和动态属性，并在修改前重新获取第二份快照。两次判断不完全一致就拒绝操作。

## 安全模型

默认策略刻意保持保守：

1. 查找包含 `vmenet*` 成员且处于活动状态的 macOS bridge，应用可选 bridge 白名单后仍要求全局候选恰好只有一个。
2. 要求 bridge 中唯一的非 `vmenet` 成员位于配置的上联白名单中。安装或重新配置时，安装器默认根据当前默认路由接口生成这个白名单，也可由用户显式指定。
3. 每次运行都从上联接口读取并规范化当前 MAC。
4. 要求实际 `vmenet*` 成员上存在有效的 guest 学习记录；虚拟机更换 MAC 后无需重装。
5. 目标必须恰好只有一条：上联自身 MAC、学习端口为该上联、并且属于动态 FDB 记录。
6. 删除前重新读取拓扑和 FDB，只有第二次判断与第一次完全一致才继续。
7. 只要出现候选不唯一、输出残缺、证据不足、多上联、静态记录或命令失败，就不修改任何内容。

程序永远不会清空整张 FDB，也不会修改 IP、路由、DNS、包过滤规则、UTM 配置或虚拟机配置，更不会重启虚拟机。

## 适用范围

- 使用 `/sbin/ifconfig` 与 `launchd` 的 macOS。
- 通过 Apple 虚拟化网络创建 UTM 桥接网络。
- 安装及删除 FDB 记录时具备管理员权限。
- 实际拓扑符合上述可验证安全模型。

解析器有意只接受已知的 macOS `ifconfig` bridge 输出格式；无法识别的新格式会被当成停止理由，而不是猜测依据。建议在 macOS 或 UTM 升级后重新运行 `scan`。

这个工具只处理一种特定 FDB 故障。相似现象也可能由虚拟机防火墙、服务未运行、IP 冲突、路由或代理配置造成。

## 快速开始

请从 [Releases 页面](https://github.com/HosamaJJF/utm-bridge-fdb-guard/releases)同时下载 `v1.0.0` 压缩包和 `SHA256SUMS`，先校验再解压，并在使用 `sudo` 前检查脚本：

```sh
shasum -a 256 -c SHA256SUMS
tar -xzf utm-bridge-fdb-guard-1.0.0.tar.gz
cd utm-bridge-fdb-guard-1.0.0
```

也可以固定到同一个发布标签，克隆源码用于检查或开发：

```sh
git clone --branch v1.0.0 --depth 1 https://github.com/HosamaJJF/utm-bridge-fdb-guard.git
cd utm-bridge-fdb-guard
```

使用自动 bridge 发现；安装器会把当前默认路由接口记录为允许的物理上联：

```sh
sudo ./scripts/install.zsh
```

安装器会先显示检测结果、拟安装配置并进行只读预检。只有在已经通过交互方式核对过同一条命令后，才建议为无人值守安装增加 `--yes`。

系统中安装的文件包括：

- `/Library/Application Support/UTMBridgeFDBGuard/bin/utm-bridge-fdb-guard`
- `/Library/Application Support/UTMBridgeFDBGuard/config.plist`
- `/Library/Application Support/UTMBridgeFDBGuard/run.lock`（仅用于内核 advisory lock 的持久化 root 管理文件）
- 同一 Application Support 目录内的版本和安装清单文件
- `/Library/LaunchDaemons/io.github.hosamajjf.utm-bridge-fdb-guard.plist`

所有安装文件均由 root 持有；LaunchDaemon label 为 `io.github.hosamajjf.utm-bridge-fdb-guard`。

### 显式配置

如果自动选择存在歧义，可以限制上联接口或 bridge：

```sh
sudo ./scripts/install.zsh --uplink en0 --bridge auto
sudo ./scripts/install.zsh --uplink en0 --bridge bridge100
```

如需更严格的 guest 证据，可以添加一个或多个示例 MAC 白名单：

```sh
sudo ./scripts/install.zsh \
  --guest-mac 02:00:00:00:00:01 \
  --guest-mac 02:00:00:00:00:02
```

guest MAC 白名单不是必需项。默认的 `learned-any` 策略会接受实际 `vmenet*` 成员上学习到的有效单播 guest MAC，因此重建虚拟机或更换虚拟网卡 MAC 通常无需重新配置。

## 命令

安装后的 LaunchDaemon 每个周期只执行一次短生命周期检查，并非常驻进程。

```sh
# 显示候选和拒绝原因，不修改 FDB
sudo ./bin/utm-bridge-fdb-guard scan --config /path/to/config.plist

# 完整执行判断流程，但不删除记录
sudo ./bin/utm-bridge-fdb-guard run --config /path/to/config.plist --dry-run

# 执行一次受保护的检查
sudo ./bin/utm-bridge-fdb-guard run --config /path/to/config.plist

# 检查配置、权限、解析和 launchd 状态
sudo ./bin/utm-bridge-fdb-guard doctor --config /path/to/config.plist

./bin/utm-bridge-fdb-guard version
```

检查已安装副本时可直接使用由 root 管理的程序和配置：

```sh
sudo "/Library/Application Support/UTMBridgeFDBGuard/bin/utm-bridge-fdb-guard" \
  scan --config "/Library/Application Support/UTMBridgeFDBGuard/config.plist"
```

### 重新配置与升级

```sh
sudo ./scripts/install.zsh --upgrade --reconfigure --uplink en0 --bridge auto
sudo ./scripts/install.zsh --upgrade
```

安装器会先把发布输入复制到由 root 管理的临时目录，在提示确认前完成验证，并清除安装路径继承的 ACL、拒绝不安全覆盖。配置一旦存在，`--uplink`、`--bridge`、`--guest-mac`、`--dry-run` 等配置选项必须与 `--upgrade --reconfigure` 同时使用，否则安装器会直接拒绝，避免参数被静默忽略。如果 Mac 改用另一物理上联接口，请通过 `--upgrade --reconfigure --uplink <接口>` 显式更新白名单。

### 检查 LaunchDaemon

```sh
sudo launchctl print system/io.github.hosamajjf.utm-bridge-fdb-guard
```

每次检查都会很快退出，所以两个周期之间看到 `state = not running` 属于正常现象；应重点检查最近退出状态和系统日志。

### 卸载

```sh
sudo ./scripts/uninstall.zsh
```

如需保留由 root 管理的配置以便日后重装：

```sh
sudo ./scripts/uninstall.zsh --keep-config
```

之后直接正常安装时，安装器会复用这份配置；复用前会确认它是软件目录中唯一保留的文件，且仍归 `root:wheel` 所有。如需替换配置，请改用 `--upgrade --reconfigure`。

## 使用建议

- 在陌生 Mac 上启用前，先运行 `scan` 和 `run --dry-run`。
- macOS、UTM、网卡或网络拓扑变化后重新运行 `doctor`。
- 不要把精确删除命令替换为整张 FDB 清空。
- 如果程序报告歧义，应修正配置或调查拓扑；即使使用显式白名单，也不会同时处理多个合格 bridge。
- 诊断输出可能包含接口 MAC；如认为这些信息敏感，请在公开提交前进行脱敏。

更完整的判断模型与限制见 [docs/technical-background.md](docs/technical-background.md)。相关讨论可参考 [UTM issue #7121](https://github.com/utmapp/UTM/issues/7121)。

## 贡献与安全问题

欢迎提交已经脱敏的 `scan` 输出以及 macOS/UTM 版本。涉及解析器的修改应同时加入“应接受”和相邻“必须拒绝”的测试夹具；CI 不得真正执行 `ifconfig ... deladdr`。

安全问题请根据 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证

MIT © 2026 [HosamaJJF](https://github.com/HosamaJJF)，详见 [LICENSE](LICENSE)。
