# SSH Login Keepalive — Windows / macOS / Linux

在**你自己的电脑或长期在线的客户端主机**上安装一个自动重连的 SSH 登录，让远端 Linux 集群账户（即使 `Linger=no`）持续存在一个登录会话。**在哪里执行安装命令，就在哪里创建后台服务**；不依赖 `ywl`，也不修改远端服务器。

实现方式：客户端 SSH 连接远端并执行 `exec sleep infinity`。连接断开后客户端服务重试；它只维持一个 SSH 登录，**不能保证远端作业或所有 user services 一定存活**。请先确认符合集群的登录会话与后台运行政策。

## 先决条件

1. 安装端有 OpenSSH Client（`ssh` / Windows `ssh.exe`），能直接访问集群登录节点，并保持开机、联网。电脑休眠或关闭时无法保活。
2. **免交互 SSH 登录**已配置好：本机有自己的密钥及已验证的 `known_hosts`。不要把密钥放进本仓库，也不要关闭主机指纹校验。不支持每次 SSH 登录均需交互密码或 OTP 的环境。
3. 远端是有 `sleep infinity` 命令的 Linux 主机（如典型 GNU coreutils 环境）。目标账号可以是 `Linger=no`。

从 GitHub 获取本包：

```bash
git clone https://github.com/Molaison/ssh-login-keepalive.git
cd ssh-login-keepalive
```

Windows 也可以使用 GitHub 的 **Code → Download ZIP** 解压，无需安装 Git。

## Linux（systemd）

在希望持续发起 SSH 的 **Linux 客户端**执行：

```bash
./keepalivectl install cluster alice@login.cluster.example.org
./keepalivectl status cluster
./keepalivectl remove cluster
```

这会安装到当前用户的 `~/.config/systemd/user/`，由 `systemd --user` 自动重连（默认每 10 秒重试），支持同一用户多个名称不同的实例。**不需要 sudo**。

如果客户端自己的 `Linger=no`，服务可以在该用户登录期间运行，但**注销后会停止**，下次登录自动启动。需要客户端注销后继续运行，须由管理员批准在**客户端**启用 `loginctl enable-linger`；本程序不擅自更改系统设置。远端账号为 `Linger=no` 不影响安装。

需要已运行的 `systemd --user`；非 systemd 的 Linux 发行版不在当前支持范围内。

## macOS（launchd）

在自己的 **Mac 桌面登录会话**里打开 Terminal 并执行：

```bash
./keepalivectl install cluster alice@login.cluster.example.org
./keepalivectl status cluster
./keepalivectl remove cluster
```

每个实例生成一个 `~/Library/LaunchAgents/` 中的 plist，`launchd` 在用户登录时启动 SSH 并在退出后重新拉起。失败日志在 `~/Library/Logs/ssh-login-keepalive/cluster.log`。

**macOS LaunchAgent 仅在用户已登录期间运行**；注销会结束代理，下次登录后恢复。锁屏通常不等于注销。安装时须有可用的 `launchctl gui/<UID>` 域。

## Windows 10/11（Task Scheduler）

在自己的 **Windows PowerShell** 中切换到解压/克隆的目录：

```powershell
# 首先验证 SSH 能否非交互登录（将目标替换为自己的账号和节点）
ssh -o BatchMode=yes alice@login.cluster.example.org true

# 安装到执行命令的当前 Windows 账号
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\keepalivectl.ps1 install cluster alice@login.cluster.example.org

# 查看 Task Scheduler 任务状态和最近的日志
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\keepalivectl.ps1 status cluster

# 卸载指定实例
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\keepalivectl.ps1 remove cluster
```

使用当前用户的 **Task Scheduler 登录触发任务**，安装时立即启动；SSH 断开后由 PowerShell worker 每 10 秒重连，并持续运行（没有默认的 3 天任务时限）。实例配置、后台脚本和日志在 `%LOCALAPPDATA%\ssh-login-keepalive\`。无需另装 Python，通常也无需管理员权限（企业策略可能限制 Task Scheduler）。

**Windows 默认也是“用户登录期间”保活**：任务使用 `Interactive` 登录方式，注销后停止，下次登录恢复；锁屏不会主动结束会话。它不是以 SYSTEM 账户运行的开机服务，也不存储 Windows 登录密码。

Windows 内置的 OpenSSH Client 如未安装，可通过 Windows 的“可选功能”安装；请先执行 `ssh -V` 确认。不要关闭 PowerShell 任务调度器服务。

## 多节点、端口、代理与更新

实例名是自定义的 `[A-Za-z0-9_-]` 字符串，可以在同一个客户端安装多个实例，如：

```bash
./keepalivectl install lab-a alice@cluster-a
./keepalivectl install lab-b alice@cluster-b
```

Windows 相应通过 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\keepalivectl.ps1 install ...` 安装。该执行策略参数仅用于本次命令，不会永久修改机器策略。同名再次 `install` 会先测试新目标，再更新现有配置并重启该实例；`remove` 只移除指定实例。

建议将端口、ProxyJump、IdentityFile 等配置写入**执行端自己的 SSH config**，再使用别名：

```sshconfig
Host cluster-a
    HostName login.cluster.example.org
    User alice
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
```

然后用 `alice@cluster-a` 安装。运行在不同电脑上的实例分别读取**那台电脑**的 SSH 配置和私钥；这不是跨机器部署工具。

## 状态与限制

| 安装端 | 服务管理器 | 何时自动启动 | 注销后继续？ |
| --- | --- | --- | --- |
| Linux + systemd | 用户级 systemd service | 用户登录；源端 `Linger=yes` 时还能开机运行 | **只有客户端已启用 linger 才可以** |
| macOS | 当前用户 LaunchAgent | 用户登录 | **不可以** |
| Windows | 当前用户 Task Scheduler | 用户登录；安装后立即启动 | **不可以** |

服务显示 `active/running`，只说明客户端维持着进程；**不代表远端计算任务健康**。网络断开、客户端休眠、目标节点重启、权限失效、PAM 策略变化均可能使保活失效。如果集群禁止长时间 SSH 登录，本程序不应作为绕过管理员设置的办法。

### 诊断

- Linux：`systemctl --user status ssh-login-keepalive@cluster.service`；`journalctl --user -u ssh-login-keepalive@cluster.service -n 50`
- macOS：`./keepalivectl status cluster`；检查上述 `.log` 日志
- Windows：使用上面的 `powershell.exe ... status cluster` 命令；检查 `%LOCALAPPDATA%\ssh-login-keepalive\cluster.log`

SSH 首次连接需**交互式核对并确认真实 host key**，再执行安装；所有安装脚本都会先运行 `BatchMode=yes` 的预检查，失败则不会覆盖已有的同名配置。
