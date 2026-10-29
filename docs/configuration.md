# YAML Configuration Reference

[Project Home](../README.md) | [中文](configuration_CN.md)

This reference explains deployment parameters, units, array ordering, and related constraints. See [RPO Deployment](rpo_deploy.md) for controller connections, environment setup, and deployment procedures.

## Files and Loading

| File | Reader | Purpose and format |
| --- | --- | --- |
| `src/inference/robots/<robot>/robot.yaml` | `RobotInterface` | Hardware configuration read by the project's YAML parser, with top-level `imu`, `motors`, and `robot` sections |
| `src/inference/robots/<robot>/configs/<policy>.yaml` | `inference_node` | Policy parameters under `inference_node.ros__parameters` |
| [Camera parkour.yaml](../src/camera/configs/parkour.yaml) | `depth_node` | Depth processing parameters under `depth_node.ros__parameters` |
| [realsense_d435i.yaml](../src/camera/configs/realsense_d435i.yaml) | RealSense `rs_launch.py` | Camera launch settings at the top level |
| [set_zero_rpo.yaml](../scripts/config/set_zero_rpo.yaml), [set_zero_rp1.yaml](../scripts/config/set_zero_rp1.yaml) | `scripts/set_zero.py` | Motor creation for zeroing, with parameters at the top level |

Robot startup selects a robot directory with `--robot` and a policy in that directory with `--policy`. Defaults are `rpo` / `default`. Camera startup's `--policy` selects a file in `src/camera/configs/`; it is a separate file from the robot policy configuration.

| Robot directory | Motor count | Default hardware | Current policy configurations |
| --- | --- | --- | --- |
| `rpo` | 23 | DM / CAN, HIPNUC serial | `default`, `amp`, `beyondmimic`, `getup`, `interrupt`, `parkour` |
| `rp1_24dof` | 24 | LRO / CAN FD, HIPNUC CAN | `default`, `beyondmimic`, `ufo` |

UFO uses the 24-motor `rp1_24dof` configuration. The 28-motor `rp1` uses separate hardware and policy configurations. Models, observations, joint mappings, and zero references must match the selected robot and training configuration.

The following example illustrates the ROS parameter hierarchy and selected fields. A complete policy additionally requires models, observation layouts, and joint parameters:

```yaml
inference_node:
  ros__parameters:
    joint_num: 24
    dt: 0.002
    decimation: 10
```

Standard launch files load configurations from the built package directories. With `--symlink-install`, verify the links between installed configurations and source files. Rebuild after adding configuration files. Parameters are loaded at node startup; YAML changes take effect after restarting the corresponding node.

## Robot Hardware Configuration

Refer to [RPO robot.yaml](../src/inference/robots/rpo/robot.yaml) and [24-motor RP1 robot.yaml](../src/inference/robots/rp1_24dof/robot.yaml). Let `N` be the total motor count and `B` the number of bus groups.

### IMU

| Parameter | Type / unit | Meaning |
| --- | --- | --- |
| `imu.imu_id` | Integer | IMU device ID; used to match CAN frames and retained as a configuration ID in serial mode |
| `imu.imu_interface_type` | String | Interface type: HIPNUC supports `serial` / `can`; MCT7123 supports `serial` / `canfd` |
| `imu.imu_interface` | String | Serial device node or SocketCAN interface, such as `/dev/ttyUSB0` or `can_hipnuc` |
| `imu.imu_type` | String | Driver type; currently `HIPNUC` or `MCT7123` |
| `imu.baudrate` | Integer | Serial communication rate or configured CAN rate; RPO uses `921600`, RP1 uses `1000000`. The system CAN interface must be configured at the corresponding rate |

### Motors and Buses

