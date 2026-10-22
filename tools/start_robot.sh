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
    echo "默认: robot=rpo, policy=default；ROS 自动检测，仅支持 Humble、Jazzy"
    echo "示例: $0 --robot rpo --policy amp"
    echo "示例: $0 rpo beyondmimic"
}

validate_name() {
    local label=$1
    local value=$2

    if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        print_error "$label 必须以字母或数字开头，且只能包含字母、数字、下划线、短横线和点: $value"
        exit 1
    fi
}

ROBOT="rpo"
POLICY="default"
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

export ROBOT_CONTROL_ISOLATION="${ROBOT_CONTROL_ISOLATION:-isolated}"

# 函数：启动组件并检查（先启动ROS节点，再设置实时优先级）
start_component() {
    local session_name=$1
    local launch_cmd=$2
    local node_name=$3
    local sleep_time=$4

    print_info "启动 $session_name ..."
    local screen_args=(-dmS "$session_name")
    local authenticate=""
    if [ "$session_name" = "inference_session" ] && [ "$ROBOT_CONTROL_ISOLATION" = "isolated" ] && [ "$EUID" -ne 0 ]; then
        if [ -t 0 ] && [ -t 1 ]; then
            print_info "请在会话内完成 sudo 验证，随后自动转入后台；仅隔离管理程序提权"
            screen_args=(-S "$session_name")
            # sudo credentials belong to this screen's terminal.
            authenticate='sudo -v || exit 1; screen -d "$STY"; '
        else
            print_info "无交互终端，隔离管理程序将使用 sudo 非交互授权"
        fi
    fi
    screen "${screen_args[@]}" bash -c "${authenticate}source install/setup.bash; export RMW_IMPLEMENTATION='$RMW_IMPLEMENTATION'; export RMW_FASTRTPS_USE_QOS_FROM_XML='$RMW_FASTRTPS_USE_QOS_FROM_XML'; export FASTRTPS_DEFAULT_PROFILES_FILE='$FASTRTPS_DEFAULT_PROFILES_FILE'; $launch_cmd; exec bash" || {
        cleanup_sessions
        return 1
    }
    sleep $sleep_time

    if ! ros2 node list | grep -q "$node_name"; then
        print_error "$session_name 启动失败！未检测到 $node_name 节点。"
        cleanup_sessions
        exit 1
    fi
}

# 函数：清理所有会话
cleanup_sessions() {
    screen -S inference_session -X quit 2>/dev/null
    screen -S joy_session -X quit 2>/dev/null
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
    for node in "inference_node" "joy_node"; do
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

# 切换到脚本目录
cd "$(dirname "$0")"
cd ..

POLICY_FILE="$POLICY"
if [[ "$POLICY_FILE" != *.yaml ]]; then
    POLICY_FILE="${POLICY_FILE}.yaml"
fi

ROBOT_DIR="src/inference/robots/$ROBOT"
if [ ! -f "$ROBOT_DIR/robot.yaml" ]; then
    print_error "机器人配置不存在: $ROBOT_DIR/robot.yaml"
    exit 1
fi
if [ ! -f "$ROBOT_DIR/configs/$POLICY_FILE" ]; then
    print_error "推理配置不存在: $ROBOT_DIR/configs/$POLICY_FILE"
    exit 1
fi

print_info "选择机器人: $ROBOT"
print_info "选择策略: $POLICY"

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

source tools/ros_environment.sh || exit 1
setup_ros_environment || exit 1

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

# 编译推理包
print_info "编译推理包..."
colcon build --symlink-install || {
    print_error "推理包编译失败"
    exit 1
}
source install/setup.bash

# 停止可能正在运行的screen会话
print_info "停止现有相关screen会话..."
cleanup_sessions
if [ -e /run/roboparty-realtime.lock ]; then
    if ! (flock -x -w 25 9) 9< /run/roboparty-realtime.lock; then
        print_error "上一推理实例仍未退出或未完成恢复，请检查 screen -r inference_session"
        exit 1
    fi
fi

start_component "inference_session" "ros2 launch roboparty_inference inference.launch.py robot:=$ROBOT policy:=$POLICY" "inference_node" 5 || exit 1
start_component "joy_session" "ros2 run joy joy_node" "joy_node" 2 || exit 1

# 验证节点的 DDS 配置
verify_dds_effectiveness

# 所有组件启动完成
print_success "----------------------------------------"
print_success "所有组件已在后台成功启动！"
print_success "使用以下命令查看各组件输出："
print_success "推理模块: screen -r inference_session"
print_success "手柄控制: screen -r joy_session"
print_success "----------------------------------------"
print_info "若要退出某个screen会话，按Ctrl+A然后按D"
print_info "使用以下命令停止所有组件："
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
