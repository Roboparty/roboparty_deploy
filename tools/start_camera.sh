#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_info() {
    echo -e "${YELLOW}$1${NC}"
}

print_error() {
    echo -e "${RED}$1${NC}"
}

show_usage() {
    echo "用法: $0 [--policy POLICY]"
    echo "      $0 [POLICY]"
    echo
    echo "分别在 realsense_session 和 camera_session 中启动 RealSense 与 depth_node。"
    echo
    echo "默认: policy=parkour；ROS 自动检测，仅支持 Humble、Jazzy"
    echo "示例: $0"
    echo "示例: $0 --policy parkour"
}

validate_name() {
    local label=$1
    local value=$2

    if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        print_error "$label 必须以字母或数字开头，且只能包含字母、数字、下划线、短横线和点: $value"
        exit 1
    fi
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

verify_topic_stream() {
    local topic=$1
    local label=$2
    local session_name=$3
    local max_attempts=${4:-2}
    local attempt
    local hz_line

    if ! wait_for_topic "$topic" 10; then
        print_error "$label 话题不存在: $topic"
        print_info "查看日志: screen -r $session_name"
        return 1
    fi
    print_success "$label 话题已发布: $topic"

    print_info "检测 $label 数据流..."
    for ((attempt = 1; attempt <= max_attempts; ++attempt)); do
        hz_line=$(timeout 3 ros2 topic hz "$topic" 2>&1 | grep -m 1 "average rate")
        if [ -n "$hz_line" ]; then
            print_success "$label 数据流正常 ($hz_line)"
            return 0
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            print_info "$label 数据流检测未完成，重试 ($attempt/$max_attempts)..."
        fi
    done

    print_error "$label 数据流检测失败！话题存在但未收到持续数据"
    print_info "查看日志: screen -r $session_name"
    return 1
}

cleanup_camera_sessions() {
    local session
    # depth_session is the legacy name used by start_robot_depth.sh.
    for session in realsense_session camera_session depth_session; do
        # 参数指定的会话保留，用于查看启动失败原因
        [ "$session" = "${1:-}" ] && continue
        screen -S "$session" -X quit &>/dev/null || true
    done
}

verify_realsense_startup() {
    local depth_topic=$1

    print_info "验证 RealSense 相机是否启动成功..."
    if ! wait_for_node "^/camera/camera$" 10; then
        print_error "RealSense 启动失败！未检测到相机节点。"
        print_info "请检查: 1) D435i 是否插入 USB3.0  2) lsusb | grep 8086  3) screen -r realsense_session"
        return 1
    fi
    print_success "RealSense 节点已上线"

    verify_topic_stream "$depth_topic" "RealSense 深度图" "realsense_session"
}

verify_depth_startup() {
    local depth_obs_topic=$1

    print_info "等待 depth_node..."
    if ! wait_for_node "^/depth_node$" 10; then
        print_error "未检测到 depth_node"
        print_info "可执行 screen -r camera_session 查看日志"
        return 1
    fi
    print_success "depth_node 已上线，开始预处理 / 编码"

    verify_topic_stream "$depth_obs_topic" "深度观测" "camera_session"
}

POLICY="parkour"
POLICY_SET=0

while [ $# -gt 0 ]; do
    case "$1" in
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
            if [ "$POLICY_SET" -eq 0 ]; then
                POLICY="$1"
                POLICY_SET=1
                shift
            else
                print_error "未知参数: $1"
                show_usage
                exit 1
            fi
            ;;
    esac
done

validate_name "policy" "$POLICY"

cd "$(dirname "$0")"
cd ..

POLICY_FILE="$POLICY"
if [[ "$POLICY_FILE" != *.yaml ]]; then
    POLICY_FILE="${POLICY_FILE}.yaml"
fi

CAMERA_DIR="src/camera"
DEPTH_CONFIG="$CAMERA_DIR/configs/$POLICY_FILE"
REALSENSE_CONFIG="$CAMERA_DIR/configs/realsense_d435i.yaml"
DEPTH_TOPIC="/camera/camera/depth/image_rect_raw"
DEPTH_OBS_TOPIC="/depth_obs"

if [ ! -f "$DEPTH_CONFIG" ]; then
    print_error "相机深度配置不存在: $DEPTH_CONFIG"
    exit 1
fi
if [ ! -f "$REALSENSE_CONFIG" ]; then
    print_error "RealSense 配置不存在: $REALSENSE_CONFIG"
    exit 1
fi

print_info "选择相机策略配置: $POLICY"

export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export RMW_FASTRTPS_USE_QOS_FROM_XML=1
export FASTRTPS_DEFAULT_PROFILES_FILE="$(pwd)/assets/rt_fastdds_profile.xml"
print_info "设置 DDS 配置文件: $FASTRTPS_DEFAULT_PROFILES_FILE"

if [ ! -f "$FASTRTPS_DEFAULT_PROFILES_FILE" ]; then
    print_error "DDS 配置文件不存在: $FASTRTPS_DEFAULT_PROFILES_FILE"
    exit 1
fi

source tools/ros_environment.sh || exit 1
setup_ros_environment || exit 1

if ! command -v colcon &>/dev/null; then
    print_error "colcon 未安装，请安装 ROS 2 开发工具"
    exit 1
fi
if ! command -v ros2 &>/dev/null; then
    print_error "ros2 未安装"
    exit 1
fi
if ! command -v screen &>/dev/null; then
    print_error "screen 未安装"
    exit 1
fi

print_info "编译相机组件..."
COLCON_BASE_PATHS=(src/camera)
BUILD_PACKAGES=(roboparty_camera)
ALLOW_OVERRIDING=()
if [ -f src/camera/thirdparty/realsense-ros/realsense2_camera/package.xml ]; then
    COLCON_BASE_PATHS+=(src/camera/thirdparty/realsense-ros)
    BUILD_PACKAGES+=(realsense2_camera)
    ALLOW_OVERRIDING=(
        --allow-overriding
        realsense2_camera
        realsense2_camera_msgs
        realsense2_description
    )
fi

colcon build --symlink-install \
    --base-paths "${COLCON_BASE_PATHS[@]}" \
    --packages-up-to "${BUILD_PACKAGES[@]}" \
    "${ALLOW_OVERRIDING[@]}" || {
    print_error "相机组件编译失败"
    exit 1
}
source install/setup.bash

if ! ros2 pkg prefix realsense2_camera &>/dev/null; then
    print_error "realsense2_camera 未找到。请检查内置 src/camera/thirdparty/realsense-ros 是否完整，或安装 ROS 2 RealSense 包"
    exit 1
fi
if ! ros2 pkg prefix roboparty_camera &>/dev/null; then
    print_error "roboparty_camera 包未找到，请检查 src/camera 是否编译成功"
    exit 1
fi

print_info "停止现有相机会话..."
cleanup_camera_sessions

print_info "启动 realsense_session（RealSense）..."
print_info "RealSense 配置文件: $REALSENSE_CONFIG"
screen -dmS realsense_session bash -c "source install/setup.bash; export RMW_IMPLEMENTATION='$RMW_IMPLEMENTATION'; export RMW_FASTRTPS_USE_QOS_FROM_XML='$RMW_FASTRTPS_USE_QOS_FROM_XML'; export FASTRTPS_DEFAULT_PROFILES_FILE='$FASTRTPS_DEFAULT_PROFILES_FILE'; ros2 launch realsense2_camera rs_launch.py config_file:='$REALSENSE_CONFIG'; exec bash"

if ! verify_realsense_startup "$DEPTH_TOPIC"; then
    # 停止仍在运行的启动命令，保留会话以便查看输出
    screen -S realsense_session -X stuff $'\003'
    cleanup_camera_sessions realsense_session
    exit 1
fi

print_info "启动 camera_session（depth_node）..."
screen -dmS camera_session bash -c "source install/setup.bash; export RMW_IMPLEMENTATION='$RMW_IMPLEMENTATION'; export RMW_FASTRTPS_USE_QOS_FROM_XML='$RMW_FASTRTPS_USE_QOS_FROM_XML'; export FASTRTPS_DEFAULT_PROFILES_FILE='$FASTRTPS_DEFAULT_PROFILES_FILE'; ros2 launch roboparty_camera depth.launch.py policy:='$POLICY' start_camera:=false; exec bash"

if ! verify_depth_startup "$DEPTH_OBS_TOPIC"; then
    # 停止仍在运行的启动命令，保留会话以便查看输出
    screen -S camera_session -X stuff $'\003'
    cleanup_camera_sessions camera_session
    exit 1
fi

print_success "----------------------------------------"
print_success "相机和深度处理已在后台成功启动！"
print_success "RealSense: screen -r realsense_session"
print_success "深度处理: screen -r camera_session"
print_success "----------------------------------------"
print_info "若要退出 screen 会话，按 Ctrl+A，然后按 D"
print_info "停止 RealSense: screen -S realsense_session -X quit"
print_info "停止深度处理: screen -S camera_session -X quit"
print_info "机器人推理另行启动: ./tools/start_robot.sh"