| Parameter | Type / length | Meaning |
| --- | --- | --- |
| `motors.motor_id` | Integer array, `N` | Motor IDs concatenated by bus group; IDs may repeat across buses but should be unique within one bus |
| `motors.motor_interface_type` | String array, `B` | Protocol for each bus, such as `can` or `canfd`; `robot.yaml` requires an array |
| `motors.motor_interface` | String array, `B` | Interface name for each bus; this order defines motor grouping |
| `motors.motor_num` | Integer array, `B` | Motor count on each bus; the sum must equal `N` |
| `motors.motor_type` | String array, `B` | Driver type per bus, such as `DM` or `LRO`; `EVO`, `RP`, and `XYN` are also supported |
| `motors.motor_model` | Integer array, `N` | Motor model enum selecting the driver's protocol ranges and related settings |
| `motors.master_id_offset` | Integer | DM host feedback ID offset; current configurations use `16`. Other drivers follow their own implementations |
| `motors.motor_zero_offset` | Number array, `N`, rad | Software position offset per motor. Current DM/LRO drivers add it to feedback and subtract it from position commands; hardware zeros are set through calibration |

For example, RPO `motor_num: [6, 7, 5, 5]` assigns the first six motors to the first bus, the next seven to the second, followed by two groups of five. `motor_id`, `motor_model`, and `motor_zero_offset` must describe the same motors in the same order.

Model enums used by the current configurations:

| Driver | `motor_model` values |
| --- | --- |
| DM | `0=DM4340P_48V`, `1=DM10010L_48V` |
| LRO | `0=LRO_5550`, `1=LRO_6562`, `2=LRO_8462`, `3=LRO_10062` |

See the [DM driver](../src/motors/src/drivers/dm/dm_motor_driver.hpp) and [LRO driver](../src/motors/src/drivers/lro/lro_motor_driver.hpp) for enum definitions. Model enum values are defined by the selected driver.

### Robot Mapping and Control

| Parameter | Type / length | Meaning |
| --- | --- | --- |
| `robot.type` | String | Closed-chain mechanism type: `rpo` or `rp1`. `rp1_24dof` uses `rp1`; the robot directory is selected by the `--robot` startup argument |
| `robot.kp` | Number array, `N` | Default MIT stiffness gains in motor order |
| `robot.kd` | Number array, `N` | Default MIT damping gains in motor order |
| `robot.motor_sign` | Integer array, `N` | Motor directions, normally `1` / `-1`, in motor order; applied to position, velocity, and effort conversions |
| `robot.close_chain_motor_idx` | Integer array, currently 4 entries | Zero-based positions in the `motor_id` array for closed-chain motors, ordered as the left pair followed by the right pair |
| `robot.urdf2motor` | Integer array, `N` | `urdf2motor[j]` is the motor-array index for logical joint `j`; use a complete permutation of `0..N-1` |
| `robot.extrinsic_R` | Number array, 9 entries | IMU mounting rotation matrix flattened by rows. The implementation uses `omega_body = R * omega_imu` and `q_body = q_imu * inverse(q_R)` |

The default `kp/kd` in `robot.yaml` define runtime MIT control gains and are shared by policies in that robot directory. Changing `rp1_24dof` gains affects default, BeyondMimic, and UFO. Gains also enter the joint-to-motor conversion for closed-chain control and must match the mechanism. That conversion divides by closed-chain motor `kp`, so those gains must be positive. `extrinsic_R` must be a valid rotation matrix matching the IMU mounting.

## Inference Policy Configuration

These parameters belong under `inference_node.ros__parameters`. Optional fields omitted from YAML use code defaults; each policy can explicitly configure the corresponding values.

### Models, Motion, and Observation Layout

