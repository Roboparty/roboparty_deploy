# Python SDK

[项目首页](../README_CN.md) | [English](python_sdk.md)

所有操作命令均在仓库根目录执行。

环境加载方式见[通用操作](operation_CN.md)，也可将下方 Humble 示例替换为 Jazzy 的 setup 文件。

| 示例脚本 | 当前适用范围 |
| --- | --- |
| `scripts/imu_py_example.py` | 采用固定 HIPNUC 串口配置，对应默认 RPO 配置；用于 RP1 时须适配其 CAN 参数 |
| `scripts/motors_py_example.py` | DM/CAN 单电机示例，ID、型号和目标位置需按实际硬件修改；用于 RP1 时须适配电机类型与通信接口 |

`robot_py` 可以分别读取 `rpo/robot.yaml` 或 `rp1_24dof/robot.yaml`。示例中的关节数量、顺序和目标必须与所选配置一致。

Python SDK 提供 IMU、电机和机器人级接口，支持通过 Python 访问硬件状态与发送控制指令。

> **注意**：`imu_py`、`motors_py` 和 `robot_py` 由工作空间构建生成。运行 SDK 示例或脚本前，须完成工作空间构建，并加载 ROS 2 环境及工作空间的 `install/setup.bash`。

```bash
source /opt/ros/humble/setup.bash
colcon build --symlink-install
source install/setup.bash
```

> **安全提示**：电机和机器人 SDK 会直接控制真实硬件。运行前须确认机器人已可靠支撑、急停可用，且设备 ID、接口和型号配置正确。每个硬件设备应由单一控制进程访问。下列相对路径均以仓库根目录为当前目录。

> **提示**：Python 脚本示例位于 `scripts/` 目录。

