# YAML 配置参考

[项目首页](../README_CN.md) | [English](configuration.md)

本文说明部署配置的参数定义、单位、排列顺序及关联约束。主控连接、环境准备及部署步骤见 [RPO 部署](rpo_deploy_CN.md)。

## 文件与加载方式

| 文件 | 读取方 | 用途与格式 |
| --- | --- | --- |
| `src/inference/robots/<robot>/robot.yaml` | `RobotInterface` | 硬件配置，由项目 YAML 解析器读取，顶层包含 `imu`、`motors`、`robot` |
| `src/inference/robots/<robot>/configs/<policy>.yaml` | `inference_node` | 策略参数，位于 `inference_node.ros__parameters` 下 |
| [相机 parkour.yaml](../src/camera/configs/parkour.yaml) | `depth_node` | 深度处理参数，位于 `depth_node.ros__parameters` 下 |
| [realsense_d435i.yaml](../src/camera/configs/realsense_d435i.yaml) | RealSense `rs_launch.py` | 相机启动配置，采用顶层参数结构 |
| [set_zero_rpo.yaml](../scripts/config/set_zero_rpo.yaml)、[set_zero_rp1.yaml](../scripts/config/set_zero_rp1.yaml) | `scripts/set_zero.py` | 电机标零配置，采用顶层参数结构 |

机器人启动通过 `--robot` 选择机器人目录，通过 `--policy` 选择该目录的策略配置。默认配置为 `rpo` / `default`。相机启动的 `--policy` 选择 `src/camera/configs/` 中的配置，与机器人策略配置属于不同文件。

| 机器人目录 | 电机数量 | 默认硬件 | 当前策略配置 |
| --- | --- | --- | --- |
| `rpo` | 23 | DM / CAN，HIPNUC 串口 | `default`、`amp`、`beyondmimic`、`getup`、`interrupt`、`parkour` |
| `rp1_24dof` | 24 | LRO / CAN FD，HIPNUC CAN | `default`、`beyondmimic`、`ufo` |

UFO 对应 `rp1_24dof` 的 24 电机配置；28 电机的 `rp1` 使用独立的硬件和策略配置。模型、观测、关节映射及零位参数须与所选机器人和训练配置一致。

以下示例展示 ROS 参数文件的层级结构及部分字段。完整策略还需配置模型、观测布局和关节参数：

```yaml
inference_node:
  ros__parameters:
    joint_num: 24
    dt: 0.002
    decimation: 10
```

标准 launch 从构建后的包目录加载配置。采用 `--symlink-install` 时，应检查安装目录与源文件的链接关系；新增配置文件后需重新构建。参数在节点启动时加载，YAML 修改通过重启对应节点生效。

## 机器人硬件配置

以 [RPO robot.yaml](../src/inference/robots/rpo/robot.yaml) 和 [24 电机 RP1 robot.yaml](../src/inference/robots/rp1_24dof/robot.yaml) 为例。记电机总数为 `N`，总线分组数为 `B`。

### IMU

| 参数 | 类型 / 单位 | 含义 |
| --- | --- | --- |
| `imu.imu_id` | 整数 | IMU 设备 ID；CAN 模式用于匹配报文，串口模式作为配置 ID 保存 |
| `imu.imu_interface_type` | 字符串 | 接口类型；HIPNUC 为 `serial` / `can`，MCT7123 为 `serial` / `canfd` |
| `imu.imu_interface` | 字符串 | 串口设备节点或 SocketCAN 接口名，如 `/dev/ttyUSB0`、`can_hipnuc` |
| `imu.imu_type` | 字符串 | 驱动类型，当前支持 `HIPNUC`、`MCT7123` |
| `imu.baudrate` | 整数 | 串口通信速率或 CAN 配置速率；RPO 示例为 `921600`，RP1 示例为 `1000000`。CAN 接口需按对应速率完成系统配置 |

### 电机与总线

