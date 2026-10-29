# RPO Deployment

[Project Home](../README.md) | [中文](rpo_deploy_CN.md)

Run all operations from the repository root on the controller, except source retrieval commands.

This guide covers the 23-motor DM/CAN `rpo` configuration. Complete [Environment Setup](#environment-setup) and [Build and Environment Loading](operation.md), then follow the wiring, zeroing, and startup instructions below. Its CAN mapping, serial interface, and waist offset apply to RPO. Manual environment commands below use Humble; use the corresponding setup file for Jazzy.

See [YAML Configuration Reference](configuration.md) for `robot.yaml`, policy, camera, and zeroing fields and array ordering.

## Environment Setup

### Controller Connection

The original RPO deployment guide lists **Orange Pi 5 Plus** and **RDK X5** as validated platforms.

- **Orange Pi 5 Plus**: OS is `Ubuntu 22.04`, kernel version is `5.10`
- **RDK X5**: OS is `Ubuntu 22.04`, kernel version is `6.1.83`

For controller connection methods and related resources, see [Orange Pi 5 Plus Wiki](http://www.orangepi.cn/orangepiwiki/index.php/Orange_Pi_5_Plus) and [RDK X5 Doc](https://d-robotics.github.io/rdk_doc/Quick_start/hardware_introduction/rdk_x5).

See [Ubuntu 22.04](https://releases.ubuntu.com/22.04/) for OS release resources. Use the actual account name when setting [real-time permissions](#real-time-priority), for example `orangepi` on Orange Pi or `sunrise` on RDK X5.

### Software Dependencies

1. Install ROS 2 Humble or Jazzy using the [Humble installation guide](https://docs.ros.org/en/humble/Installation.html) or [Jazzy installation guide](https://docs.ros.org/en/jazzy/Installation.html). Use an operating system supported by the selected distribution. See [Common Operation](operation.md) for automatic ROS detection.

2. Install deployment dependencies on the controller, including `ccache`, `fmt`, `spdlog`, `eigen3`, `screen`, and zlib:

   ```bash
   sudo apt update && sudo apt install -y ccache libfmt-dev libspdlog-dev libeigen3-dev screen zlib1g-dev
   ```

3. Gamepad control requires the ROS 2 `joy` package:

   ```bash
   # Humble
   sudo apt install -y ros-humble-joy
   ```

   For Jazzy, use:

   ```bash
   sudo apt install -y ros-jazzy-joy
   ```

4. Install the following Python dependencies for repository scripts such as `scripts/set_zero.py`:

   ```bash
   sudo apt install -y python3-yaml python3-numpy
   ```

### Source Code

Clone the deployment repository and initialize its submodules:

```bash
git clone --recursive https://github.com/Roboparty/roboparty_deploy.git
cd roboparty_deploy
git submodule update --init --recursive
```

### Real-time Priority

Configure real-time priority permissions for the runtime account:

```bash
sudo nano /etc/security/limits.conf
```

Append the following settings to the file, **replacing `your_username` with the actual account name**:

```bash
# Allow your user to set real-time priorities
your_username   -   rtprio   98
your_username   -   memlock  unlimited
```

Restart the device to apply the configuration and check the real-time priority limit:

```bash
ulimit -r
```

> **Tip**: The expected output is **98**.

### Real-time Kernel

Install the **5.10 real-time kernel** on Orange Pi 5 Plus with the following commands:

> **Note**: RDK X5 uses the project-provided image with a preinstalled real-time kernel. Skip the installation commands in this section.

```bash
cd assets
sudo apt install ./*.deb
cd ..
```

### AP Configuration (Optional)

A WiFi access point (AP) provides a wireless debugging connection to the controller. Configuration files are located in `tools/create_ap`.

> **Note**: A single wireless adapter has limited connectivity to external wireless networks while operating in AP mode.
>
> - Use a **wired network** for external access when downloading packages or installing dependencies.
> - Stop the AP service before restoring wireless network access. This operation requires a monitor or wired connection for controller access:
>   ```bash
>   sudo systemctl stop create_ap.service
>   ```

1. Install the AP utility and grant execution permissions:

   ```bash
   sudo cp tools/create_ap/create_ap /usr/bin/
   sudo chmod +x /usr/bin/create_ap
   ```

2. Install the systemd service file:

   ```bash
   sudo cp tools/create_ap/create_ap.service /etc/systemd/system/
   ```

3. Install the configuration for the controller model:

   **Orange Pi 5 Plus**:

   ```bash
   sudo cp tools/create_ap/create_ap_orangepi.conf /etc/create_ap.conf
   ```

   **RDK X5**:

   ```bash
   sudo cp tools/create_ap/create_ap_sunrise.conf /etc/create_ap.conf
   ```

   > **Description**: Under the default configuration, the hotspot name (`SSID`) is **`atom`** and the password (`PASSPHRASE`) is **`jujujuju`**. Configure the hotspot name and password through the corresponding fields in `/etc/create_ap.conf`.

4. Enable the AP service at boot and start it:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable create_ap.service
   sudo systemctl start create_ap.service
   ```

## Hardware Configuration

Configure motor IDs, IMU baud rate, and IMU output frequency before connecting the hardware.

Configure **motor IDs** according to [RoboParty RPO Product Installation Manual](https://roboparty.feishu.cn/wiki/OiO2wF4NiiE08Yk1yJjcgnumnUw) using the Damiao configuration utility. See [Damiao Technology Docs](https://gitee.com/kit-miao/damiao-document).

The **IMU** defaults to a baud rate of **`921600`** and an output frequency of **`500HZ`**. Configuration procedures are documented in the [HiPNUC Product Manual](https://www.hipnuc.com/resource_hi14.html).
> **Tip**: The IMU output frequency must be **greater than 200HZ**. When using another baud rate, update the IMU configuration in `src/inference/robots/rpo/robot.yaml`.

## Hardware Connection

The default motor CAN mapping is listed below. Without fixed device bindings, interface numbering follows USB-to-CAN connection order, starting at `can0`:
- **`can0`** corresponds to **Left leg**
- **`can1`** corresponds to **Right leg and waist**
- **`can2`** corresponds to **Left hand**
- **`can3`** corresponds to **Right hand**

> **Recommendation**: Connect USB-to-CAN adapters to the controller's **USB 3.0 ports**. Use a USB 3.0 hub connected to a USB 3.0 port when a hub is required. The IMU and gamepad can use USB 2.0 ports. Refer to [RoboParty RPO Wiring Instructions](https://roboparty.feishu.cn/wiki/QeY2wozbiiIivlkBfdccvqVlnog).

### Method 1: Manual Configuration (Not Recommended)
Without udev rules, connect USB-to-CAN adapters in the order specified above. After connecting the adapters and IMU, configure CAN interfaces and IMU serial permissions manually:

```bash
# CAN Configuration
sudo ip link set canX up type can bitrate 1000000
sudo ip link set canX txqueuelen 1000
# Apply both commands to each interface: can0, can1, can2, can3

# IMU Configuration
sudo chmod 666 /dev/ttyUSB0
```

### Method 2: Use udev rules for automatic binding (Recommended)
udev rules bind devices to physical USB ports, making interface naming and configuration independent of connection order. The provided examples, `99-auto-up-devs-orangepi.rules` and `99-auto-up-devs-sunrise.rules`, apply to wiring that matches [RoboParty RPO Wiring Instructions](https://roboparty.feishu.cn/wiki/QeY2wozbiiIivlkBfdccvqVlnog).

For other wiring layouts, update each `KERNELS` entry to match the actual USB port. Monitor USB events with the following command:

```bash
sudo udevadm monitor
```

USB connection events include the corresponding device path. For example, `/devices/pci0000:00/0000:00:14.0/usb3/3-8` corresponds to the `KERNELS` match value `3-8`. Ports connected through a hub use the `3-8.x` form; set the value according to the actual port path.

Install and reload the completed rules:

```bash
# For RDK X5, use assets/99-auto-up-devs-sunrise.rules
sudo cp assets/99-auto-up-devs-orangepi.rules /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger
```

Restart the controller to apply the configuration.

The udev rules also configure the IMU serial port. After the rules take effect, all CAN interfaces should be configured and enabled automatically. Check interface status with `ip a`.

## Motor Zeroing (Initial Setup / Zero Loss)

> **Note**: Perform motor zeroing during initial deployment. Recalibration is required after motor servicing, replacement, or zero-point loss.

The repository provides two zero-calibration methods for different situations:

- `ros2 service call /set_zeros std_srvs/srv/Trigger`
  Use this when the robot software is already running, the motors have been initialized, and inference is not running. It sends the current joint positions as hardware-zero commands.
- `python3 scripts/set_zero.py --config scripts/config/set_zero_rpo.yaml`
  Provides manual zeroing for individual motors during initial setup, recalibration after maintenance, or partial recalibration.

For the `/set_zeros` service, the recommended sequence is:

1. From the repository root, run `./tools/start_robot.sh`. The script performs the required build, generates `install/setup.bash`, starts the software in background `screen` sessions, and then returns to the current terminal.
2. After the script starts successfully and returns, load the ROS2 and workspace environments in the same terminal.
3. Call `/init_motors` to initialize the motors.
4. Position the robot at the physical zeroing reference and verify that inference is stopped.
5. Call `/set_zeros` to send the zero commands.
6. Power-cycle the motors after zeroing so the new zero points take effect.

```bash
# Repository root; run all commands below in the same terminal
./tools/start_robot.sh
source /opt/ros/humble/setup.bash
source install/setup.bash
ros2 service call /init_motors std_srvs/srv/Trigger
ros2 service call /set_zeros std_srvs/srv/Trigger
```

For the `scripts/set_zero.py` script:

1. Load the ROS2 environment from the repository root.
2. Build the workspace to generate `install/setup.bash`.
3. Load the workspace environment in the current terminal.
4. Verify that CAN interfaces and udev mappings are operational.
5. Check or edit `scripts/config/set_zero_rpo.yaml` as needed so the motor IDs, CAN interfaces, and motor models match the hardware.
6. Run the script in an interactive terminal and manually move each motor to its target zero position when prompted.
7. Press `Enter` to send the zero command for the current motor, or press Space to skip it.
8. Power-cycle the motors after zeroing so the new zero points take effect.

```bash
source /opt/ros/humble/setup.bash
colcon build --symlink-install
source install/setup.bash
python3 scripts/set_zero.py --config scripts/config/set_zero_rpo.yaml
```

`scripts/set_zero.py` calibrates motors in the order defined in `scripts/config/set_zero_rpo.yaml` and switches each motor into damping mode during calibration so the pose can be adjusted by hand.

## Start Software

> **Warning**: Before starting the robot, ensure the robot has completed zero point calibration. Read the **[RoboParty RPO Safety Operation Guide](https://roboparty.feishu.cn/wiki/ZGtnwpHCjii2XykBYMGchoBBnSl)** before startup.

The software zero offsets in `src/inference/robots/rpo/robot.yaml` must match the calibration method:

```yaml
motor_zero_offset: 
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
     0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.093,
     0.0, 0.0, 0.0, 0.0, 0.0,
     0.0, 0.0, 0.0, 0.0, 0.0]
```

- Calibration using the **waist yaw limit block**: retain `2.093`.
- Calibration using a **3D printed fixture for waist yaw**: change `2.093` to `0.0`.

Start the robot software after completing the configuration:

```bash
./tools/start_robot.sh
```

The default startup configuration is the `rpo` robot with the `default` policy. Specify the robot and policy explicitly as follows:

```bash
./tools/start_robot.sh --robot rpo --policy amp
./tools/start_robot.sh rpo beyondmimic
```

`./tools/start_robot.sh` automatically runs `colcon build --symlink-install` to build the workspace and starts the following two `screen` sessions in the background:

- `inference_session`: inference node
- `joy_session`: joystick node

Use the following commands to inspect their output:

```bash
screen -r inference_session
screen -r joy_session
```

Use the following commands to stop the corresponding background components:

```bash
screen -S inference_session -X quit
screen -S joy_session -X quit
```

The `policy` argument selects a policy configuration from `src/inference/robots/rpo/configs/`:

```bash
./tools/start_robot.sh --robot rpo --policy default
./tools/start_robot.sh --robot rpo --policy amp
./tools/start_robot.sh --robot rpo --policy beyondmimic
./tools/start_robot.sh --robot rpo --policy getup
./tools/start_robot.sh --robot rpo --policy interrupt
./tools/start_robot.sh --robot rpo --policy parkour
```

`parkour` depends on the `/depth_obs` observation. Before starting robot inference, launch RealSense and depth processing in another terminal:

```bash
./tools/start_camera.sh --policy parkour
```

See [Common Operation](operation.md) for gamepad controls, services, and logs.
