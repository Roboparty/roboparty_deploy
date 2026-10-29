# RPO 部署

[项目首页](../README_CN.md) | [English](rpo_deploy.md)

除源码获取命令外，所有操作均在主控的仓库根目录执行。

本文适用于 `rpo` 的 23 电机 DM/CAN 配置。[环境准备](#环境准备)和[构建与环境加载](operation_CN.md)为部署前置条件，硬件接线、电机标零和软件启动按下述流程执行。本文的 CAN 映射、串口和腰部零偏只适用于 RPO。以下手动加载环境的命令以 Humble 为例，Jazzy 使用其对应的 setup 文件。

`robot.yaml`、策略 YAML、相机与标零参数的定义及数组顺序见 [YAML 配置参考](configuration_CN.md)。

## 环境准备

### 主控连接

原 RPO 部署文档所列验证平台为 **Orange Pi 5 Plus** 与 **RDK X5**。

- **Orange Pi 5 Plus**: 系统为 `Ubuntu 22.04`，内核版本为 `5.10`
- **RDK X5**: 系统为 `Ubuntu 22.04`，内核版本为 `6.1.83`

关于主控的连接方法和相关资料，参见 [Orange Pi 5 Plus Wiki](http://www.orangepi.cn/orangepiwiki/index.php/Orange_Pi_5_Plus) 与 [RDK X5 Doc](https://d-robotics.github.io/rdk_doc/Quick_start/hardware_introduction/rdk_x5)。

系统版本资料见 [Ubuntu 22.04](https://releases.ubuntu.com/22.04/)。配置[实时优先级](#实时优先级)时，应使用实际用户名，例如 Orange Pi 的 `orangepi` 或 RDK X5 的 `sunrise`。

### 软件依赖

1. 安装 ROS 2 Humble 或 Jazzy，分别参考 [Humble 安装文档](https://docs.ros.org/en/humble/Installation.html) 或 [Jazzy 安装文档](https://docs.ros.org/en/jazzy/Installation.html)。操作系统与 ROS 版本须符合对应安装文档。启动脚本的自动检测行为见[通用操作](operation_CN.md)。

2. 在主控上安装部署依赖，包括 `ccache`、`fmt`、`spdlog`、`eigen3`、`screen` 和 zlib：

   ```bash
   sudo apt update && sudo apt install -y ccache libfmt-dev libspdlog-dev libeigen3-dev screen zlib1g-dev
   ```

3. 手柄控制依赖 ROS 2 的 `joy` 包，安装命令如下：

   ```bash
   # Humble
   sudo apt install -y ros-humble-joy
   ```

   Jazzy 对应的安装命令：

   ```bash
   sudo apt install -y ros-jazzy-joy
   ```

4. 使用仓库中的 Python 脚本（如 `scripts/set_zero.py`）时，安装以下 Python 依赖：

   ```bash
   sudo apt install -y python3-yaml python3-numpy
   ```

### 获取源码

获取部署代码并初始化子模块：

```bash
git clone --recursive https://github.com/Roboparty/roboparty_deploy.git
cd roboparty_deploy
git submodule update --init --recursive
```

### 实时优先级

配置运行账户的实时优先级权限：

```bash
sudo nano /etc/security/limits.conf
```

在文件末尾添加以下配置，**将 `your_username` 替换为实际用户名**：

```bash
# Allow your user to set real-time priorities
your_username   -   rtprio   98
your_username   -   memlock  unlimited
```

重启设备应用配置，并检查实时优先级上限：

```bash
ulimit -r
```

> **提示**：预期输出为 **98**。

### 实时内核

Orange Pi 5 Plus 的 **5.10 实时内核**安装命令如下：

> **注意**：RDK X5 使用项目提供的预装实时内核镜像，跳过本节安装命令。

```bash
cd assets
sudo apt install ./*.deb
cd ..
```

### AP 配置（可选）

WiFi 热点（AP）用于主控的无线调试连接，配置文件位于 `tools/create_ap` 目录。

> **注意**：单网卡在 AP 模式下连接外部无线网络的能力受限。
>
> - 下载软件包或部署依赖时，主控应通过**有线网络**访问外网。
> - 恢复无线网络连接前，停止 AP 服务。执行该操作需通过外接显示器或有线网络登录主控：
>   ```bash
>   sudo systemctl stop create_ap.service
>   ```

1. 安装 AP 工具并授予执行权限：

   ```bash
   sudo cp tools/create_ap/create_ap /usr/bin/
   sudo chmod +x /usr/bin/create_ap
   ```

2. 部署 systemd 服务文件：

   ```bash
   sudo cp tools/create_ap/create_ap.service /etc/systemd/system/
   ```

3. 按主控型号部署配置文件：

   **Orange Pi 5 Plus**：

   ```bash
   sudo cp tools/create_ap/create_ap_orangepi.conf /etc/create_ap.conf
   ```

   **RDK X5**：

   ```bash
   sudo cp tools/create_ap/create_ap_sunrise.conf /etc/create_ap.conf
   ```

   > **说明**：默认配置下的热点名称（`SSID`）为 **`atom`**，连接密码（`PASSPHRASE`）为 **`jujujuju`**。热点名称和密码通过 `/etc/create_ap.conf` 中的对应字段配置。

4. 设置开机自启并启动 AP 服务：

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable create_ap.service
   sudo systemctl start create_ap.service
   ```

## 硬件配置

硬件连接前应完成电机 ID、IMU 波特率及输出频率配置。

**电机 ID** 按 [产品安装手册](https://roboparty.feishu.cn/wiki/OiO2wF4NiiE08Yk1yJjcgnumnUw) 中的定义配置，设置工具为达妙上位机，操作方法见 [达妙科技文档](https://gitee.com/kit-miao/damiao-document)。

**IMU** 的默认波特率为 **`921600`**，输出频率为 **`500HZ`**。上位机配置方法见 [HiPNUC 产品手册](https://www.hipnuc.com/resource_hi14.html)。
> **提示**：IMU 输出频率须 **大于 200HZ**。采用其他波特率时，应同步更新 `src/inference/robots/rpo/robot.yaml` 中的 IMU 配置。

## 硬件连接

电机驱动的默认 CAN 映射如下。未配置固定绑定时，接口按 USB 转 CAN 设备的接入顺序编号，首个接口为 `can0`：
- **`can0`** 对应 **左腿**
- **`can1`** 对应 **右腿加腰**
- **`can2`** 对应 **左手**
- **`can3`** 对应 **右手**

> **建议**：USB 转 CAN 适配器建议连接主控的 **USB 3.0 接口**。使用 USB 扩展坞时，应选用 USB 3.0 扩展坞并连接 USB 3.0 接口；IMU 和手柄可连接 USB 2.0 接口。接线方法见 [走线说明](https://roboparty.feishu.cn/wiki/QeY2wozbiiIivlkBfdccvqVlnog)。

### 方式一：手动配置（不推荐）
未配置 udev 规则时，USB 转 CAN 设备须按上述顺序接入。设备及 IMU 接入后，手动配置 CAN 接口与 IMU 串口权限：

```bash
# CAN 配置
sudo ip link set canX up type can bitrate 1000000
sudo ip link set canX txqueuelen 1000
# canX 依次取 can0、can1、can2、can3；每个接口均执行上述两条命令

# IMU 配置
sudo chmod 666 /dev/ttyUSB0
```

### 方式二：使用 udev 规则自动绑定（推荐）
udev 规则按 USB 物理端口绑定设备，使接口命名与配置独立于设备接入顺序。仓库提供 `99-auto-up-devs-orangepi.rules` 和 `99-auto-up-devs-sunrise.rules` 两个示例，适用于接线方式与 [走线说明](https://roboparty.feishu.cn/wiki/QeY2wozbiiIivlkBfdccvqVlnog) 完全一致的设备。

采用其他接线方式时，应将规则中的 `KERNELS` 项更新为实际 USB 端口。通过以下命令监视 USB 事件：

```bash
sudo udevadm monitor
```

设备接入时，监视输出包含对应 USB 端口的设备路径。例如，路径 `/devices/pci0000:00/0000:00:14.0/usb3/3-8` 对应的 `KERNELS` 匹配值为 `3-8`。通过扩展坞接入的端口使用 `3-8.x` 形式，应按实际端口路径填写。

完成规则配置后，安装并重新加载规则：

```bash
# RDK X5 使用 assets/99-auto-up-devs-sunrise.rules
sudo cp assets/99-auto-up-devs-orangepi.rules /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger
```

重启主控应用配置。

udev 规则同时包含 IMU 串口配置。规则生效后，各 CAN 接口应自动完成配置并启用，使用 `ip a` 检查接口状态。

## 电机标零（首次使用/零点丢失时）

> **说明**：电机标零在首次部署时执行。电机检修、更换或零点丢失后，应重新标定。

仓库提供以下两种零点标定方式：

- `ros2 service call /set_zeros std_srvs/srv/Trigger`
  将当前关节位置作为硬件标零命令发送。调用条件为机器人软件已启动、电机已初始化且推理已停止。
- `python3 scripts/set_zero.py --config scripts/config/set_zero_rpo.yaml`
  按电机逐项进行人工摆位标零，适用于首次装机、检修后重标定或部分电机重标定。

使用 `/set_zeros` 服务时，建议按以下顺序操作：

1. 在仓库根目录运行 `./tools/start_robot.sh`；脚本完成工作空间构建，生成 `install/setup.bash`，通过后台 `screen` 会话启动软件后返回调用终端。
2. 脚本启动成功并返回后，在同一终端加载 ROS2 和工作空间环境。
3. 调用 `/init_motors` 初始化电机。
4. 确认机器人处于目标零位，且此时没有运行推理。
5. 调用 `/set_zeros` 发送标零命令。
6. 标零结束后重新给电机上下电，使新的零点生效。

```bash
# 仓库根目录；以下命令均在同一终端执行
./tools/start_robot.sh
source /opt/ros/humble/setup.bash
source install/setup.bash
ros2 service call /init_motors std_srvs/srv/Trigger
ros2 service call /set_zeros std_srvs/srv/Trigger
```

使用脚本 `scripts/set_zero.py` 时：

1. 在仓库根目录加载 ROS2 环境。
2. 编译工作空间，生成 `install/setup.bash`。
3. 在当前终端加载工作空间环境。
4. 确认 CAN 接口与 udev 映射已正常生效。
5. 核对 `scripts/config/set_zero_rpo.yaml` 中的电机 ID、CAN 接口和电机型号，确保配置与实际硬件一致。
6. 在可交互终端中运行脚本后，按提示将当前电机手动摆到零位。
7. 按 `Enter` 发送该电机的标零命令，按空格跳过当前电机。
8. 标零结束后重新给电机上下电，使新的零点生效。

```bash
source /opt/ros/humble/setup.bash
colcon build --symlink-install
source install/setup.bash
python3 scripts/set_zero.py --config scripts/config/set_zero_rpo.yaml
```

`scripts/set_zero.py` 按 `scripts/config/set_zero_rpo.yaml` 中的顺序标定各电机，标定期间使用阻尼模式支持人工摆位。

## 启动软件

> **警告**：启动前须完成电机零点标定，并阅读 **[安全操作指南](https://roboparty.feishu.cn/wiki/ZGtnwpHCjii2XykBYMGchoBBnSl)**。

`src/inference/robots/rpo/robot.yaml` 中的软件零点偏移须与标定方式一致：

```yaml
motor_zero_offset: 
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
     0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.093,
     0.0, 0.0, 0.0, 0.0, 0.0,
     0.0, 0.0, 0.0, 0.0, 0.0]
```

- 采用**腰部 yaw 限位块**作为标定基准：保留 `2.093`。
- 采用**打印件固定腰部 yaw**作为标定基准：将 `2.093` 改为 `0.0`。

完成上述配置后，启动机器人软件：

```bash
./tools/start_robot.sh
```

默认启动配置为 `rpo` 机器人和 `default` 策略。显式指定机器人与策略的命令如下：

```bash
./tools/start_robot.sh --robot rpo --policy amp
./tools/start_robot.sh rpo beyondmimic
```

`./tools/start_robot.sh` 会自动执行 `colcon build --symlink-install` 编译工作空间，并在后台启动以下两个 `screen` 会话：

- `inference_session`：推理节点
- `joy_session`：手柄节点

查看后台会话输出：

```bash
screen -r inference_session
screen -r joy_session
```

终止对应后台会话：

```bash
screen -S inference_session -X quit
screen -S joy_session -X quit
```

`policy` 参数指定 `src/inference/robots/rpo/configs/` 下的策略配置：

```bash
./tools/start_robot.sh --robot rpo --policy default
./tools/start_robot.sh --robot rpo --policy amp
./tools/start_robot.sh --robot rpo --policy beyondmimic
./tools/start_robot.sh --robot rpo --policy getup
./tools/start_robot.sh --robot rpo --policy interrupt
./tools/start_robot.sh --robot rpo --policy parkour
```

`parkour` 依赖 `/depth_obs` 深度观测。启动机器人推理前，应在独立终端启动 RealSense 与深度处理：

```bash
./tools/start_camera.sh --policy parkour
```

手柄、服务接口和日志操作见[通用操作](operation_CN.md)。