| 参数 | 类型 / 长度 | 含义 |
| --- | --- | --- |
| `motors.motor_id` | 整数数组，`N` | 按总线分组依次拼接的电机 ID；不同总线可以有相同 ID，同一总线应避免重复 |
| `motors.motor_interface_type` | 字符串数组，`B` | 每组总线的协议，如 `can`、`canfd`；`robot.yaml` 必须使用数组 |
| `motors.motor_interface` | 字符串数组，`B` | 每组总线对应的接口名；顺序决定后续电机分组 |
| `motors.motor_num` | 整数数组，`B` | 每组总线的电机数量，总和应为 `N` |
| `motors.motor_type` | 字符串数组，`B` | 每组电机的驱动类型，如 `DM`、`LRO`；还支持 `EVO`、`RP`、`XYN` |
| `motors.motor_model` | 整数数组，`N` | 每个电机的型号枚举，用于选择对应驱动的协议范围等设置 |
| `motors.master_id_offset` | 整数 | DM 的主机反馈 ID 偏移；默认配置为 `16`，其他驱动按各自实现处理 |
| `motors.motor_zero_offset` | 数值数组，`N`，rad | 每个电机的软件位置偏移；当前 DM/LRO 在反馈中加上偏移，在位置指令中减去偏移；硬件零点通过标零操作设置 |

RPO 的 `motor_num: [6, 7, 5, 5]` 将电机数组依次划分为 6、7、5、5 个元素的四组。`motor_id`、`motor_model`、`motor_zero_offset` 须采用一致的电机排列顺序。

当前配置使用的型号枚举：

| 驱动 | `motor_model` 对应值 |
| --- | --- |
| DM | `0=DM4340P_48V`，`1=DM10010L_48V` |
| LRO | `0=LRO_5550`，`1=LRO_6562`，`2=LRO_8462`，`3=LRO_10062` |

枚举定义见 [DM 驱动](../src/motors/src/drivers/dm/dm_motor_driver.hpp)和 [LRO 驱动](../src/motors/src/drivers/lro/lro_motor_driver.hpp)。型号枚举的数值定义以所选驱动为准。

### 机器人映射与控制

| 参数 | 类型 / 长度 | 含义 |
| --- | --- | --- |
| `robot.type` | 字符串 | 闭链机构解耦类型，支持 `rpo`、`rp1`；`rp1_24dof` 对应 `rp1`，机器人目录由启动参数 `--robot` 选择 |
| `robot.kp` | 数值数组，`N` | 默认 MIT 刚度增益，按电机顺序排列 |
| `robot.kd` | 数值数组，`N` | 默认 MIT 阻尼增益，按电机顺序排列 |
| `robot.motor_sign` | 整数数组，`N` | 各电机方向，通常为 `1` / `-1`，按电机顺序排列，作用于位置、速度与 effort 转换 |
| `robot.close_chain_motor_idx` | 整数数组，当前为 4 个 | 闭链电机的零起始数组索引，对应 `motor_id` 数组中的位置，按左侧一对、右侧一对排列 |
| `robot.urdf2motor` | 整数数组，`N` | `urdf2motor[j]` 给出逻辑关节 `j` 对应的电机数组索引，应是 `0..N-1` 的完整排列 |
| `robot.extrinsic_R` | 数值数组，9 个 | IMU 安装旋转矩阵，按行展开为 3×3；当前实现的角速度转换为 `omega_body = R * omega_imu`，四元数转换为 `q_body = q_imu * inverse(q_R)` |

`robot.yaml` 的 `kp/kd` 定义运行时 MIT 控制增益，是同一机器人目录内各策略共用的默认值。调整 `rp1_24dof` 的增益会影响 default、BeyondMimic 和 UFO。闭链控制中增益还参与关节到电机的换算，应与实际机构匹配；当前换算以闭链电机的 `kp` 为分母，要求对应增益大于零。`extrinsic_R` 应为合法的旋转矩阵，并与 IMU 实际安装方向一致。

## 推理策略配置

本节参数位于 `inference_node.ros__parameters` 下。YAML 中省略的可选参数使用代码默认值，各策略可显式配置对应值。

### 模型、动作与观测布局

| 参数 | 类型 | 含义与约束 |
| --- | --- | --- |
| `model_names` | 字符串数组 | ONNX 模型列表，非空；相对路径基于该机器人 `models/`，也可使用绝对路径 |
| `motion_names` | 字符串数组 | 动作 NPZ 列表，相对路径基于 `motions/`；可省略或为空，否则长度必须与模型数一致，不使用动作的模型用 `""` 占位 |
| `latent_names` | 字符串数组 | latent NPZ 列表，相对路径基于 `latents/`；长度规则同 `motion_names`，UFO 使用其中的 float32 二维数组 `z` |
| `obs_layouts` | 字符串数组 | 每个模型的观测顺序、每项维度和可选历史 tap，必须与模型数量相同并与训练输入一致 |
| `frame_stacks` | 正整数数组 | 每个模型保留的推理历史帧数，长度与模型数相同；tap 必须小于对应帧数 |
| `obs_stack_orders` | 字符串数组 | 每个模型的堆叠顺序，支持 `frame_major` / `obs_major`，长度与模型数相同 |

