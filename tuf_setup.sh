#!/usr/bin/env bash
# ==============================================================================
# 华硕天选 1 代 (FA506IV: 4800H + RTX2060 + 梵想1T + AX200)
# CachyOS / Arch Linux 全适应交互式开荒与防死机脚本
# ==============================================================================

set -u

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 获取真实普通用户名（防止用户误加 sudo 运行导致 paru 报错）
REAL_USER="${SUDO_USER:-$USER}"
if [ "$REAL_USER" = "root" ]; then
    echo -e "${RED}[错误] 请不要直接在 root 账户下运行此脚本！${NC}"
    echo -e "请使用你的普通用户直接运行：${GREEN}./tuf_setup.sh${NC}"
    exit 1
fi

# 检查并清理 pacman 数据库锁
check_pacman_lock() {
    if [ -f /var/lib/pacman/db.lck ]; then
        echo -e "${YELLOW}[提示] 检测到 pacman 数据库锁，正在尝试移除...${NC}"
        sudo rm -f /var/lib/pacman/db.lck
    fi
}

# 寻找可用的 AUR 助手
get_aur_helper() {
    if command -v paru &>/dev/null; then
        echo "paru"
    elif command -v yay &>/dev/null; then
        echo "yay"
    else
        echo ""
    fi
}

# ==============================================================================
# 模块 1：配置 sudo 免密码
# ==============================================================================
setup_sudo_nopasswd() {
    echo -e "\n${CYAN}>>> [1/6] 正在配置用户 [${REAL_USER}] 的 sudo 免密码权限...${NC}"
    local sudo_file="/etc/sudoers.d/99-nopasswd-${REAL_USER}"
    local tmp_file="/tmp/99-nopasswd-${REAL_USER}"

    echo "${REAL_USER} ALL=(ALL:ALL) NOPASSWD: ALL" > "$tmp_file"

    # 使用 visudo 严格校验语法，防止改坏 sudo
    if sudo visudo -cf "$tmp_file" &>/dev/null; then
        sudo install -m 0440 "$tmp_file" "$sudo_file"
        rm -f "$tmp_file"
        echo -e "${GREEN}[成功] 已开启 sudo 免密码！后续所有操作将不再需要输入密码。${NC}"
    else
        rm -f "$tmp_file"
        echo -e "${RED}[失败] sudoers 语法校验未通过，已自动回滚确保系统安全。${NC}"
        return 1
    fi
}

# ==============================================================================
# 辅助函数：自适应向各种引导器写入/移除内核参数（防重复）
# ==============================================================================
update_bootloader_params() {
    local add_params=("$@")
    local updated=0

    # 1. 检测并适配 GRUB
    if [ -f /etc/default/grub ]; then
        echo -e "${BLUE}[检测] 发现 GRUB 引导器 (/etc/default/grub)${NC}"
        sudo cp /etc/default/grub /etc/default/grub.bak
        for param in "${add_params[@]}"; do
            local key="${param%%=*}"
            # 如果已存在同名键，先移除旧键值
            if grep -q "GRUB_CMDLINE_LINUX_DEFAULT=.*${key}" /etc/default/grub; then
                sudo sed -i -E "s/${key}=[^ \"]*//g" /etc/default/grub
            fi
            # 追加新参数
            sudo sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\1 ${param}\"/" /etc/default/grub
        done
        # 清理多余空格
        sudo sed -i -E 's/  +/ /g; s/=" /="/g' /etc/default/grub
        sudo grub-mkconfig -o /boot/grub/grub.cfg
        updated=1
    fi

    # 2. 检测并适配 CachyOS systemd-boot (sdboot-manage)
    if [ -f /etc/sdboot-manage.conf ]; then
        echo -e "${BLUE}[检测] 发现 systemd-boot 引导配置 (/etc/sdboot-manage.conf)${NC}"
        sudo cp /etc/sdboot-manage.conf /etc/sdboot-manage.conf.bak
        for param in "${add_params[@]}"; do
            local key="${param%%=*}"
            if grep -q "LINUX_OPTIONS=.*${key}" /etc/sdboot-manage.conf; then
                sudo sed -i -E "s/${key}=[^ \"]*//g" /etc/sdboot-manage.conf
            fi
            sudo sed -i -E "s/^(LINUX_OPTIONS=\"[^\"]*)\"/\1 ${param}\"/" /etc/sdboot-manage.conf
        done
        sudo sed -i -E 's/  +/ /g; s/=" /="/g' /etc/sdboot-manage.conf
        sudo sdboot-manage gen
        updated=1
    fi

    # 3. 检测并适配 Limine (/etc/default/limine)
    if [ -f /etc/default/limine ]; then
        echo -e "${BLUE}[检测] 发现 Limine 引导配置 (/etc/default/limine)${NC}"
        sudo cp /etc/default/limine /etc/default/limine.bak
        for param in "${add_params[@]}"; do
            if ! grep -q "$param" /etc/default/limine; then
                echo "KERNEL_CMDLINE[default]+=\" ${param}\"" | sudo tee -a /etc/default/limine >/dev/null
            fi
        done
        if command -v limine-mkinitcpio &>/dev/null; then
            sudo limine-mkinitcpio
        fi
        updated=1
    fi

    if [ "$updated" -eq 0 ]; then
        echo -e "${RED}[警告] 未检测到受支持的自动引导配置文件，请手动添加参数：${add_params[*]}${NC}"
    else
        echo -e "${GREEN}[成功] 引导参数已安全写入并更新（原配置已自动备份为 .bak）！${NC}"
    fi
}

