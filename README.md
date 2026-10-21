# SSH Login Keepalive — Windows / macOS / Linux

在**你自己的电脑或长期在线的客户端主机**上安装一个自动重连的 SSH 登录，让远端 Linux 集群账户（即使 `Linger=no`）持续存在一个登录会话。**在哪里执行安装命令，就在哪里创建后台服务**；不依赖 `ywl`，也不修改远端服务器。

实现方式：客户端 SSH 连接远端并执行 `exec sleep infinity`。连接断开后客户端服务重试；它只维持一个 SSH 登录，**不能保证远端作业或所有 user services 一定存活**。请先确认符合集群的登录会话与后台运行政策。

## 一键安装（推荐）

无需 Git、无需下载 ZIP、无需手动修改配置文件。**在希望执行保活的那台电脑上**打开对应终端，复制一行命令：

**macOS Terminal / Linux Terminal：**

```sh
bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/Molaison/ssh-login-keepalive/main/install.sh | bash'
```

脚本通过 `uname` 自动识别 macOS / Linux，分别配置 `launchd` / `systemd --user`。

**Windows PowerShell：**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "iex (irm https://raw.githubusercontent.com/Molaison/ssh-login-keepalive/main/install.ps1 -ErrorAction Stop)"
```

脚本识别 Windows 并使用当前用户的 Task Scheduler；`-ExecutionPolicy Bypass` **仅对这次 PowerShell 进程有效**，不会更改系统策略。

安装过程会依次提示：

```text
SSH username: alice
Target SSH hostname or SSH alias: f102
```

随后自动检查免交互 SSH：

1. **已经能免交互登录**：复用当前 SSH 配置和密钥，不重新生成密钥，不修改远端。
2. **尚未配置**：如本机没有 `~/.ssh/id_ed25519`，自动生成 Ed25519 密钥（用于无人值守，**无 passphrase**，私钥仅留在本机）；否则复用现有公钥。SSH 连接远端一次，提示输入远端账号密码及服务器可能要求的 OTP，并将**公钥**追加到该账号的 `~/.ssh/authorized_keys`，不会覆盖现有条目或保存密码。
3. **验证**：再次使用 `BatchMode=yes` 测试免交互登录。成功才创建并启动保活服务；最后检查 Linux 的 systemd MainPID、macOS 的 launchd 运行状态或 Windows 的计划任务运行状态。若 SSH 仍需人工输入，**不创建新服务**。

安装完成会打印对应的 `status` 和 `remove` 命令。实例名称由用户名与主机名自动生成（示例为 `alice-f102`），**不要求用户手动编辑脚本、配置文件或输入实例名**。再次运行可以安装另一个目标；相同用户名和主机名会更新同一实例。

**关于 SSH-OTP：** 自动安装公钥 ≠ 绕过服务器强制的 OTP。某些集群要求 `publickey + keyboard-interactive/TOTP`，即使输入过一次远端密码，以后的连接仍需动态 OTP。此时脚本会停止并说明原因；如果管理员允许自动化 TOTP，可以另行配置 [ssh-otp](https://github.com/Molaison/ssh-otp)（需要独立的 TOTP secret），验证真正无人值守后再安装保活，不能仅凭一次密码自动推导或关闭 OTP。

执行远程代码前可先在 GitHub 查看 [`install.sh`](https://github.com/Molaison/ssh-login-keepalive/blob/main/install.sh) 和 [`install.ps1`](https://github.com/Molaison/ssh-login-keepalive/blob/main/install.ps1)。两条命令均从本仓库 `main` 分支下载；Windows 和 Unix shell 的启动语法不同，因此提供两条系统对应的入口，而非声称同一条命令兼容所有 shell。

## 先决条件

1. 安装端有 OpenSSH Client（`ssh` / Windows `ssh.exe`），能直接访问集群登录节点，并保持开机、联网。电脑休眠或关闭时无法保活。
2. **首次安装能够正常交互式 SSH 登录**：SSH 会自行询问远端密码、OTP 和首次连接的 host key 指纹；需人工核对真实指纹。日后服务必须能够免交互登录，集群仍强制每次手动 OTP 的情况不适用。不要把密钥放进本仓库，也不要关闭主机指纹校验。
3. 远端是有 `sleep infinity` 命令的 Linux 主机（如典型 GNU coreutils 环境）。目标账号可以是 `Linger=no`。

## 手动安装 / 高级用法

如需自己命名实例、管理多个 SSH 配置或审查后运行，也可以从 GitHub 克隆：

```bash
git clone https://github.com/Molaison/ssh-login-keepalive.git
cd ssh-login-keepalive
```

Windows 也可以使用 GitHub 的 **Code → Download ZIP** 解压，无需安装 Git。以下手动命令不是完成一键安装所必需的。

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

SSH 首次连接需**交互式核对并确认真实 host key**。一键安装在首次 SSH 验证失败时引导添加公钥，之后再次以 `BatchMode=yes` 验证；手动 `keepalivectl install` 则仍要求事先配置好免交互 SSH。密钥不会上传 GitHub，只有公钥发往用户指定的目标主机。
