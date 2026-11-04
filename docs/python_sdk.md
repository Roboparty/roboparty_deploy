# Python SDK

[Project Home](../README.md) | [中文](python_sdk_CN.md)

Run all commands from the repository root.

See [Common Operation](operation.md) for environment loading, or replace the Humble setup path below with the Jazzy setup path.

| Example script | Current scope |
| --- | --- |
| `scripts/imu_py_example.py` | Fixed HIPNUC serial settings match the default RPO configuration; RP1 use requires adaptation to its CAN parameters |
| `scripts/motors_py_example.py` | DM/CAN single-motor example; verify ID, model, and target position against the hardware before use; RP1 use requires adaptation to its motor type and communication interface |

`robot_py` can read either `rpo/robot.yaml` or `rp1_24dof/robot.yaml`. Joint counts, ordering, and targets must match the selected configuration.

The Python SDK provides IMU, motor, and robot interfaces for accessing hardware state and sending control commands.

> **Note**: The `imu_py`, `motors_py`, and `robot_py` modules are generated from the workspace build output. Build the workspace and load the ROS 2 environment and workspace `install/setup.bash` before running SDK examples or scripts.

```bash
source /opt/ros/humble/setup.bash
colcon build --symlink-install
source install/setup.bash
```

> **Safety**: The motor and robot SDKs directly control real hardware. Before use, securely support the robot, make an emergency stop available, and verify all device IDs, interfaces, and models. Use a single control process for each hardware device. Relative paths below assume the repository root is the current directory.

> **Tip**: Python script examples are located in `scripts/`.