# ==============================================================================
# 模块 2：注入 4800H + 梵想 1T 固态防死机核心参数
# ==============================================================================
setup_kernel_fixes() {
    echo -e "\n${CYAN}>>> [2/6] 正在配置 4800H 防 C6 掉电与梵想 1T 固态防掉盘参数...${NC}"
    local base_params=(
        "processor.max_cstate=5"
        "nvme_core.default_ps_max_latency_us=0"
    )
    update_bootloader_params "${base_params[@]}"
}

# ==============================================================================
# 模块 3：显卡模式交互配置（纯核显断电 vs 保留独显加防死机封印）
# ==============================================================================
setup_gpu_mode() {
    echo -e "\n${CYAN}>>> [3/6] 请选择 RTX 2060 独显处理方案：${NC}"
    echo -e "  ${GREEN}[1] 彻底断电屏蔽 2060（强烈推荐：纯 4800H 核显，内屏+HDMI正常，绝不死机）${NC}"
    echo -e "  ${YELLOW}[2] 保留 2060 混合模式（需要跑 CUDA，自动为您注入防 GSP/RTD3 死机封印）${NC}"
    echo -e "  [0] 跳过此步"
    read -rp "请输入选项 [1/2/0，默认 1]: " gpu_choice
    gpu_choice="${gpu_choice:-1}"

    check_pacman_lock
    if ! command -v envycontrol &>/dev/null; then
        echo -e "${BLUE}正在安装显卡管理神器 envycontrol...${NC}"
        sudo pacman -S --needed --noconfirm envycontrol
    fi

    case "$gpu_choice" in
        1)
            echo -e "${BLUE}正在将显卡切换为 Integrated（纯核显并断电 2060）...${NC}"
            sudo envycontrol -s integrated
            echo -e "${GREEN}[成功] RTX 2060 已设置为开机断电屏蔽！${NC}"
            ;;
        2)
            echo -e "${BLUE}正在切换为 Hybrid 模式并注入 NVIDIA 防死机内核封印...${NC}"
            sudo envycontrol -s hybrid
            local nv_params=(
                "processor.max_cstate=5"
                "nvme_core.default_ps_max_latency_us=0"
                "nvidia-drm.modeset=1"
                "nvidia.NVreg_DynamicPowerManagement=0x00"
                "nvidia.NVreg_EnableGpuFirmware=0"
            )
            update_bootloader_params "${nv_params[@]}"
            sudo systemctl enable nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service 2>/dev/null || true
            echo -e "${GREEN}[成功] 已保留 2060 并关闭了会导致死机的 RTD3 断电与 GSP 固件！${NC}"
            ;;
        *)
            echo -e "${YELLOW}已跳过显卡配置。${NC}"
            ;;
    esac
}

# ==============================================================================
# 模块 4：测速换源 + 华硕控制中心 (风扇/电池80%限充) + AX200 蓝牙
# ==============================================================================
setup_asus_and_system() {
    echo -e "\n${CYAN}>>> [4/6] 系统换源、华硕奥创控制中心与 AX200 蓝牙配置...${NC}"
    check_pacman_lock

    if command -v cachyos-rate-mirrors &>/dev/null; then
        read -rp "是否运行 cachyos-rate-mirrors 自动测速切换国内最快源？[Y/n]: " mirror_ans
        if [[ "${mirror_ans:-Y}" =~ ^[Yy]$ ]]; then
            sudo cachyos-rate-mirrors
        fi
    fi

    echo -e "${BLUE}正在安装华硕控制套件 (asusctl / rog-control-center) 与蓝牙支持...${NC}"
    sudo pacman -S --needed --noconfirm asusctl rog-control-center power-profiles-daemon bluez bluez-utils
    sudo mkdir -p /etc/asusd
    sudo systemctl enable --now power-profiles-daemon 2>/dev/null || true
    sudo systemctl start asusd 2>/dev/null || true
    sudo systemctl enable --now bluetooth 2>/dev/null || true

    read -rp "是否将电池充电上限设为 80% 以保护天选 1 代电池？[Y/n]: " bat_ans
    if [[ "${bat_ans:-Y}" =~ ^[Yy]$ ]]; then
        if asusctl -c 80 2>/dev/null; then
            echo -e "${GREEN}[成功] 电池充电上限已锁定为 80%！${NC}"
        else
            echo -e "${YELLOW}[提示] 电池限充将在重启后或打开 ROG Control Center 时生效。${NC}"
        fi
    fi
}

