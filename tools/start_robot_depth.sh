#!/bin/bash

# 颜色定义，用于美化输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

# 函数：打印成功消息
print_success() {
    echo -e "${GREEN}$1${NC}"
}

# 函数：打印提示消息
print_info() {
    echo -e "${YELLOW}$1${NC}"
}

# 函数：打印错误消息
print_error() {
    echo -e "${RED}$1${NC}"
}

show_usage() {
    echo "用法: $0 [--robot ROBOT] [--policy POLICY]"
    echo "      $0 [ROBOT] [POLICY]"
    echo
    echo "用于深度相机策略（use_depth: true）。"
    echo "depth.launch.py 会先启动 RealSense，再启动 depth_node（encoder.onnx）；"
    echo "无需开始 policy 推理即可查看 crop / downsample debug 图像（debug_vis: true）。"
    echo "非深度策略请使用: ./tools/start_robot.sh"
    echo
    echo "默认: robot=rpo, policy=parkour"
    echo "示例: $0"
    echo "示例: $0 --robot rpo --policy parkour"
}

validate_name() {
    local label=$1
    local value=$2

    if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        print_error "$label 必须以字母或数字开头，且只能包含字母、数字、下划线、短横线和点: $value"
        exit 1
    fi
}

read_yaml_value() {
    local file=$1
    local key=$2
    sed -nE "s/^[[:space:]]*${key}:[[:space:]]*\"?([^\"#[:space:]]+)\"?.*$/\1/p" "$file" | head -n 1
}

