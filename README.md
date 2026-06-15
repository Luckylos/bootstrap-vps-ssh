# bootstrap-vps-ssh

单文件脚本：在目标 VPS 上通过现有探针执行，自动把内置 SSH 公钥追加到 `root` 的 `authorized_keys`，必要时最小修复 SSH 公钥登录配置，然后在终端输出公网 IP 与 SSH 监听端口。

## 用途

适用于：
- 你已经能通过哪吒 / Komari / 其他探针在 VPS 上执行命令
- 你希望后续直接用自己的私钥 SSH 登录该 VPS

## 执行方式

```bash
curl -fsSL https://raw.githubusercontent.com/Luckylos/bootstrap-vps-ssh/main/bootstrap-vps-ssh.sh | bash
```

## 输出

成功时只输出两行：

```text
SSH_IP=1.2.3.4
SSH_PORT=22
```

## 固定行为

- 默认目标用户：`root`
- 脚本内置一把 SSH 公钥
- 仅在 `authorized_keys` 中不存在该公钥时追加
- 保留原有 `authorized_keys` 内容，不覆盖、不删除
- 必要时最小修复以下 SSH 配置：
  - `PubkeyAuthentication yes`
  - `AuthorizedKeysFile .ssh/authorized_keys`
  - `PermitRootLogin prohibit-password`
- 脚本为**无参数入口**；传入任意位置参数会直接报错退出

## 外部访问说明

脚本为了输出 `SSH_IP`，会主动请求公网 IPv4 查询服务：
- `https://api.ipify.org`
- `https://ipv4.icanhazip.com`
- `https://ifconfig.me/ip`

如果目标 VPS 出站受限，可在测试/调试时使用 `PUBLIC_IP_OVERRIDE` 覆盖。
如果 SSH 监听端口探测存在歧义或被极简环境限制，可使用 `SSH_PORT_OVERRIDE` 覆盖。

## 不会做的事

- 不修改防火墙
- 不修改云安全组
- 不修改 SSH 监听端口
- 不删除系统日志
- 不清理探针平台执行记录
- 不上传任何信息到第三方存储服务

## 测试/验证钩子

脚本主入口无参数，但保留了少量环境变量钩子用于本地验证，不是日常使用接口：

- `AUTHORIZED_KEYS_PATH`
- `SSHD_CONFIG_PATH`
- `PUBLIC_IP_OVERRIDE`
- `SSH_PORT_OVERRIDE`
- `SKIP_SSHD_REPAIR=1`
- `SKIP_SSHD_RELOAD=1`

## 注意

- 脚本里必须内置的是 **公钥**，不是私钥。
- 默认修复 SSH 配置时，本机需要可用的 `sshd` 命令。