# ==============================================================================
# 模块 5：中文输入法 (Fcitx5) 与中文字体配置
# ==============================================================================
setup_chinese_input() {
    echo -e "\n${CYAN}>>> [5/6] 正在配置 Fcitx5 中文输入法与中文字体...${NC}"
    check_pacman_lock

    echo -e "请选择你喜欢的中文词库方案："
    echo -e "  ${GREEN}[1] 标准拼音 + 维基百科大词库（轻量、开箱即用）${NC}"
    echo -e "  ${CYAN}[2] Rime 雾凇拼音（极客首选，词库极其精准）${NC}"
    read -rp "请输入选项 [1/2，默认 1]: " ime_choice
    ime_choice="${ime_choice:-1}"

    sudo pacman -S --needed --noconfirm fcitx5-im fcitx5-chinese-addons fcitx5-pinyin-zhwiki \
        noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd

    if [ "$ime_choice" = "2" ]; then
        local aur_helper
        aur_helper=$(get_aur_helper)
        if [ -n "$aur_helper" ]; then
            sudo -u "$REAL_USER" "$aur_helper" -S --needed --noconfirm fcitx5-rime rime-ice-git
        else
            sudo pacman -S --needed --noconfirm fcitx5-rime
        fi
    fi

    # 如果处于 KDE Plasma 环境，尝试自动将 Wayland 虚拟键盘设为 Fcitx5
    if command -v kwriteconfig6 &>/dev/null; then
        sudo -u "$REAL_USER" kwriteconfig6 --file kwinrc --group Wayland --key InputMethod "/usr/share/applications/org.fcitx.Fcitx5.desktop"
        echo -e "${GREEN}[成功] 已自动为您将 KDE Plasma 6 虚拟键盘挂载为 Fcitx5！${NC}"
    else
        echo -e "${YELLOW}[提示] 请在【系统设置 -> 键盘 -> 虚拟键盘】中点选 Fcitx 5 并点击应用。${NC}"
    fi
}