See [YAML Configuration Reference](configuration.md#robot-hardware-configuration) for hardware fields and joint/motor ordering.

## 1. IMU SDK (`imu_py`)

### Static Methods

- `create_imu(imu_id: int, interface_type: str, interface: str, imu_type: str, baudrate: int = 0) -> IMUDriver`: Create an IMU driver. Supported combinations are `HIPNUC` with `serial` / `can`, and `MCT7123` with `serial` / `canfd`.

`interface` is a serial device such as `/dev/ttyUSB0` or a SocketCAN interface such as `can0`. Both serial and CAN configurations read and pass `baudrate`: serial uses it as the communication rate, while CAN uses a SocketCAN interface configured to the same bitrate. In CAN mode, `imu_id` identifies incoming device frames; in serial mode, it is stored only as a configuration ID.

### Member Methods

- `get_imu_id() -> int`: Return the IMU configuration ID stored in the driver instance, as supplied at construction.
- `get_ang_vel() -> List[float]`: Get the latest cached angular velocity `[x, y, z]` (rad/s).
- `get_quat() -> List[float]`: Get the latest cached quaternion `[w, x, y, z]`.
- `get_lin_acc() -> List[float]`: Get the latest cached linear acceleration `[x, y, z]` (m/s²).
- `get_temperature() -> float`: Get cached temperature (°C); this field retains its initial value in the current serial implementation.

Getters return asynchronous feedback caches in the IMU frame. Caches start at zero, and the interface provides no timestamp or ready flag. Applications must wait for the first valid sample and implement timeout and disconnection handling.

### Example

```python
import time
import imu_py
imu = imu_py.IMUDriver.create_imu(8, "serial", "/dev/ttyUSB0", "HIPNUC", 921600)
time.sleep(0.1)  # Feedback is asynchronous; wait for the first sample
quat = imu.get_quat()
```

## 2. Motor SDK (`motors_py`)

Valid control modes in `MotorControlMode` are `MIT`, `POS`, and `SPD`. `NONE` indicates that a mode has yet to be set; control calls require a valid mode.

### Static Methods

- `create_motor(motor_id: int, interface_type: str, interface: str, motor_type: str, motor_model: int, master_id_offset: int = 0, motor_zero_offset: float = 0.0) -> MotorDriver`: Create a motor driver and immediately open its communication interface.

Supported motor types are `DM`, `EVO`, `LRO`, `RP`, and `XYN`. DM/EVO use CAN or CAN-FD, while LRO/XYN use CAN-FD. RP transport support is defined by its driver. `interface` is an interface name such as `can0`, `motor_model` must match the hardware, only DM uses `master_id_offset`, and `motor_zero_offset` is a software position offset in radians.

### Member Methods

- `init_motor() -> int`: Initialize and enable the motor. Interpret the returned status or error code according to the corresponding driver's conventions.
- `deinit_motor()`: Send a disable command.
- `set_motor_control_mode(mode: MotorControlMode)`: Set the control mode.
- `motor_mit_cmd(pos: float, vel: float, kp: float, kd: float, torque: float)`: Send a single-motor MIT command. Position is in radians, velocity in rad/s, feed-forward torque is used as N·m, and `kp`/`kd` are the stiffness/damping gains defined by the driver protocol.
- `motors_mit_cmd(f_p: List[float], f_v: List[float], f_kp: List[float], f_kd: List[float], f_t: List[float])`: Send batched MIT commands for up to eight slots; support depends on the driver.
- `motor_pos_cmd(pos: float, spd: float, ignore_limit: bool = False)`: Send a position command in radians with speed in rad/s. Current drivers apply limits according to their implementations; `ignore_limit` is unused in this process.
- `motor_spd_cmd(spd: float)`: Send a speed command (rad/s).
- `set_motor_zero() -> None`: Send the hardware-zero command. The command has no immediate feedback result; power-cycle the motor before using the new zero.
- `write_motor_flash() -> bool`: Request parameter persistence and return the driver result.
- `get_motor_param(param_cmd: int)`: Submit a driver parameter read request; the current Python interface provides no synchronous parameter return value.
- `reset_motor_id()`: Reset the hardware ID according to the driver rules.
- `clear_motor_error()`: Send a clear-error command.
- `get_motor_pos() -> float`: Get the latest cached position (rad).
- `get_motor_spd() -> float`: Get the latest cached speed (rad/s).
- `get_motor_current() -> float`: Get the latest cached torque/current feedback; the physical quantity depends on the driver.
- `get_motor_temperature() -> float`: Get the latest cached temperature (°C).
- `get_error_id() -> int`: Get the cached error code.
- `get_motor_id() -> int`: Get the local motor ID.
- `get_motor_control_mode() -> int`: Get the local control mode.
- `get_response_count() -> int`: Get the offline-detection counter; control requests increment it and feedback clears it. The inference node uses the configured `dt` and reports offline after 100 ms without feedback.
- `refresh_motor_status()`: Perform a driver-specific status refresh.
- `get_can_name() -> str`: Return the CAN/CAN-FD interface name configured at construction.

Call `set_motor_control_mode()` before the first control command or a mode change. If the mode has yet to be set, a control call may only switch modes, requiring a subsequent call to send the target. Feedback getters read asynchronous caches; active refresh uses driver-specific status refresh interfaces.

Support for batched control, parameter persistence, ID reset, and status refresh depends on the driver; check the corresponding implementation before use.

### Example

```python
import motors_py
motor = motors_py.MotorDriver.create_motor(1, "can", "can0", "DM", 0, 16)
try:
    motor.init_motor()
    motor.set_motor_control_mode(motors_py.MotorControlMode.MIT)
    # kp=0 applies damping without tracking a position target
    motor.motor_mit_cmd(0.0, 0.0, 0.0, 1.0, 0.0)
finally:
    motor.deinit_motor()
```

## 3. Robot SDK (`robot_py`)

`RobotInterface` provides robot-level control and creates motor and IMU drivers from the configuration file.

### Constructor

- `RobotInterface(config_file: str)`: Read the YAML file and create the motor and IMU drivers. Construction opens communication interfaces; `init_motors()` enables the motors. Relative paths are resolved from the current working directory.

All joint vectors use the logical joint order in the configuration. `p`, `kp`, `kd`, the target passed to `reset_joints()`, and every non-empty `v` and `tau` vector must match the motor count. Pass the selected policy's `kp`/`kd` in logical joint order; the interface maps joint vectors to motor order through `urdf2motor`. `reset_joints()` and `apply_action()` validate lengths and values.

### Member Methods

- `init_motors() -> None`: Initialize and enable all motors. Driver return codes are not returned to Python.
- `deinit_motors() -> None`: Disable all motors.
- `apply_action(p: List[float], v: List[float], kp: List[float], kd: List[float], tau: List[float] = []) -> None`: Send joint MIT commands. Position is in radians, velocity in rad/s, and `tau` is feed-forward torque. `v` is required; empty `v`/`tau` vectors use zero. `kp`/`kd` are required and must be finite; `kp` must be positive and `kd` non-negative. Command transmission requires initialized motors; the function returns immediately otherwise.
- `reset_joints(joint_default_angle: List[float], kp: List[float], kd: List[float]) -> None`: Smoothly move the robot to the target angles in about four seconds. `kp`/`kd` use the same validation as `apply_action()`.
- `read_joints() -> None`: Convert asynchronous motor feedback caches to logical joint order and update the joint cache.
- `refresh_joints() -> None`: Ask each driver to refresh status, wait one second, and update the joint cache. Exact refresh behavior depends on the driver.
- `read_imu() -> None`: Transform the asynchronous IMU cache into the body frame and update the IMU cache.
- `set_zeros() -> None`: Set each current motor-shaft position as the hardware zero. Configured software offsets retain their values; update the joint cache through the corresponding read or refresh interface.
- `clear_errors() -> None`: Send a clear-error command to all motors.
- `get_joint_q() -> List[float]`: Get cached logical joint positions (rad).
- `get_joint_vel() -> List[float]`: Get cached logical joint velocities (rad/s).
- `get_joint_tau() -> List[float]`: Get cached logical joint effort. Its underlying physical quantity and unit depend on the motor driver.
- `get_quat() -> List[float]`: Get the body-frame quaternion `[w, x, y, z]` written by the most recent `read_imu()`.
- `get_ang_vel() -> List[float]`: Get the body-frame angular velocity `[x, y, z]` (rad/s) written by the most recent `read_imu()`.

Getters return the local `RobotInterface` cache. Update the cache with the corresponding `read_*()` method or `refresh_joints()` before reading.

### Properties

- `is_init: bool`: Read-only software state indicating an initialization call without subsequent deinitialization. Determine motor availability and faults from the corresponding driver feedback.

### Example

```python
import robot_py
robot = robot_py.RobotInterface("src/inference/robots/rpo/robot.yaml")
try:
    robot.init_motors()
    robot.refresh_joints()
    joint_q = robot.get_joint_q()
    kp = [40.0] * len(joint_q)  # Use the selected policy's gains
    kd = [2.0] * len(joint_q)
    robot.apply_action(joint_q, [], kp, kd)
finally:
    if robot.is_init:
        robot.deinit_motors()
```