传入 SDK 的硬件配置参数及关节/电机顺序见 [YAML 配置参考](configuration_CN.md#机器人硬件配置)。

## 1. IMU SDK (`imu_py`)

### 静态方法

- `create_imu(imu_id: int, interface_type: str, interface: str, imu_type: str, baudrate: int = 0) -> IMUDriver`: 创建 IMU 驱动。当前支持 `HIPNUC` 的 `serial` / `can` 接口，以及 `MCT7123` 的 `serial` / `canfd` 接口。

`interface` 为串口设备节点（如 `/dev/ttyUSB0`）或 SocketCAN 接口名（如 `can0`）。串口和 CAN 配置都会读取并传递 `baudrate`：串口用它设置通信速率，CAN 则使用已配置为相同波特率的 SocketCAN 接口。`imu_id` 在 CAN 模式下用于匹配设备报文，串口模式下仅作为配置 ID 保存。

### 成员方法

- `get_imu_id() -> int`: 返回驱动实例中保存的 IMU 配置 ID，取值来自实例创建参数。
- `get_ang_vel() -> List[float]`: 获取最新缓存的角速度 `[x, y, z]` (rad/s)。
- `get_quat() -> List[float]`: 获取最新缓存的四元数 `[w, x, y, z]`。
- `get_lin_acc() -> List[float]`: 获取最新缓存的线加速度 `[x, y, z]` (m/s²)。
- `get_temperature() -> float`: 获取缓存的温度 (°C)；当前串口实现中，该字段保持初始值。

getter 返回 IMU 坐标系中的异步反馈缓存，缓存初始值为零。接口未提供时间戳或就绪状态，应用需等待首个有效数据，并实现超时与断线处理。

### 使用示例

```python
import time
import imu_py
imu = imu_py.IMUDriver.create_imu(8, "serial", "/dev/ttyUSB0", "HIPNUC", 921600)
time.sleep(0.1)  # 反馈异步更新，先等待首帧
quat = imu.get_quat()
```

## 2. 电机 SDK (`motors_py`)

`MotorControlMode` 的有效控制模式为 `MIT`、`POS` 和 `SPD`。`NONE` 用于标识模式尚未设置，控制调用须使用有效模式。

### 静态方法

- `create_motor(motor_id: int, interface_type: str, interface: str, motor_type: str, motor_model: int, master_id_offset: int = 0, motor_zero_offset: float = 0.0) -> MotorDriver`: 创建电机驱动并立即打开通信接口。

支持 `DM`、`EVO`、`LRO`、`RP`、`XYN`；DM/EVO 可使用 CAN 或 CAN-FD，LRO/XYN 使用 CAN-FD，RP 的传输方式以驱动实现为准。`interface` 为接口名（如 `can0`），`motor_model` 必须与实际型号一致，`master_id_offset` 仅 DM 使用，`motor_zero_offset` 为以 rad 计的软件位置偏移。

### 成员方法

- `init_motor() -> int`: 初始化并使能电机，返回对应驱动定义的状态码或错误码；返回值须按该驱动的约定解释。
- `deinit_motor()`: 发送失能指令。
- `set_motor_control_mode(mode: MotorControlMode)`: 设置控制模式。
- `motor_mit_cmd(pos: float, vel: float, kp: float, kd: float, torque: float)`: 发送单电机 MIT 指令。位置为 rad，速度为 rad/s，前馈力矩按 N·m 使用，`kp`/`kd` 为驱动协议的刚度/阻尼增益。
- `motors_mit_cmd(f_p: List[float], f_v: List[float], f_kp: List[float], f_kd: List[float], f_t: List[float])`: 发送最多 8 个槽位的批量 MIT 指令；支持情况取决于驱动。
- `motor_pos_cmd(pos: float, spd: float, ignore_limit: bool = False)`: 发送位置指令，单位分别为 rad 和 rad/s。当前驱动的限位处理按各自实现执行，`ignore_limit` 参数未参与该过程。
- `motor_spd_cmd(spd: float)`: 发送速度指令 (rad/s)。
- `set_motor_zero() -> None`: 发送硬件标零命令；该命令不返回即时反馈结果，标零完成后须重新给电机上下电。
- `write_motor_flash() -> bool`: 请求保存参数并返回驱动结果。
- `get_motor_param(param_cmd: int)`: 提交驱动参数读取请求；当前 Python 接口未提供同步参数返回值。
- `reset_motor_id()`: 按驱动规则重置硬件 ID。
- `clear_motor_error()`: 发送清错指令。
- `get_motor_pos() -> float`: 获取最新缓存的位置 (rad)。
- `get_motor_spd() -> float`: 获取最新缓存的速度 (rad/s)。
- `get_motor_current() -> float`: 获取最新缓存的力矩/电流反馈；物理量取决于驱动。
- `get_motor_temperature() -> float`: 获取最新缓存的温度 (°C)。
- `get_error_id() -> int`: 获取缓存的错误码。
- `get_motor_id() -> int`: 获取本地电机 ID。
- `get_motor_control_mode() -> int`: 获取本地控制模式。
- `get_response_count() -> int`: 获取离线检测计数器；控制请求时递增，收到反馈时清零。推理节点按配置的 `dt` 换算计数，连续 100 ms 未收到反馈才判定离线。
- `refresh_motor_status()`: 执行驱动相关的状态刷新。
- `get_can_name() -> str`: 返回创建时配置的 CAN/CAN-FD 接口名。

首次控制或切换模式前，应调用 `set_motor_control_mode()` 完成模式设置。模式未预先设置时，本次控制调用可能仅执行模式切换，目标发送需后续调用。反馈 getter 的数据来源为异步缓存；主动刷新通过驱动相关的状态刷新接口执行。

批量控制、参数持久化、ID 重置和状态刷新的支持情况取决于驱动，使用前须核对对应驱动实现。

### 使用示例

```python
import motors_py
motor = motors_py.MotorDriver.create_motor(1, "can", "can0", "DM", 0, 16)
try:
    motor.init_motor()
    motor.set_motor_control_mode(motors_py.MotorControlMode.MIT)
    # kp=0，仅施加阻尼，不跟踪位置目标
    motor.motor_mit_cmd(0.0, 0.0, 0.0, 1.0, 0.0)
finally:
    motor.deinit_motor()
```

## 3. 机器人 SDK (`robot_py`)

`RobotInterface` 提供机器人级控制接口，根据配置文件创建电机与 IMU 驱动。

### 构造函数

- `RobotInterface(config_file: str)`: 读取 YAML 并创建电机和 IMU 驱动。构造阶段打开通信接口，电机使能通过 `init_motors()` 执行；相对路径按当前工作目录解析。

所有关节向量均采用配置中的逻辑关节顺序。`p`、`kp`、`kd`、`reset_joints()` 的目标以及非空的 `v`、`tau` 必须与电机数量一致。调用方按逻辑关节顺序传入所选策略的 `kp`/`kd`；接口通过 `urdf2motor` 将关节向量映射到电机顺序。`reset_joints()` 和 `apply_action()` 会检查长度和数值有效性。

### 成员方法

- `init_motors() -> None`: 初始化并使能所有电机。
- `deinit_motors() -> None`: 失能所有电机。
- `apply_action(p: List[float], v: List[float], kp: List[float], kd: List[float], tau: List[float] = []) -> None`: 发送关节 MIT 指令；位置为 rad、速度为 rad/s、`tau` 为前馈力矩。`v` 为必填参数；空的 `v`/`tau` 使用零值。`kp`/`kd` 必须传入且有限，`kp` 为正、`kd` 非负。指令发送以电机已初始化为前置条件；未初始化时函数直接返回。
- `reset_joints(joint_default_angle: List[float], kp: List[float], kd: List[float]) -> None`: 用约 4 秒将机器人平滑移动到目标角度；`kp`/`kd` 的校验规则与 `apply_action()` 相同。
- `read_joints() -> None`: 基于电机异步反馈缓存，转换为逻辑关节顺序并更新关节缓存。
- `refresh_joints() -> None`: 调用各驱动刷新状态，等待 1 秒后更新关节缓存；具体刷新行为取决于驱动。
- `read_imu() -> None`: 将 IMU 异步缓存转换到机身坐标系并更新 IMU 缓存。
- `set_zeros() -> None`: 将当前电机轴位置设为硬件零点；配置中的软件偏移保持原值，关节缓存需通过对应读取或刷新接口更新。
- `clear_errors() -> None`: 向所有电机发送清错指令。
- `get_joint_q() -> List[float]`: 获取缓存的逻辑关节位置 (rad)。
- `get_joint_vel() -> List[float]`: 获取缓存的逻辑关节速度 (rad/s)。
- `get_joint_tau() -> List[float]`: 获取缓存的逻辑关节 effort；其底层物理量和单位取决于电机驱动。
- `get_quat() -> List[float]`: 获取最近一次 `read_imu()` 写入的机身四元数 `[w, x, y, z]`。
- `get_ang_vel() -> List[float]`: 获取最近一次 `read_imu()` 写入的机身角速度 `[x, y, z]` (rad/s)。

getter 返回 `RobotInterface` 的本地缓存。读取前应调用对应的 `read_*()` 或 `refresh_joints()` 更新缓存。

### 属性

- `is_init: bool`: 只读属性，记录初始化调用后尚未去初始化的软件状态。电机在线状态与故障信息须依据各驱动反馈判定。

### 使用示例

```python
import robot_py
robot = robot_py.RobotInterface("src/inference/robots/rpo/robot.yaml")
try:
    robot.init_motors()
    robot.refresh_joints()
    joint_q = robot.get_joint_q()
    kp = [40.0] * len(joint_q)  # 使用所选策略的增益
    kd = [2.0] * len(joint_q)
    robot.apply_action(joint_q, [], kp, kd)
finally:
    if robot.is_init:
        robot.deinit_motors()
```