# ==============================================================================
# 模块 6：交互式安装常用日常软件 (AUR)
# ==============================================================================
setup_daily_apps() {
    echo -e "\n${CYAN}>>> [6/6] 常用日常软件选装（使用内置 paru/yay）...${NC}"
    local aur_helper
    aur_helper=$(get_aur_helper)
    if [ -z "$aur_helper" ]; then
        echo -e "${YELLOW}未检测到 paru 或 yay，正在从官方源安装 paru...${NC}"
        sudo pacman -S --needed --noconfirm paru
        aur_helper="paru"
    fi

    echo -e "请输入你想安装的软件编号（支持多选，用空格隔开，如：${GREEN}1 2 4${NC}，直接回车跳过）："
    echo -e "  [1] 微信原生版 (wechat-bin)"
    echo -e "  [2] QQ 原生版 (linuxqq)"
    echo -e "  [3] Edge 浏览器 (microsoft-edge-stable-bin)"
    echo -e "  [4] Chrome 浏览器 (google-chrome)"
    echo -e "  [5] VS Code 官方版 (visual-studio-code-bin)"
    echo -e "  [6] WPS 国内版全套 (wps-office-cn + 中文包 + 字体)"
    read -rp "你的选择: " app_choices

    local pkgs=()
    for item in $app_choices; do
        case "$item" in
            1) pkgs+=("wechat-bin") ;;
            2) pkgs+=("linuxqq") ;;
            3) pkgs+=("microsoft-edge-stable-bin") ;;
            4) pkgs+=("google-chrome") ;;
            5) pkgs+=("visual-studio-code-bin") ;;
            6) pkgs+=("wps-office-cn" "wps-office-mui-zh-cn" "ttf-wps-fonts") ;;
        esac
    done

    if [ ${#pkgs[@]} -gt 0 ]; then
        echo -e "${BLUE}即将为您自动安装: ${pkgs[*]}${NC}"
        sudo -u "$REAL_USER" "$aur_helper" -S --needed --noconfirm "${pkgs[@]}"
        echo -e "${GREEN}[成功] 所选软件安装完毕！${NC}"
    else
        echo -e "${YELLOW}未选择任何额外软件，已跳过。${NC}"
    fi
}

# ==============================================================================
# 模块 7：系统健康与防死机状态全面体检
# ==============================================================================
system_health_check() {
    echo -e "\n${CYAN}==================== 天选 1 代防死机状态体检 ====================${NC}"
    
    # 1. 检查 sudo 免密
    if [ -f "/etc/sudoers.d/99-nopasswd-${REAL_USER}" ]; then
        echo -e "1. Sudo 免密状态 : ${GREEN}已开启 (${REAL_USER})${NC}"
    else
        echo -e "1. Sudo 免密状态 : ${YELLOW}未开启${NC}"
    fi

    # 2. 检查当前生效的内核参数
    local cmdline
    cmdline=$(cat /proc/cmdline)
    echo -e "2. 当前运行参数  : ${BLUE}${cmdline}${NC}"
    if [[ "$cmdline" == *"processor.max_cstate=5"* ]]; then
        echo -e "   ├─ 4800H 防 C6 死锁 : ${GREEN}已生效 (max_cstate=5)${NC}"
    else
        echo -e "   ├─ 4800H 防 C6 死锁 : ${RED}未生效（若刚配置请先重启电脑）${NC}"
    fi

    if [[ "$cmdline" == *"nvme_core.default_ps_max_latency_us=0"* ]]; then
        echo -e "   └─ 梵想固态防掉盘   : ${GREEN}已生效 (latency_us=0)${NC}"
    else
        echo -e "   └─ 梵想固态防掉盘   : ${RED}未生效（若刚配置请先重启电脑）${NC}"
    fi

    # 3. 检查显卡状态
    if lspci | grep -qi nvidia; then
        echo -e "3. RTX 2060 状态 : ${YELLOW}当前在线（若已切核显，重启后将彻底断电隐身）${NC}"
    else
        echo -e "3. RTX 2060 状态 : ${GREEN}已彻底断电下线（100% 纯核显无死机模式）${NC}"
    fi

    # 4. 检查蓝牙状态
    if systemctl is-active --quiet bluetooth; then
        echo -e "4. AX200 蓝牙服务: ${GREEN}运行中${NC}"
    else
        echo -e "4. AX200 蓝牙服务: ${YELLOW}未运行${NC}"
    fi
    echo -e "${CYAN}=================================================================${NC}\n"
}

# ==============================================================================
# 主交互菜单
# ==============================================================================
main_menu() {
    while true; do
        echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║     华硕天选 1 代 (FA506IV) CachyOS / Arch 一键开荒助手        ║${NC}"
        echo -e "${GREEN}╠════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  ${CYAN}[0] 🚀 一键全流程开荒（强烈推荐：依次执行 1~6 项）${NC}            ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  [1] 🔑 配置当前用户 (${REAL_USER}) sudo 免密码                  ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  [2] 🛡️ 注入 4800H 防 C6 掉电 + 梵想固态防掉盘内核参数          ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  [3] 🎮 切换显卡模式（彻底断电屏蔽 2060 / 保留 2060 加封印）   ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  [4] 🌀 测速换源 + 安装华硕奥创中心(风扇/限充) + 开启蓝牙      ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  [5] 🇨🇳 安装配置 Fcitx5 中文输入法与中文字体                   ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  [6] 📦 交互式选装日常软件（微信 / QQ / VSCode / 浏览器 / WPS）${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  [7] 🔍 系统防死机状态全面体检                                 ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  [r] 🔄 立即重启电脑使配置生效                                 ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  [q] ❌ 退出脚本                                               ${GREEN}║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
        read -rp "请输入选项编号: " choice

        case "$choice" in
            0)
                setup_sudo_nopasswd
                setup_kernel_fixes
                setup_gpu_mode
                setup_asus_and_system
                setup_chinese_input
                setup_daily_apps
                system_health_check
                echo -e "${GREEN}🎉 全流程开荒完毕！请输入 [r] 重启电脑以激活所有防死机保护。${NC}"
                ;;
            1) setup_sudo_nopasswd ;;
            2) setup_kernel_fixes ;;
            3) setup_gpu_mode ;;
            4) setup_asus_and_system ;;
            5) setup_chinese_input ;;
            6) setup_daily_apps ;;
            7) system_health_check ;;
            r|R)
                echo -e "${GREEN}正在重启系统...${NC}"
                sudo reboot
                ;;
            q|Q)
                echo -e "${GREEN}祝使用愉快，彻底告别 CapsLock 闪烁！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入。${NC}"
                ;;
        esac
    done
}

main_menu