多模型配置中，上述数组按模型索引对齐。例如 BeyondMimic 的普通行走模型没有动作文件，需要在 `motion_names` 的对应位置保留空字符串。

观测项格式为 `name:size` 或 `name:size@tap|tap`。其中 `size` 是该项一帧的维度，tap `0` 为当前帧，`1` 为上一次推理；未指定 tap 时使用全部历史帧。

| 观测名称 | 维度 | 内容 |
| --- | --- | --- |
| `ang_vel` | 3 | 机身角速度 |
| `gravity_b` | 3 | 投影到机身坐标系的单位重力方向 |
| `cmd_vel` | 3 | 目标前进速度、侧向速度和偏航角速度 |
| `dof_pos` | `joint_num` | 按策略顺序排列的关节角度减去默认角度 |
| `dof_vel` | `joint_num` | 按策略顺序排列的关节速度 |
| `last_action` | `joint_num` | 上一推理步的模型输出，经 `clip_actions` 和 `action_rescale` 处理，按策略关节顺序记录 |
| `motion_command` | `2 × joint_num` | 动作文件中的参考关节位置与速度，需要对应的 `motion_names` |
| `interrupt` | 1 | Interrupt 模式状态，`0` / `1` |
| `perception` | 与发布方一致 | 感知向量，例如 parkour 的 128 维深度编码 |
| `latent` | 与 `z.shape[1]` 一致 | 当前 latent 向量，UFO 为 256 维，需要对应的 `latent_names` |

### 历史观测

tap 须为非负整数且互不重复。任一观测项配置显式 tap 时，策略启用稀疏历史模式。堆叠顺序如下：

- `obs_major`：按观测项分组，组内按 tap 排列；显式 tap 保留书写顺序，未指定 tap 的项按最旧帧到当前帧排列。
- `frame_major`：按最旧帧到当前帧排列，每帧内遵循 `obs_layouts` 的顺序；显式 tap 必须严格降序，例如 `@4|2|0`。

例如 parkour 只使用当前帧的感知观测，其他观测保留 8 帧历史：

```yaml
obs_layouts:
  - "ang_vel:3, gravity_b:3, cmd_vel:3, dof_pos:23, dof_vel:23, last_action:23, perception:128@0"
frame_stacks: [8]
obs_stack_orders: ["obs_major"]
```

输入长度为 `78 × 8 + 128 = 752`。一般计算规则是：未指定 tap 的项贡献 `size × frame_stacks` 个数值，指定 tap 的项贡献 `size × tap 数量` 个数值，最后对所有项求和。程序启动时会检查最终输入长度是否与 ONNX 模型一致。

普通策略首次推理时使用当前观测填满全部历史帧。稀疏历史且带 latent 的策略（当前 UFO）在首次推理时将旧历史帧初始化为零，并在最新帧位置写入当前观测；初始化或重置后采用相同规则。

### 周期、缩放与限制