| Parameter | Type | Meaning and constraints |
| --- | --- | --- |
| `model_names` | String array | Non-empty ONNX model list. Relative paths resolve under the robot's `models/`; absolute paths are also accepted |
| `motion_names` | String array | Motion NPZ list, relative to `motions/`. May be omitted or empty; otherwise its length must match the model list. Use `""` for models without motion data |
| `latent_names` | String array | Latent NPZ list, relative to `latents/`, with the same length rules as `motion_names`. UFO reads a two-dimensional float32 array named `z` |
| `obs_layouts` | String array | Observation ordering, per-source dimensions, and optional history taps for each model; length must match the model list and contents must match training |
| `frame_stacks` | Positive integer array | Inference history capacity for each model; length matches the model list. Every tap must be smaller than its capacity |
| `obs_stack_orders` | String array | History order per model: `frame_major` or `obs_major`; length matches the model list |

All these lists share model indices. For example, a BeyondMimic walking model without reference motion needs an empty string at its index in `motion_names`.

Observation entries use `name:size` or `name:size@tap|tap`. `size` is the single-frame dimension for that source; tap `0` is current, `1` is the previous inference step. Omitting taps uses all history frames.

| Observation source | Dimension | Contents |
| --- | --- | --- |
| `ang_vel` | 3 | Body angular velocity |
| `gravity_b` | 3 | Unit gravity direction projected into the body frame |
| `cmd_vel` | 3 | Target forward velocity, lateral velocity, and yaw rate |
| `dof_pos` | `joint_num` | Joint positions minus default angles, in policy order |
| `dof_vel` | `joint_num` | Joint velocities in policy order |
| `last_action` | `joint_num` | Model output from the preceding inference step, processed by `clip_actions` and `action_rescale` and stored in policy joint order |
| `motion_command` | `2 × joint_num` | Reference joint positions and velocities from motion data; requires the corresponding `motion_names` entry |
| `interrupt` | 1 | Interrupt mode state, `0` / `1` |
| `perception` | Matches publisher | Perception vector, such as parkour's 128-dimensional depth encoding |
| `latent` | Matches `z.shape[1]` | Current latent vector; UFO uses 256 dimensions and requires a corresponding `latent_names` entry |

### Observation History

Taps must be non-negative and unique. Explicit taps on any source enable sparse history mode. History ordering:

- `obs_major`: source first, then tap. Explicit taps retain their written order; sources without taps use oldest-to-current ordering.
- `frame_major`: oldest-to-current frames, with sources in `obs_layouts` order within each frame. Explicit taps must be strictly descending, for example `@4|2|0`.

For example, parkour uses current perception and eight history frames for the other observations:

```yaml
obs_layouts:
  - "ang_vel:3, gravity_b:3, cmd_vel:3, dof_pos:23, dof_vel:23, last_action:23, perception:128@0"
frame_stacks: [8]
obs_stack_orders: ["obs_major"]
```

The input length is `78 × 8 + 128 = 752`. In general, each source without explicit taps contributes `size × frame_stacks` values, while a source with taps contributes `size × number_of_taps`; sum them over all entries. Startup checks the resulting input length against the ONNX model.

Ordinary policies fill every history frame with current observations on the first inference step. Sparse policies with latent data, currently UFO, initialize older history to zero and write current observations into the newest slot. The same rule applies after initialization or reset.

### Timing, Scaling, and Limits

