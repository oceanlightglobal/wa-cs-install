# WhatsApp AI 客服 · 安装文件

这个仓库只放安装用的几个文件，源码不在这里。

**安装命令**（在你的 Ubuntu 服务器上执行）：

```bash
curl -fsSL https://oceanlightglobal.github.io/wa-cs-install/install.sh | sudo bash
```

| 文件 | 作用 |
|---|---|
| `install.sh` | 一键安装脚本 |
| `docker-compose.yml` | 容器编排 |
| `Caddyfile` | 自动 HTTPS 配置 |
| `version.json` | 版本清单，客户后台靠它检查更新 |

这些文件都不含密钥。真正的密码和令牌是安装时在**客户自己的服务器上**随机生成的。