| 参数 | 类型 / 单位 | 含义与当前默认值 |
| --- | --- | --- |
| `joint_num` | 正整数 | 策略关节数量，应与机器人电机总数、模型输出及关节数组一致；代码默认 `23` |
| `dt` | 正数，s | 电机控制线程的目标周期；代码默认 `0.001`，当前普通策略多为 `0.004`，UFO 为 `0.002` |
| `decimation` | 正整数 | 推理周期相对控制周期的倍数，推理周期为 `dt × decimation`；代码默认 `10` |
| `intra_threads` | 整数 | ONNX Runtime 算子内线程数；正数显式指定，非正数使用 Runtime 默认；代码默认 `-1`，当前 YAML 为 `1` |
| `act_alpha` | 数值 | 每个控制周期的位置目标低通系数，`y = alpha × target + (1-alpha) × y_previous`；通常取 `0 < alpha <= 1`，`1` 不平滑，`0` 保持旧目标；代码默认 `0.9` |
| `obs_scales_lin_vel` | 数值 | `cmd_vel` 中前进、侧向速度的缩放；默认 `1.0` |
| `obs_scales_ang_vel` | 数值 | `ang_vel` 和 `cmd_vel` 偏航角速度的缩放；默认 `1.0` |
| `obs_scales_dof_pos` | 数值 | 关节相对默认角度的观测缩放；默认 `1.0` |
| `obs_scales_dof_vel` | 数值 | 关节速度的观测缩放；默认 `1.0` |
| `obs_scales_gravity_b` | 数值 | 单位重力向量的观测缩放；默认 `1.0` |
| `clip_observations` | 非负数 | 缩放后的单帧观测逐元素限制到 `[-值, 值]`；默认 `100.0` |
| `clip_actions` | 非负数 | 原始模型输出逐元素限制到 `[-值, 值]`，发生在 `action_rescale` 之前；代码默认 `18.0` |
| `action_rescale` | 数值 | 裁剪后模型输出的额外乘数；默认 `1.0`，UFO 为 `8.0`，也会影响 `last_action` 观测 |
| `action_scale` | 数值数组，1 或 `joint_num` 个 | 将动作转换为关节角偏移，按逻辑关节顺序排列；单值广播到全部关节，代码默认 `[0.3]` |
| `usd2urdf` | 整数数组，`joint_num` 个 | 策略索引到逻辑关节索引的映射；`usd2urdf[i]` 是模型第 `i` 项对应的逻辑关节，应为完整的零起始排列 |
| `clip_cmd` | 数值数组，6 个 | `[vx_min, vx_max, vy_min, vy_max, yaw_min, yaw_max]`；线速度为 m/s，偏航为 rad/s，限制手柄及 `cmd_vel` 指令；默认 `[-0.4, 0.6, -0.4, 0.4, -0.8, 0.8]` |
| `joint_default_angle` | 数值数组，`joint_num` 个，rad | 逻辑关节顺序下的默认姿态，同时用于复位、关节位置观测和动作目标偏置 |
| `joint_limits` | 数值数组，`2 × joint_num` 个，rad | `[joint0_min, joint0_max, joint1_min, joint1_max, ...]`，按逻辑关节顺序；`dof_pos` 观测执行关节反馈越限检查，触发时节点报错退出；目标位置限幅需独立实现 |
| `gravity_z_upper` | 数值 | 未缩放的机身重力方向 z 分量上限；`gravity_b` 观测检测到超过上限时退出，默认 `-0.5`；UFO 的配置值 `1.0` 通常使该退出条件不触发，倒地保护需单独验证 |
| `perception_obs_topic` | 字符串 | `Float32MultiArray` 感知输入话题；默认 `elevation_data`，parkour 为 `/depth_obs`，需与发布方一致 |
| `use_depth` | 布尔值 | 默认 `false`；为 `true` 时，开始/重置推理将请求清理深度历史；相机由独立启动流程管理，感知维度由 `obs_layouts` 的 `perception` 项定义 |
| `gamma` | 数值 | latent 前向窗口中第 `i` 帧的权重为 `gamma^i`；默认 `0.8`，通常取 `0 <= gamma <= 1` |
| `window_size` | 正整数 | latent 从当前帧向后融合的帧数；末尾不足时使用剩余帧，默认 `1`，UFO 为 `3`；融合后按首帧 latent 的范数归一化 |

动作转换按以下顺序进行，`i` 为模型输出索引，`j` 为逻辑关节索引：

```text
j = usd2urdf[i]
a[i] = action_rescale * clamp(model_output[i], -clip_actions, clip_actions)
target[j] = joint_default_angle[j] + action_scale[j] * a[i]
filtered_target[j] = act_alpha * target[j] + (1 - act_alpha) * previous_target[j]
```

`action_scale`、`joint_default_angle`、`joint_limits` 使用逻辑关节顺序，`robot.yaml` 的 `kp/kd`、零偏和方向使用电机顺序；二者通过 `urdf2motor` 关联。周期、缩放、观测布局及关节映射均须与训练配置一致。相关参数变更应同步验证模型输入与动作输出。

### launch 自动提供的参数