| Parameter | Type / unit | Meaning and code default |
| --- | --- | --- |
| `joint_num` | Positive integer | Policy joint count; must match motor count, model output, and joint arrays. Default `23` |
| `dt` | Positive number, s | Target motor-control thread period. Default `0.001`; most current policies use `0.004`, UFO uses `0.002` |
| `decimation` | Positive integer | Inference-to-control period ratio; inference period is `dt × decimation`. Default `10` |
| `intra_threads` | Integer | ONNX Runtime intra-op thread count; positive values set it explicitly, non-positive values leave Runtime defaults. Code default `-1`, current YAML uses `1` |
| `act_alpha` | Number | Position-target filter coefficient per control step: `y = alpha × target + (1-alpha) × y_previous`. Normally `0 < alpha <= 1`; `1` disables smoothing, `0` retains the previous target. Default `0.9` |
| `obs_scales_lin_vel` | Number | Scale for forward and lateral `cmd_vel` components. Default `1.0` |
| `obs_scales_ang_vel` | Number | Scale for `ang_vel` and commanded yaw rate. Default `1.0` |
| `obs_scales_dof_pos` | Number | Scale for joint position observations relative to default angles. Default `1.0` |
| `obs_scales_dof_vel` | Number | Joint velocity observation scale. Default `1.0` |
| `obs_scales_gravity_b` | Number | Unit gravity observation scale. Default `1.0` |
| `clip_observations` | Non-negative number | Clamp scaled single-frame observations to `[-value, value]`. Default `100.0` |
| `clip_actions` | Non-negative number | Clamp raw model output to `[-value, value]` before `action_rescale`. Code default `18.0` |
| `action_rescale` | Number | Extra multiplier after action clipping. Default `1.0`; UFO uses `8.0`. Also affects `last_action` observations |
| `action_scale` | Number array, 1 or `joint_num` entries | Converts actions to joint-angle offsets, in logical joint order. A single value broadcasts to every joint. Default `[0.3]` |
| `usd2urdf` | Integer array, `joint_num` entries | Mapping from policy output index to logical joint index. `usd2urdf[i]` is the joint for model entry `i`; use a complete zero-based permutation |
| `clip_cmd` | Number array, 6 entries | `[vx_min, vx_max, vy_min, vy_max, yaw_min, yaw_max]`; linear velocity in m/s, yaw in rad/s. Limits gamepad and `cmd_vel` commands. Default `[-0.4, 0.6, -0.4, 0.4, -0.8, 0.8]` |
| `joint_default_angle` | Number array, `joint_num` entries, rad | Default pose in logical joint order, used for reset, relative position observations, and action-target offsets |
| `joint_limits` | Number array, `2 × joint_num` entries, rad | `[joint0_min, joint0_max, joint1_min, joint1_max, ...]` in logical joint order. `dof_pos` checks joint feedback and terminates the node on limit violations; target-position clamping requires separate handling |
| `gravity_z_upper` | Number | Upper bound on unscaled body gravity z. The `gravity_b` source exits if this is exceeded. Default `-0.5`; UFO's value of `1.0` normally leaves this termination condition inactive; fall protection requires separate validation |
| `perception_obs_topic` | String | Input `Float32MultiArray` perception topic. Default `elevation_data`; parkour uses `/depth_obs`. Must match the publisher |
| `use_depth` | Boolean | Default `false`. When true, starting/resetting inference requests a depth-history reset. Camera startup is managed separately; perception dimensions are defined by `obs_layouts` |
| `gamma` | Number | Latent look-ahead window weight for frame `i` is `gamma^i`. Default `0.8`; normally use `0 <= gamma <= 1` |
| `window_size` | Positive integer | Number of forward latent frames to blend, using remaining frames near the end. Default `1`, UFO uses `3`. The blend is normalized to the first latent frame's norm |

Action conversion uses the following order, where `i` is a model output index and `j` is a logical joint index:

```text
j = usd2urdf[i]
a[i] = action_rescale * clamp(model_output[i], -clip_actions, clip_actions)
target[j] = joint_default_angle[j] + action_scale[j] * a[i]
filtered_target[j] = act_alpha * target[j] + (1 - act_alpha) * previous_target[j]
```

`action_scale`, `joint_default_angle`, and `joint_limits` use logical joint order. Hardware gains, offsets, and directions use motor order, linked through `urdf2motor`. Timing, scales, observation layouts, and joint mappings must match training. Parameter changes require corresponding validation of model inputs and action outputs.

### Parameters Supplied by Launch

| Parameter | Standard launch value |
| --- | --- |
| `robot_name` | Selected robot directory, such as `rpo` or `rp1_24dof` |
| `policy_name` | Selected policy, such as `default` or `ufo` |
| `robot_config` | Path to that robot's `robot.yaml` |
| `model_dir` | That robot's `models/` directory |
| `motion_dir` | That robot's `motions/` directory |
| `latent_dir` | That robot's `latents/` directory |

