#!/usr/bin/env python3
import os
import argparse
import sys
import yaml

# Prefer this workspace's driver over an older system installation.
workspace_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
driver_dir = os.path.join(
    workspace_dir, "install", "roboparty_motors", "lib",
    f"python{sys.version_info.major}.{sys.version_info.minor}", "site-packages",
)
if os.path.isdir(driver_dir):
    sys.path.insert(0, driver_dir)
import motors_py
import time
import termios
import tty


def read_key_nonblocking(timeout=0.05):
    import select
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        if select.select([sys.stdin], [], [], timeout)[0]:
            ch = sys.stdin.read(1)
            return ch
        return None
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)


def load_config(config_path: str) -> dict:
    with open(config_path, 'r', encoding='utf-8') as f:
        config = yaml.safe_load(f)
    return config


def create_motors(config: dict) -> list:
    motors = []
    motor_ids = config['motor_id']
    motor_interface_types = config['motor_interface_type']
    motor_interfaces = config['motor_interface']
    if isinstance(motor_interface_types, str):
        motor_interface_types = [motor_interface_types] * len(motor_interfaces)
    motor_num = config['motor_num']
    motor_type = config['motor_type']
    if isinstance(motor_type, str):
        motor_type = [motor_type] * len(motor_interfaces)
    motor_models = config['motor_model']
    master_id_offset = config['master_id_offset']
    motor_zero_offsets = config['motor_zero_offset']
    
    motor_idx = 0
    for interface_idx, num in enumerate(motor_num):
        interface = motor_interfaces[interface_idx]
        interface_type = motor_interface_types[interface_idx]
        for _ in range(num):
            if motor_idx >= len(motor_ids):
                break
            motor_id = motor_ids[motor_idx]
            motor_model = motor_models[motor_idx] if motor_idx < len(motor_models) else 0
            motor_zero_offset = motor_zero_offsets[motor_idx] if motor_idx < len(motor_zero_offsets) else 0.0
            
            motor = motors_py.MotorDriver.create_motor(
                motor_id=motor_id,
                interface_type=interface_type,
                interface=interface,
                motor_type=motor_type[interface_idx],
                motor_model=motor_model,
                master_id_offset=master_id_offset,
                motor_zero_offset=motor_zero_offset,
            )
            use_batch_mit = (interface_type == "canfd" and motor_type[interface_idx] in ("EVO", "RP"))
            motors.append({
                'motor': motor,
                'motor_id': motor_id,
                'interface': interface,
                'interface_type': interface_type,
                'index': motor_idx,
                'use_batch_mit': use_batch_mit,
            })
            motor_idx += 1
    
    return motors


def calibrate_motor(motor_info: dict) -> bool:
    motor = motor_info['motor']
    motor_id = motor_info['motor_id']
    interface = motor_info['interface']
    use_batch_mit = motor_info.get('use_batch_mit', False)
    print(f"\n{'='*50}")
    print(f"正在标定电机 ID: {motor_id} (接口: {interface})")
    print(f"{'='*50}")
    
    print("使能电机...")
    motor.init_motor()
    time.sleep(0.3)
    
    print("设置纯阻尼控制模式...")
    motor.set_motor_control_mode(motors_py.MotorControlMode.MIT)
    time.sleep(0.1)
    
    print("\n>>> 请手动将电机摆到零位 <<<")
    print("提示: 电机现在处于阻尼模式，可以自由转动")
    print("操作: 按 [Enter] 确认标零 | 按 [空格] 跳过此电机")

    if use_batch_mit:
        p_arr = [0.0] * 8
        v_arr = [0.0] * 8
        kp_arr = [0.0] * 8
        kd_arr = [2.0] * 8
        t_arr = [0.0] * 8

    zeroed = False
    try:
        while True:
            if use_batch_mit:
                motor.motors_mit_cmd(p_arr, v_arr, kp_arr, kd_arr, t_arr)
            else:
                motor.motor_mit_cmd(0.0, 0.0, 0.0, 2.0, 0.0)
            
            pos = motor.get_motor_pos()
            err = motor.get_error_id()
            print(f"\r当前位置: {pos:+.6f} rad | 错误码: {err} | [Enter]标零 / [空格]跳过", end='', flush=True)
            
            key = read_key_nonblocking(0.05)
            if key == '\r' or key == '\n':  # Enter
                motor.set_motor_zero()
                zeroed = True
                break
            elif key == ' ':  # Space
                zeroed = False
                break
            elif key == '\x03':  # Ctrl+C
                raise KeyboardInterrupt
            
            time.sleep(0.02)
    except KeyboardInterrupt:
        print("\n\n用户中断标定")
        motor.deinit_motor()
        raise
    
    print("失能电机...")
    motor.deinit_motor()
    time.sleep(0.2)
    
    return zeroed


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description='Motor zero calibration')
    parser.add_argument('--config', default=os.path.join(script_dir, 'config', 'set_zero_rpo.yaml'))
    config_path = parser.parse_args().config
    
    print("="*60)
    print("           电机零点标定工具")
    print("="*60)
    print(f"\n配置文件: {config_path}\n")
    
    try:
        config = load_config(config_path)
    except Exception as e:
        print(f"加载配置文件失败: {e}")
        return 1
    
    print("配置信息:")
    print(f"  - 电机ID列表: {config['motor_id']}")
    print(f"  - 电机类型: {config['motor_type']}")
    print(f"  - 接口类型: {config['motor_interface_type']}")
    print(f"  - 接口: {config['motor_interface']}")
    print(f"  - 电机型号: {config['motor_model']}")
    print("\n" + "-"*60)
    input("按 Enter 开始标定流程...")
    print("-"*60)
    
    try:
        motors = create_motors(config)
        print(f"\n成功创建 {len(motors)} 个电机对象")
    except Exception as e:
        print(f"创建电机失败: {e}")
        return 1
    
    try:
        zeroed_ids = []
        skipped_ids = []
        for motor_info in motors:
            result = calibrate_motor(motor_info)
            if result:
                zeroed_ids.append(motor_info['motor_id'])
                print(f"电机 {motor_info['motor_id']} 标定完成!")
            else:
                skipped_ids.append(motor_info['motor_id'])
                print(f"电机 {motor_info['motor_id']} 已跳过")
    except KeyboardInterrupt:
        print("\n\n标定被用户中断")
        return 1
    except Exception as e:
        print(f"\n标定过程出错: {e}")
        return 1
    
    print("\n" + "="*60)
    print("         标定流程完成!")
    print("="*60)
    if zeroed_ids:
        print(f"  已标零电机: {zeroed_ids}")
    if skipped_ids:
        print(f"  已跳过电机: {skipped_ids}")
    
    print("\n标定流程结束，请将已标零电机重新上下电后再使用新的零点")
    return 0


if __name__ == '__main__':
    sys.exit(main())