| 参数 | 标准 launch 提供的值 |
| --- | --- |
| `robot_name` | 所选机器人目录名，如 `rpo`、`rp1_24dof` |
| `policy_name` | 所选策略名，如 `default`、`ufo` |
| `robot_config` | 所选目录中的 `robot.yaml` 路径 |
| `model_dir` | 所选目录中的 `models/` |
| `motion_dir` | 所选目录中的 `motions/` |
| `latent_dir` | 所选目录中的 `latents/` |

标准 [inference.launch.py](../src/inference/launch/inference.launch.py) 在策略 YAML 后提供这些参数，覆盖 YAML 中同名值。通过标准 launch 启动时，由启动文件管理上述参数；独立运行节点时需显式提供对应路径。

## 相机配置

### 深度处理参数

以下参数位于 `src/camera/configs/parkour.yaml` 的 `depth_node.ros__parameters` 下。表中示例值取自当前 parkour 配置，适用范围由相机规格和模型输入约束确定。

| 参数 | 类型 / 示例 | 含义 |
| --- | --- | --- |
| `depth_topic` | 字符串，`/camera/camera/depth/image_rect_raw` | 输入深度图话题，支持 `16UC1` 毫米深度或 `32FC1` 米深度；应与 RealSense 输出一致 |
| `depth_obs_topic` | 字符串，`/depth_obs` | 输出 `Float32MultiArray` 话题，应与推理的 `perception_obs_topic` 一致 |
| `depth_process_hz` | 正数，`50.0` Hz | 深度预处理、历史堆叠与编码的目标频率，与相机采集频率分别配置 |
| `use_depth_encoder` | 布尔值，`true` | 使用 ONNX 编码器；为 `false` 时直接输出归一化后的裁剪深度历史 |
| `depth_encoder_model_name` | 字符串，`encoder.onnx` | 编码器文件名，相对路径基于相机包的 `models/` |
| `depth_encoder_output_dim` | 正整数，`128` | 启用编码器时的输出向量长度，需与模型输出和策略 `perception` 维度一致 |
| `depth_history_taps` | 整数数组，`[35, 30, 25, 20, 15, 10, 5, 0]` | 按深度处理步计的历史偏移，非空、非负、严格降序；与推理 `obs_layouts` 中的 tap 属于两个独立历史缓冲 |
| `intra_threads` | 整数，`1` | 深度编码器的 ONNX Runtime 算子内线程数，正数显式指定 |
| `debug_vis` | 布尔值，`true` | 发布下采样和裁剪的调试深度图 |
| `debug_depth_vis_topic` | 字符串，`/debug_depth_vis` | 调试话题前缀，后缀为 `/downsample`、`/crop` |
| `depth_use_bilinear` | 布尔值，`true` | 缩放时为 `true` 使用双线性插值，为 `false` 使用区域插值 |
| `depth_input_width` | 正整数，`480` 像素 | 预期的输入图像宽度；不匹配时提示警告，实际图像按其源尺寸进行下采样 |
| `depth_input_height` | 正整数，`270` 像素 | 预期的输入图像高度，应与相机深度 profile 一致 |
| `depth_width` | 正整数，`64` 像素 | 裁剪前下采样网格的宽度 |
| `depth_height` | 正整数，`36` 像素 | 裁剪前下采样网格的高度 |
| `depth_crop_up` | 非负整数，`18` 像素 | 从下采样网格顶部裁剪的行数 |
| `depth_crop_down` | 非负整数，`0` 像素 | 从下采样网格底部裁剪的行数 |
| `depth_crop_left` | 非负整数，`16` 像素 | 从下采样网格左侧裁剪的列数 |
| `depth_crop_right` | 非负整数，`16` 像素 | 从下采样网格右侧裁剪的列数 |
| `depth_min_distance` | 数值，`0.0` m | 有效深度裁剪及归一化的下限，无效/非正深度保留为零 |
| `depth_max_distance` | 数值，`2.5` m | 有效深度裁剪及归一化的上限，必须大于下限 |
| `model_dir` | 字符串，launch 自动提供 | 相机编码器目录；标准 launch 使用相机包的 `models/`，覆盖 YAML 中同名值 |

裁剪在下采样网格上执行。当前裁剪后尺寸为 `(64 - 16 - 16) × (36 - 18 - 0) = 32 × 18`，8 个历史 tap 组成 `32 × 18 × 8 = 4608` 个输入值。启用编码器后输出 128 维；关闭编码器则输出 4608 维，策略的 `perception` 维度也需要相应匹配。正常 50 Hz 处理时，tap `35` 约对应 0.7 秒前的处理步。