Standard [inference.launch.py](../src/inference/launch/inference.launch.py) supplies these after the policy YAML, overriding fields of the same name. Standard launch manages these parameters. Independent node execution requires explicit matching paths.

## Camera Configuration

### Depth Processing Parameters

These parameters belong under `depth_node.ros__parameters` in `src/camera/configs/parkour.yaml`. Example values are taken from the current parkour configuration; applicability is determined by camera specifications and model input constraints.

| Parameter | Type / example | Meaning |
| --- | --- | --- |
| `depth_topic` | String, `/camera/camera/depth/image_rect_raw` | Input depth image topic; supports `16UC1` millimeters or `32FC1` meters. Must match RealSense output |
| `depth_obs_topic` | String, `/depth_obs` | Output `Float32MultiArray` topic; must match inference `perception_obs_topic` |
| `depth_process_hz` | Positive number, `50.0` Hz | Target preprocessing/history/encoding frequency, separate from camera capture frequency |
| `use_depth_encoder` | Boolean, `true` | Use the ONNX encoder; false returns normalized cropped depth history directly |
| `depth_encoder_model_name` | String, `encoder.onnx` | Encoder filename, relative to the camera package's `models/` |
| `depth_encoder_output_dim` | Positive integer, `128` | Encoded vector length, matching model output and the policy's `perception` dimension |
| `depth_history_taps` | Integer array, `[35, 30, 25, 20, 15, 10, 5, 0]` | History offsets in depth processing steps; non-empty, non-negative, strictly descending. This history is separate from inference `obs_layouts` taps |
| `intra_threads` | Integer, `1` | Depth encoder ONNX Runtime intra-op thread count; positive values set it explicitly |
| `debug_vis` | Boolean, `true` | Publish downsampled and cropped debug depth images |
| `debug_depth_vis_topic` | String, `/debug_depth_vis` | Debug topic prefix, with `/downsample` and `/crop` suffixes |
| `depth_use_bilinear` | Boolean, `true` | True uses bilinear resize; false uses area interpolation |
| `depth_input_width` | Positive integer, `480` pixels | Expected source width. Mismatches generate warnings; actual images are resized using their source dimensions |
| `depth_input_height` | Positive integer, `270` pixels | Expected source height, matching the camera depth profile |
| `depth_width` | Positive integer, `64` pixels | Downsample grid width before cropping |
| `depth_height` | Positive integer, `36` pixels | Downsample grid height before cropping |
| `depth_crop_up` | Non-negative integer, `18` pixels | Rows removed from the top of the downsample grid |
| `depth_crop_down` | Non-negative integer, `0` pixels | Rows removed from the bottom of the downsample grid |
| `depth_crop_left` | Non-negative integer, `16` pixels | Columns removed from the left of the downsample grid |
| `depth_crop_right` | Non-negative integer, `16` pixels | Columns removed from the right of the downsample grid |
| `depth_min_distance` | Number, `0.0` m | Lower valid-depth clipping and normalization bound; invalid/non-positive depth remains zero |
| `depth_max_distance` | Number, `2.5` m | Upper valid-depth clipping and normalization bound, greater than the lower bound |
| `model_dir` | String, supplied by launch | Encoder directory. Standard launch uses the camera package's `models/` and overrides the same YAML field |

Cropping operates on the downsample grid. Current cropped dimensions are `(64 - 16 - 16) × (36 - 18 - 0) = 32 × 18`. Eight taps provide `32 × 18 × 8 = 4608` encoder input values. Encoding produces 128 values; disabling the encoder produces 4608, so the policy's perception dimension must match. At a normal 50 Hz processing rate, tap `35` is approximately 0.7 seconds back in processing steps.

### RealSense Launch Parameters

