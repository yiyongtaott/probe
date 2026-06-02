import sys
import struct

def main():
    if len(sys.argv) < 2:
        print("用法: python fix_subsystem.py <exe文件>")
        sys.exit(1)
    
    filename = sys.argv[1]
    
    try:
        # 以二进制模式读写文件
        with open(filename, 'r+b') as f:
            # 1. 读取DOS头，获取PE头偏移 (Offset 0x3C)
            f.seek(0x3C)
            pe_offset_bytes = f.read(4)
            pe_offset = struct.unpack('<I', pe_offset_bytes)[0]
            
            # 2. 计算子系统字段位置 (PE头起始 + 0x5C)
            # PE Header (4 bytes) + File Header (20 bytes) + Optional Header (Subsystem is at 68th byte)
            subsystem_offset = pe_offset + 0x5C
            
            # 3. 读取当前子系统值
            f.seek(subsystem_offset)
            current_subsystem_bytes = f.read(2)
            current_subsystem = struct.unpack('<H', current_subsystem_bytes)[0]
            
            subsystem_names = {
                1: "Native",
                2: "Windows GUI (无窗口)",
                3: "Windows CUI (控制台)",
            }
            
            current_name = subsystem_names.get(current_subsystem, f"未知({current_subsystem})")
            print(f"检测到当前子系统: {current_name}")
            
            # 4. 自动转换逻辑
            target_subsystem = None
            if current_subsystem == 3:
                target_subsystem = 2
                print("目标操作：控制台程序 -> GUI程序 (隐藏启动时的黑窗口)")
            elif current_subsystem == 2:
                target_subsystem = 3
                print("目标操作：GUI程序 -> 控制台程序 (显示标准输出日志)")
            else:
                print(f"当前子系统为 {current_name}，非标准 CUI/GUI 程序，不建议自动修改。")
                return

            # 5. 执行修改
            f.seek(subsystem_offset)
            f.write(struct.pack('<H', target_subsystem))
            
            # 6. 验证
            f.seek(subsystem_offset)
            new_subsystem = struct.unpack('<H', f.read(2))[0]
            new_name = subsystem_names.get(new_subsystem, "未知")
            
            print("-" * 30)
            print(f"修改成功！")
            print(f"新子系统: {new_name}")
                
    except FileNotFoundError:
        print(f"错误: 文件 '{filename}' 不存在")
    except PermissionError:
        print(f"错误: 权限不足。请检查文件是否被占用，或尝试以管理员身份运行。")
    except Exception as e:
        print(f"错误: {e}")

if __name__ == "__main__":
    main()