### RealSense 启动参数

以下参数位于 `realsense_d435i.yaml` 顶层，参数名中的点号按字面保留。

| 参数 | 当前值 | 含义 |
| --- | --- | --- |
| `camera_namespace` | `camera` | ROS 相机命名空间 |
| `camera_name` | `camera` | 相机节点名称；与 namespace 共同决定话题前缀 |
| `enable_depth` | `true` | 启用深度流 |
| `enable_color` | `false` | 启用彩色流 |
| `publish_tf` | `false` | 是否发布相机坐标系 TF |
| `enable_gyro` | `false` | 是否发布相机陀螺仪流；与机器人 HIPNUC/MCT7123 IMU 独立 |
| `enable_accel` | `false` | 是否发布相机加速度计流 |
| `depth_module.depth_profile` | `480x270x60` | 深度宽度 × 高度 × 采集帧率，应由设备支持；相机采集频率为 60 Hz，深度处理频率为 50 Hz |
| `depth_module.depth_format` | `Z16` | 深度采集格式，当前输出用于毫米深度转换 |
| `depth_module.enable_auto_exposure` | `true` | 深度模块自动曝光 |
| `log_level` | `info` | 相机驱动日志等级 |
| `output` | `screen` | 相机启动日志输出位置 |
| `spatial_filter.enable` | `false` | RealSense 空间滤波开关，与项目深度下采样插值参数独立 |

修改 namespace 或 name 时同步修改 `depth_topic`；`start_camera.sh` 的节点/话题检查也使用当前默认名称。相机命名变更需同步更新 YAML 配置与脚本检查项。

## 标零配置

`set_zero_rpo.yaml`、`set_zero_rp1.yaml` 将硬件配置的 `motors` 字段放在顶层，不包含 `imu`、`robot` 或 `ros__parameters`。

| 参数 | 含义与格式 |
| --- | --- |
| `motor_id` | 要按顺序标零的电机 ID 数组，可以配置所需电机子集 |
| `motor_interface_type` | 各总线的 `can` / `canfd` 数组；脚本也接受单个字符串并广播到各总线 |
| `motor_interface` | 总线接口名数组 |
| `motor_num` | 每条总线待标零电机的数量，总和应与 ID 数量一致 |
| `motor_type` | 各总线驱动类型数组；脚本也接受单个字符串并广播 |
| `motor_model` | 每个电机的型号枚举数组，含义同硬件配置 |
| `master_id_offset` | DM 主机反馈 ID 偏移 |
| `motor_zero_offset` | 标零时读取电机位置所用的软件偏移数组，单位 rad；不会作为结果写回 YAML |

标零脚本支持字符串广播；`robot.yaml` 的对应字段采用数组结构，两类配置应按各自格式维护。标零脚本将型号/零偏数组中缺失的电机项赋值为 `0`，配置时应显式提供完整的型号和零偏参数。

省略 `--config` 时默认读取 RPO 配置。24 电机 RP1 指定 `scripts/config/set_zero_rp1_24dof.yaml`，28 电机 RP1 指定 `scripts/config/set_zero_rp1.yaml`。脚本逐项写入电机硬件零点，运行配置中的 `motor_zero_offset`、`motor_sign` 及关节映射保持原值。

RPO 的运行配置与标零配置中的腰部软件偏移目前分别为 `2.093` 和 `0.0`，两项分别用于运行坐标转换和标零过程，应依据对应物理基准分别确定。腰部标零方法及偏移选择见 [RPO 启动说明](rpo_deploy_CN.md#启动软件)。

## 修改前核对

- 硬件参数的数组长度、总线分组和关节映射完整一致；`urdf2motor`、`usd2urdf` 按零起始数组索引定义映射。
- `obs_layouts` 的来源、维度、缩放、历史顺序和输入总长度与训练及 ONNX 模型一致。
- 模型文件、外部权重、动作及 latent 数据须与所选机器人和策略配置匹配。
- `dt × decimation` 与训练控制频率一致；UFO 为 `0.002 × 10 = 0.020` 秒，即 50 Hz。
- 深度图话题、感知话题、输入尺寸、裁剪尺寸、历史 tap 和编码器输入/输出相互匹配。
- 硬件零点与软件偏移分开处理；机械限位与倒地保护需结合实际机构和运行条件验证。