wait_for_node() {
    local node_pattern=$1
    local timeout_seconds=$2
    local attempts=$((timeout_seconds * 2))
    local i

    for ((i = 0; i < attempts; ++i)); do
        if ros2 node list 2>/dev/null | grep -qE "$node_pattern"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

wait_for_topic() {
    local topic=$1
    local timeout_seconds=$2
    local attempts=$((timeout_seconds * 2))
    local i

    for ((i = 0; i < attempts; ++i)); do
        if ros2 topic list 2>/dev/null | grep -Fxq "$topic"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

wait_for_service() {
    local service=$1
    local timeout_seconds=$2
    local attempts=$((timeout_seconds * 2))
    local i

    for ((i = 0; i < attempts; ++i)); do
        if ros2 service list 2>/dev/null | grep -Fxq "$service"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# 函数：启动组件并检查
start_component() {
    local session_name=$1
    local launch_cmd=$2
    local node_name=$3
    local startup_timeout=$4

    print_info "启动 $session_name ..."
    screen -dmS $session_name bash -c "source install/setup.bash; export RMW_IMPLEMENTATION='$RMW_IMPLEMENTATION'; export RMW_FASTRTPS_USE_QOS_FROM_XML='$RMW_FASTRTPS_USE_QOS_FROM_XML'; export FASTRTPS_DEFAULT_PROFILES_FILE='$FASTRTPS_DEFAULT_PROFILES_FILE'; $launch_cmd; exec bash"

    if ! wait_for_node "$node_name" "$startup_timeout"; then
        print_error "$session_name 启动失败！未检测到 $node_name 节点。"
        cleanup_sessions
        exit 1
    fi
}

verify_realsense_startup() {
    local depth_topic=$1
    local hz_line

    print_info "验证 RealSense 相机是否启动成功..."

    if ! wait_for_node "camera/camera|realsense" 10; then
        print_error "RealSense 启动失败！未检测到相机节点。"
        print_info "请检查: 1) D435i 是否插入 USB3.0  2) lsusb | grep 8086  3) screen -r depth_session"
        return 1
    fi
    print_success "RealSense 节点已上线"

    if ! wait_for_topic "$depth_topic" 10; then
        print_error "RealSense 启动失败！未找到深度话题: $depth_topic"
        return 1
    fi
    print_success "深度话题已发布: $depth_topic"

    print_info "检测深度图帧率..."
    # --window 5：更快出 average rate；超时+重试：给相机初始化留时间
    local attempt
    for ((attempt = 1; attempt <= 3; ++attempt)); do
        hz_line=$(timeout 3 ros2 topic hz "$depth_topic" --window 5 2>&1 | grep "average rate" | tail -1)
        if [ -n "$hz_line" ]; then
            print_success "深度图发布正常 ($hz_line)"
            return 0
        fi
        if [ "$attempt" -lt 3 ]; then
            print_info "帧率检测未完成，重试 ($attempt/3)..."
        fi
    done

    print_error "深度图帧率检测失败！话题已存在但未收到稳定数据流"
    print_info "请检查: 1) D435i USB3.0  2) screen -r depth_session  3) ros2 topic hz $depth_topic"
    return 1
}

verify_depth_startup() {
    local depth_obs_topic=$1
    local debug_vis_topic=$2
    local debug_vis=$3

    print_info "等待 depth_node（encoder.onnx）..."
    if ! wait_for_node "^/depth_node$" 10; then
        print_error "未检测到 depth_node"
        print_info "可执行 screen -r depth_session 查看日志"
        return 1
    fi
    print_success "depth_node 已上线，开始预处理 / 编码"

    print_info "等待深度观测话题: $depth_obs_topic"
    if ! wait_for_topic "$depth_obs_topic" 10; then
        print_error "未检测到深度观测话题: $depth_obs_topic"
        return 1
    fi
    print_success "深度观测话题已发布: $depth_obs_topic"

    if [ "$debug_vis" = "true" ] || [ "$debug_vis" = "1" ]; then
        local downsample_topic="${debug_vis_topic%/}/downsample"
        local crop_topic="${debug_vis_topic%/}/crop"
        print_info "等待 debug 图像话题..."
        if ! wait_for_topic "$downsample_topic" 10; then
            print_error "未检测到 downsample 话题: $downsample_topic"
            return 1
        fi
        if ! wait_for_topic "$crop_topic" 10; then
            print_error "未检测到 crop 话题: $crop_topic"
            return 1
        fi
        print_success "debug 图像话题已发布:"
        print_success "  $downsample_topic"
        print_success "  $crop_topic"
    fi
    return 0
}

verify_inference_startup() {
    # Node 基类一构造就会进 node list；/action 在其它接口创建之后才出现
    print_info "等待 inference_node 就绪..."
    if ! wait_for_topic "/action" 10; then
        print_error "未检测到 /action，inference_node 可能未完成启动"
        print_info "可执行 screen -r inference_session 查看日志"
        return 1
    fi
    print_success "inference_node 已就绪 (/action)"

    print_info "等待 start_inference 服务..."
    if ! wait_for_service "/start_inference" 5; then
        print_error "未检测到 /start_inference 服务"
        return 1
    fi
    print_success "start_inference 服务已就绪"
    return 0
}

# 函数：清理所有 screen 会话
cleanup_sessions() {
    local id
    for id in $(screen -ls 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+\.[^[:space:]]+).*/\1/p'); do
        screen -S "$id" -X quit 2>/dev/null
    done
}

# 函数：详细验证 DDS 配置是否生效
verify_dds_effectiveness() {
    print_info "详细验证 DDS 配置是否生效..."
    sleep 2

    # 1. 检查环境变量
    print_info "检查环境变量..."
    echo "RMW_IMPLEMENTATION: $RMW_IMPLEMENTATION"
    echo "FASTRTPS_DEFAULT_PROFILES_FILE: $FASTRTPS_DEFAULT_PROFILES_FILE"

    # 2. 验证配置文件是否被读取
    print_info "验证配置文件读取..."
    if [ -f "$FASTRTPS_DEFAULT_PROFILES_FILE" ]; then
        print_success "配置文件存在"

        # 检查XML语法
        if command -v xmllint &> /dev/null; then
            if xmllint --noout "$FASTRTPS_DEFAULT_PROFILES_FILE" 2>/dev/null; then
                print_success "XML 格式正确"
            else
                print_error "XML 格式错误"
                xmllint "$FASTRTPS_DEFAULT_PROFILES_FILE"
                return 1
            fi
        fi
    else
        print_error "配置文件不存在: $FASTRTPS_DEFAULT_PROFILES_FILE"
        return 1
    fi

    # 3. 检查进程是否使用了 Fast DDS
    print_info "检查进程 DDS 实现..."
    for node in "inference_node" "depth_node" "joy_node"; do
        local pid=$(pgrep -x "$node" 2>/dev/null)
        if [ -n "$pid" ]; then
            # 检查进程环境变量
            local env_file="/proc/$pid/environ"
            if [ -f "$env_file" ]; then
                if grep -z "FASTRTPS_DEFAULT_PROFILES_FILE" "$env_file" >/dev/null 2>&1; then
                    print_success "$node 环境变量设置正确"
                else
                    print_error "$node 缺少 FASTRTPS_DEFAULT_PROFILES_FILE 环境变量"
                fi

                if grep -z "RMW_IMPLEMENTATION=rmw_fastrtps_cpp" "$env_file" >/dev/null 2>&1; then
                    print_success "$node RMW 实现正确"
                else
                    print_error "$node RMW 实现不正确"
                fi
            fi
        fi
    done

    # 4. 检查共享内存传输
    print_info "检查共享内存传输..."
    local shm_files=$(ls /dev/shm/ 2>/dev/null | grep -E "(fastrtps|fast_dds|rmw)" | wc -l)
    if [ "$shm_files" -gt 0 ]; then
        print_success "共享内存传输活跃 ($shm_files 个文件)"
    else
        print_error "共享内存传输未检测到"
    fi

    # 5. 测试 DDS 发现性能
    print_info "测试 DDS 发现性能..."
    local start_time=$(date +%s%3N)
    ros2 node list >/dev/null 2>&1
    local end_time=$(date +%s%3N)
    local discovery_time=$((end_time - start_time))

    if [ "$discovery_time" -lt 500 ]; then
        print_success "DDS 发现延迟: ${discovery_time}ms (优秀)"
    elif [ "$discovery_time" -lt 1000 ]; then
        print_info "DDS 发现延迟: ${discovery_time}ms (良好)"
    else
        print_error "DDS 发现延迟: ${discovery_time}ms (较慢)"
    fi
}

ROBOT="rpo"
POLICY="parkour"
ROBOT_SET=0
POLICY_SET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --robot|-r)
            if [ $# -lt 2 ]; then
                print_error "缺少 --robot 参数值"
                show_usage
                exit 1
            fi
            ROBOT="$2"
            ROBOT_SET=1
            shift 2
            ;;
        --policy|-p)
            if [ $# -lt 2 ]; then
                print_error "缺少 --policy 参数值"
                show_usage
                exit 1
            fi
            POLICY="$2"
            POLICY_SET=1
            shift 2
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            if [ "$ROBOT_SET" -eq 0 ]; then
                ROBOT="$1"
                ROBOT_SET=1
            elif [ "$POLICY_SET" -eq 0 ]; then
                POLICY="$1"
                POLICY_SET=1
            else
                print_error "未知参数: $1"
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

validate_name "robot" "$ROBOT"
validate_name "policy" "$POLICY"

# 切换到脚本目录
cd "$(dirname "$0")"
cd ..

POLICY_FILE="$POLICY"
if [[ "$POLICY_FILE" != *.yaml ]]; then
    POLICY_FILE="${POLICY_FILE}.yaml"
fi

ROBOT_DIR="src/inference/robots/$ROBOT"
CAMERA_DIR="src/camera"
POLICY_CONFIG="$ROBOT_DIR/configs/$POLICY_FILE"
DEPTH_CONFIG="$CAMERA_DIR/configs/$POLICY_FILE"
REALSENSE_CONFIG="$CAMERA_DIR/configs/realsense_d435i.yaml"

if [ ! -f "$ROBOT_DIR/robot.yaml" ]; then
    print_error "机器人配置不存在: $ROBOT_DIR/robot.yaml"
    exit 1
fi
if [ ! -f "$POLICY_CONFIG" ]; then
    print_error "推理配置不存在: $POLICY_CONFIG"
    exit 1
fi

USE_DEPTH="$(read_yaml_value "$POLICY_CONFIG" "use_depth")"
USE_DEPTH="${USE_DEPTH:-false}"
DEPTH_OBS_TOPIC="$(read_yaml_value "$POLICY_CONFIG" "depth_obs_topic")"
DEPTH_OBS_TOPIC="${DEPTH_OBS_TOPIC:-/depth_obs}"

DEPTH_TOPIC="/camera/camera/depth/image_rect_raw"
USE_DEPTH_ENCODER="false"
DEPTH_ENCODER_MODEL="encoder.onnx"
DEBUG_VIS="false"
DEBUG_DEPTH_VIS_TOPIC="/debug_depth_vis"
if [ -f "$DEPTH_CONFIG" ]; then
    DEPTH_TOPIC="$(read_yaml_value "$DEPTH_CONFIG" "depth_topic")"
    DEPTH_TOPIC="${DEPTH_TOPIC:-/camera/camera/depth/image_rect_raw}"
    DEPTH_OBS_FROM_CAMERA="$(read_yaml_value "$DEPTH_CONFIG" "depth_obs_topic")"
    if [ -n "$DEPTH_OBS_FROM_CAMERA" ]; then
        DEPTH_OBS_TOPIC="$DEPTH_OBS_FROM_CAMERA"
    fi
    USE_DEPTH_ENCODER="$(read_yaml_value "$DEPTH_CONFIG" "use_depth_encoder")"
    USE_DEPTH_ENCODER="${USE_DEPTH_ENCODER:-false}"
    DEPTH_ENCODER_MODEL="$(read_yaml_value "$DEPTH_CONFIG" "depth_encoder_model_name")"
    DEPTH_ENCODER_MODEL="${DEPTH_ENCODER_MODEL:-encoder.onnx}"
    DEBUG_VIS="$(read_yaml_value "$DEPTH_CONFIG" "debug_vis")"
    DEBUG_VIS="${DEBUG_VIS:-false}"
    DEBUG_DEPTH_VIS_TOPIC="$(read_yaml_value "$DEPTH_CONFIG" "debug_depth_vis_topic")"
    DEBUG_DEPTH_VIS_TOPIC="${DEBUG_DEPTH_VIS_TOPIC:-/debug_depth_vis}"
fi

if [ "$USE_DEPTH" = "true" ]; then
    if [ ! -f "$REALSENSE_CONFIG" ]; then
        print_error "use_depth=true 但 RealSense 配置不存在: $REALSENSE_CONFIG"
        exit 1
    fi
    if [ ! -f "$DEPTH_CONFIG" ]; then
        print_error "use_depth=true 但深度节点配置不存在: $DEPTH_CONFIG"
        exit 1
    fi
    if [ "$USE_DEPTH_ENCODER" = "true" ] && [ ! -f "$CAMERA_DIR/models/$DEPTH_ENCODER_MODEL" ]; then
        print_error "深度编码器模型不存在: $CAMERA_DIR/models/$DEPTH_ENCODER_MODEL"
        exit 1
    fi
fi

print_info "选择机器人: $ROBOT"
print_info "选择策略: $POLICY"
print_info "深度感知: $USE_DEPTH"

# 设置 DDS 配置文件
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export RMW_FASTRTPS_USE_QOS_FROM_XML=1
export FASTRTPS_DEFAULT_PROFILES_FILE="$(pwd)/assets/rt_fastdds_profile.xml"
print_info "设置 DDS 配置文件: $FASTRTPS_DEFAULT_PROFILES_FILE"

# 检查 DDS 配置文件是否存在
if [ ! -f "$FASTRTPS_DEFAULT_PROFILES_FILE" ]; then
    print_error "DDS 配置文件不存在: $FASTRTPS_DEFAULT_PROFILES_FILE"
    exit 1
fi

# 检查是否已source setup文件
if [ -z "$AMENT_PREFIX_PATH" ]; then
    print_info "未检测到ROS 2环境，正在执行source..."
    source /opt/ros/humble/setup.bash || {
        print_error "无法source /opt/ros/humble/setup.bash，请检查路径是否正确"
        exit 1
    }
fi

# 检查 colcon 和 ros2
if ! command -v colcon &> /dev/null; then
    print_error "colcon 未安装，请安装 ROS 2 开发工具"
    exit 1
fi
if ! command -v ros2 &> /dev/null; then
    print_error "ros2 未安装"
    exit 1
fi

# 检查是否已安装screen
if ! command -v screen &> /dev/null; then
    print_error "screen 未安装"
    exit 1
fi

# 编译工作空间（含 imu / motors / inference / camera；realsense-ros 在 camera/thirdparty 下）
print_info "编译工作空间..."
# realsense-ros 嵌在 camera 包的 thirdparty 内，需额外 base-paths 才能被 colcon 发现
COLCON_BASE_PATHS=(src)
if [ -d src/camera/thirdparty/realsense-ros ]; then
    COLCON_BASE_PATHS+=(src/camera/thirdparty/realsense-ros)
fi
# 工作区改名后 CMakeCache 仍指向旧路径时，清掉过期 build/install
WS_ROOT="$(pwd)"
if compgen -G "build/*/CMakeCache.txt" > /dev/null; then
    if ! grep -Rql "CMAKE_HOME_DIRECTORY:INTERNAL=${WS_ROOT}/" build --include='CMakeCache.txt' 2>/dev/null; then
        print_info "检测到过期 CMake 缓存（工作区路径已变更），清理 build/install ..."
        rm -rf build install log
    fi
fi
# 若系统已装 apt 版 realsense2_*，允许工作空间源码包覆盖
colcon build --symlink-install \
    --base-paths "${COLCON_BASE_PATHS[@]}" \
    --allow-overriding realsense2_camera realsense2_camera_msgs realsense2_description || {
    print_error "工作空间编译失败"
    exit 1
}
source install/setup.bash

if [ "$USE_DEPTH" = "true" ]; then
    if ! ros2 pkg prefix realsense2_camera &>/dev/null; then
        print_error "realsense2_camera 未找到。请确认 src/camera/thirdparty/realsense-ros 子模块已初始化，且系统已安装 librealsense2（如: sudo apt install ros-humble-librealsense2）"
        exit 1
    fi
    if ! ros2 pkg prefix camera &>/dev/null; then
        print_error "camera 包未找到，请检查 src/camera 是否编译成功"
        exit 1
    fi
fi

# 停止可能正在运行的screen会话
print_info "停止现有所有screen会话..."
cleanup_sessions

if [ "$USE_DEPTH" = "true" ]; then
    # depth.launch.py 内会先启 RealSense，再启 depth_node（encoder + debug 图）
    print_info "启动 depth_session（RealSense + Depth Process）..."
    print_info "RealSense 配置文件: $REALSENSE_CONFIG"
    screen -dmS depth_session bash -c "source install/setup.bash; export RMW_IMPLEMENTATION='$RMW_IMPLEMENTATION'; export RMW_FASTRTPS_USE_QOS_FROM_XML='$RMW_FASTRTPS_USE_QOS_FROM_XML'; export FASTRTPS_DEFAULT_PROFILES_FILE='$FASTRTPS_DEFAULT_PROFILES_FILE'; ros2 launch camera depth.launch.py policy:=$POLICY realsense_config:=$REALSENSE_CONFIG; exec bash"
    if ! verify_realsense_startup "$DEPTH_TOPIC"; then
        cleanup_sessions
        exit 1
    fi
    if ! verify_depth_startup "$DEPTH_OBS_TOPIC" "$DEBUG_DEPTH_VIS_TOPIC" "$DEBUG_VIS"; then
        cleanup_sessions
        exit 1
    fi
fi

print_info "启动 inference_session ..."
# depth_node 已单独启动时，传 start_depth_node:=false，避免重复拉起
INFERENCE_LAUNCH_ARGS="robot:=$ROBOT policy:=$POLICY"
if [ "$USE_DEPTH" = "true" ]; then
    INFERENCE_LAUNCH_ARGS="$INFERENCE_LAUNCH_ARGS use_depth:=true start_depth_node:=false"
fi
screen -dmS inference_session bash -c "source install/setup.bash; export RMW_IMPLEMENTATION='$RMW_IMPLEMENTATION'; export RMW_FASTRTPS_USE_QOS_FROM_XML='$RMW_FASTRTPS_USE_QOS_FROM_XML'; export FASTRTPS_DEFAULT_PROFILES_FILE='$FASTRTPS_DEFAULT_PROFILES_FILE'; ros2 launch roboparty_inference inference.launch.py $INFERENCE_LAUNCH_ARGS; exec bash"
if ! verify_inference_startup; then
    cleanup_sessions
    exit 1
fi

start_component "joy_session" "ros2 run joy joy_node" "joy_node" 3

# 验证节点的 DDS 配置
verify_dds_effectiveness

# 所有组件启动完成
print_success "----------------------------------------"
print_success "所有组件已在后台成功启动！"
print_success "使用以下命令查看各组件输出："
if [ "$USE_DEPTH" = "true" ]; then
    print_success "相机 + 深度编码: screen -r depth_session"
fi
print_success "推理模块: screen -r inference_session"
print_success "手柄控制: screen -r joy_session"
print_success "----------------------------------------"
print_info "若要退出某个screen会话，按Ctrl+A然后按D"
print_info "使用以下命令停止所有组件："
if [ "$USE_DEPTH" = "true" ]; then
    print_info "screen -S depth_session -X quit"
fi
print_info "screen -S inference_session -X quit"
print_info "screen -S joy_session -X quit"
print_success "----------------------------------------"
print_info "手柄控制说明:"
print_info "X键: 使能/失能电机"
print_info "A键: 复位电机"
print_info "B键: 开始/暂停推理"
print_info "Y键: 切换手柄控制/cmd_vel指令控制"
print_info "LB键: 切换策略模式(在beyondmimic/interrupt模式下可用)"
print_info "RB键: 切换运动序列(在beyondmimic模式下可用)"
print_info "右摇杆: 控制前后左右移动"
print_info "LT/RT: 控制转向(左/右旋转)"
