# 更新已有 Docker 部署

`update-existing.sh` 用于把已经运行的 Sub2API Docker Compose 部署更新到本仓库 `main` 分支的最新代码。

脚本只重新构建并重建 `sub2api` 应用容器，不会执行 `docker compose down`，也不会停止或重建 PostgreSQL、Redis，不会删除或替换原有 volume、数据目录、`.env` 或 `config.yaml`。

## 首次使用

在部署服务器上克隆本仓库：

```bash
git clone https://github.com/bowie-xz8090/sub2api.git
cd sub2api
chmod +x deploy/update-existing.sh
deploy/update-existing.sh
```

脚本会从当前运行的 `sub2api` 容器标签中自动识别原来的 Compose 文件和项目名。因此，原部署目录与本仓库不在同一路径也可以正常更新，但原 Compose 文件必须仍然存在。

以后更新时重复执行：

```bash
cd sub2api
deploy/update-existing.sh
```

请使用具备 Docker 访问权限的账号执行。若必须使用 root，请让仓库也由 root 克隆或将仓库加入 Git 的 `safe.directory`，避免 Git 拒绝读取其他用户拥有的工作树。

## 无法自动识别时

显式指定原部署使用的文件。下面示例适用于本地目录持久化版本：

```bash
deploy/update-existing.sh \
  --compose-file /opt/sub2api/docker-compose.local.yml \
  --env-file /opt/sub2api/.env \
  --project-name sub2api \
  --project-dir /opt/sub2api
```

如果原部署叠加了多个 Compose 文件，需要按原来的顺序重复传入：

```bash
deploy/update-existing.sh \
  -f /opt/sub2api/docker-compose.yml \
  -f /opt/sub2api/docker-compose.prod.yml \
  --env-file /opt/sub2api/.env \
  --project-name sub2api
```

## 更新过程

1. 检查当前仓库没有未提交的已跟踪文件修改。
2. 从 `origin/main` 获取最新提交，只允许 fast-forward 更新。
3. 使用最新源码构建带提交号的本地 Docker 镜像。
4. 将 PostgreSQL、容器内 `config.yaml` 和部署 `.env` 备份到原 Compose 文件目录下的 `backups/<UTC时间>/`。
5. 仅执行 `docker compose up -d --no-deps --force-recreate sub2api`。
6. 等待应用健康检查；失败时自动恢复更新前的应用镜像。

数据库迁移是前向迁移。应用镜像自动回退不会反向恢复数据库；如需恢复数据库，应使用更新前生成的 `postgres.dump`。

## 常用参数

```text
--skip-git          不拉取代码，直接构建当前 checkout
--no-backup         跳过更新前备份（不建议）
--remote NAME       指定 Git remote，默认 origin
--branch NAME       指定更新分支，默认 main
--project-dir DIR   指定原 Compose 项目目录，确保相对挂载路径不变
--health-timeout N  健康检查等待秒数，默认 180
```

## 数据保留说明

- PostgreSQL 数据仍位于原来的命名卷或 `postgres_data/` 目录。
- Redis 数据仍位于原来的命名卷或 `redis_data/` 目录。
- `/app/data` 使用原挂载，已有 `config.yaml`、密钥及应用数据不会被覆盖。
- 原 `.env` 仅被读取，不会被脚本修改。
- 脚本不包含 `down`、`down -v`、volume 删除或数据目录删除操作。
