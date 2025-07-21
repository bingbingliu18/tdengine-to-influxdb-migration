# 软件包目录

此目录用于存放项目所需的外部软件包，如 TDengine 安装包。

## 当前包含的软件包

- TDengine-server-3.0.5.0-Linux-x64.tar.gz：TDengine 服务器和客户端软件包

## 使用方法

脚本会自动从此目录查找所需的软件包。如果软件包不存在，脚本会尝试下载它们。

## 手动下载

如果您需要手动下载 TDengine 软件包，可以使用以下命令：

```bash
wget -O TDengine-server-3.0.5.0-Linux-x64.tar.gz https://www.taosdata.com/assets-download/3.0/TDengine-server-3.0.5.0-Linux-x64.tar.gz
```
```bash
wget -O taos-jdbcdriver-3.0.0-dist.jar https://repo1.maven.org/maven2/com/taosdata/jdbc/taos-jdbcdriver/3.0.0/taos-jdbcdriver-3.0.0-dist.jar
```
然后将下载的文件放在此目录中。