These fields appear at the top level of `realsense_d435i.yaml`. Dots are part of the complete parameter names.

| Parameter | Current value | Meaning |
| --- | --- | --- |
| `camera_namespace` | `camera` | ROS camera namespace |
| `camera_name` | `camera` | Camera node name; together with the namespace, determines topic prefixes |
| `enable_depth` | `true` | Enable depth streaming |
| `enable_color` | `false` | Enable color streaming |
| `publish_tf` | `false` | Publish camera coordinate-frame TF |
| `enable_gyro` | `false` | Publish the camera gyroscope stream, separate from the robot HIPNUC/MCT7123 IMU |
| `enable_accel` | `false` | Publish the camera accelerometer stream |
| `depth_module.depth_profile` | `480x270x60` | Depth width × height × capture rate, supported by the device. Capture is 60 Hz, separate from 50 Hz depth processing |
| `depth_module.depth_format` | `Z16` | Depth capture format used for millimeter depth conversion |
| `depth_module.enable_auto_exposure` | `true` | Enable depth-module auto exposure |
| `log_level` | `info` | Camera driver log level |
| `output` | `screen` | Camera launch log destination |
| `spatial_filter.enable` | `false` | RealSense spatial filter toggle, separate from the project's depth resize interpolation |

Update `depth_topic` when changing the namespace or camera name. `start_camera.sh` also checks the current default node/topic names; camera naming changes require updates to both YAML configuration and script checks.

## Zeroing Configuration

`set_zero_rpo.yaml` and `set_zero_rp1.yaml` place hardware `motors` fields at the top level, without `imu`, `robot`, or `ros__parameters` sections.

| Parameter | Meaning and format |
| --- | --- |
| `motor_id` | IDs to zero in order; a selected motor subset is allowed |
| `motor_interface_type` | Array of `can` / `canfd` per bus; the script also broadcasts a single string to every bus |
| `motor_interface` | Bus interface name array |
| `motor_num` | Motors to zero per bus; sum must match the ID count |
| `motor_type` | Driver types per bus; the script also accepts and broadcasts a single string |
| `motor_model` | Per-motor model enums, with the same meanings as hardware configuration |
| `master_id_offset` | DM host feedback ID offset |
| `motor_zero_offset` | Software position offsets used while zeroing, in radians; results are not written back to YAML |

The zeroing script supports string broadcasting; the corresponding `robot.yaml` fields use arrays. Each configuration must follow its own format. The script assigns `0` to motor entries missing from model/offset arrays; configurations should explicitly provide complete model and offset values.

Without `--config`, the script uses RPO configuration. For RP1, select `scripts/config/set_zero_rp1_24dof.yaml` for 24 motors or `scripts/config/set_zero_rp1.yaml` for 28 motors. The script writes individual motor hardware zeros. Runtime `motor_zero_offset`, `motor_sign`, and joint mappings remain configured in their respective YAML files.

The RPO runtime and zeroing configurations currently use waist software offsets of `2.093` and `0.0`, respectively. These values serve runtime coordinate conversion and the calibration process, respectively, and must be determined according to their physical reference poses. See [RPO Software Startup](rpo_deploy.md#start-software) for the waist calibration method and offset choice.

## Checks Before Editing

- Keep hardware array lengths, bus groups, and joint mappings consistent. `urdf2motor` and `usd2urdf` define mappings using zero-based array indices.
- Match observation sources, dimensions, scales, history ordering, and total input length to training and the ONNX model.
- Match model files, external weights, motion data, and latent data to the selected robot and policy configuration.
- Match `dt × decimation` to the training control rate. UFO uses `0.002 × 10 = 0.020` seconds, or 50 Hz.
- Match depth and perception topics, image dimensions, crops, history taps, and encoder input/output.
- Handle hardware zeros and software offsets separately. Validate mechanical limits and fall protection against the actual mechanism and operating conditions.
